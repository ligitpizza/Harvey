"""Module 11 admin panel (D-59).

GET /admin/audit-logs        filter by date range, action, user, text; summary counts
GET /admin/audit-logs.csv    the same rows as CSV (FR-11.3); the export itself is audited
GET /admin/system-health     live check and latency per service, uptime (FR-11.3)
GET /admin/analytics/hospital   risk distribution and trend, consultations, adherence (FR-11.4)
GET /admin/analytics/system     clinicians, messages, critical alerts, activity (FR-11.3)
POST /admin/reports          hospital-wide PDF for a date range (UC11.5)
"""

from datetime import UTC, date, datetime, time, timedelta
from typing import Any

from fastapi import APIRouter, Depends, Query, Response, status
from pydantic import BaseModel, ConfigDict, Field

from app.core.audit import AuditLogger, get_audit_logger
from app.core.auth import CurrentUser, require_roles
from app.core.config import Settings, get_settings
from app.core.enums import UserRole
from app.core.errors import ApiError
from app.integrations.delivery import CourierClient, get_courier_client
from app.integrations.email import EmailClient, get_email_client
from app.integrations.gemini import LlmClient, get_llm_client
from app.integrations.sms import SmsClient, get_sms_client
from app.services.analytics import (
    AnalyticsSource,
    get_analytics_source,
    hospital,
    report_data,
    report_pdf,
    system,
)
from app.services.audit_view import (
    AuditReader,
    get_audit_reader,
    module_of,
    summarise,
    to_csv,
)
from app.services.chart_builder import (
    CHART_TYPES,
    MAX_CHARTS,
    MEASURES,
    PERIODS,
    clean_chart,
    series,
)
from app.services.health_tools import ERRORS, SERVICES, test_service
from app.services.notifications import Notifier, get_notifier
from app.services.system_health import Probe, get_probe, system_health, uptime
from app.services.users import UserRepository, get_user_repository

router = APIRouter(prefix="/admin", tags=["admin"])
admin_only = require_roles(UserRole.ADMIN)

MYT = timedelta(hours=8)
MAX_RANGE_DAYS = 366


def _range(start: date | None, end: date | None) -> tuple[datetime, datetime]:
    """Malaysian dates [start, end] -> UTC instants [from, to). Default: the last 7 days."""
    today = (datetime.now(UTC) + MYT).date()
    end = end or today
    start = start or end - timedelta(days=6)
    if start > end:
        raise ApiError(
            "INVALID_RANGE",
            "The start date is after the end date.",
            status.HTTP_422_UNPROCESSABLE_CONTENT,
        )
    if (end - start).days > MAX_RANGE_DAYS:
        raise ApiError(
            "INVALID_RANGE", "Choose at most one year.", status.HTTP_422_UNPROCESSABLE_CONTENT
        )
    lo = datetime.combine(start, time.min, tzinfo=UTC) - MYT
    hi = datetime.combine(end + timedelta(days=1), time.min, tzinfo=UTC) - MYT
    return lo, hi


def _rows(
    reader: AuditReader,
    users: UserRepository,
    lo: datetime,
    hi: datetime,
    action: str | None,
    user_id: str | None,
    q: str | None,
) -> list[dict[str, Any]]:
    people = dict(users.list_users())
    needle = (q or "").strip().lower()
    rows: list[dict[str, Any]] = []
    for log_id, e in reader.between(lo, hi):
        if action and e.get("action") != action:
            continue
        if not action and e.get("action") == "JOB_HEARTBEAT":
            continue  # 96 a day from the sweep; shown only when filtered for
        if user_id and e.get("userId") != user_id:
            continue
        who = people.get(str(e.get("userId")), {})
        ts = e.get("timestamp")
        row = {
            "id": log_id,
            "timestamp": ts.isoformat() if isinstance(ts, datetime) else None,
            "userId": e.get("userId"),
            "userName": who.get("name"),
            "role": who.get("role"),
            "action": e.get("action"),
            "module": module_of(e),
            "targetType": e.get("targetType"),
            "targetId": e.get("targetId"),
            "details": e.get("details"),
        }
        if needle and not any(
            needle in str(v).lower()
            for v in (row["userName"], row["userId"], row["action"], row["details"], log_id)
        ):
            continue
        rows.append(row)
    return rows


@router.get("/audit-logs")
def audit_logs(
    start: date | None = Query(default=None, alias="from"),
    end: date | None = Query(default=None, alias="to"),
    action: str | None = None,
    user_id: str | None = Query(default=None, alias="userId"),
    q: str | None = None,
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=15, ge=1, le=200),
    _: CurrentUser = Depends(admin_only),
    reader: AuditReader = Depends(get_audit_reader),
    users: UserRepository = Depends(get_user_repository),
) -> dict[str, Any]:
    """UC11.3: system-wide events, filterable by user / date / action (Fig 4.3.14.3)."""
    lo, hi = _range(start, end)
    rows = _rows(reader, users, lo, hi, action, user_id, q)
    previous = len(reader.between(lo - (hi - lo), lo))
    return {
        "summary": summarise([r for r in rows], previous),
        "actions": sorted({str(e.get("action")) for _, e in reader.between(lo, hi)}),
        "total": len(rows),
        "entries": rows[offset : offset + limit],
    }


@router.get("/audit-logs.csv")
def audit_logs_csv(
    start: date | None = Query(default=None, alias="from"),
    end: date | None = Query(default=None, alias="to"),
    action: str | None = None,
    user_id: str | None = Query(default=None, alias="userId"),
    q: str | None = None,
    admin: CurrentUser = Depends(admin_only),
    reader: AuditReader = Depends(get_audit_reader),
    users: UserRepository = Depends(get_user_repository),
    audit: AuditLogger = Depends(get_audit_logger),
) -> Response:
    lo, hi = _range(start, end)
    rows = _rows(reader, users, lo, hi, action, user_id, q)
    audit.log(
        user_id=admin.uid,
        action="EXPORT_AUDIT_LOG",
        details=f"Exported {len(rows)} audit entries as CSV.",
    )
    return Response(
        content=to_csv(rows),
        media_type="text/csv",
        headers={"Content-Disposition": 'attachment; filename="careflow-audit-log.csv"'},
    )


@router.get("/system-health")
def get_system_health(
    _: CurrentUser = Depends(admin_only),
    probe: Probe = Depends(get_probe),
    reader: AuditReader = Depends(get_audit_reader),
    settings: Settings = Depends(get_settings),
) -> dict[str, Any]:
    """Fig 4.3.14.7: API, database, ML model, push, email, AI agent, Stripe, Grab."""
    return system_health(probe, reader, settings)


@router.get("/analytics/hospital")
def hospital_analytics(
    months: int = Query(default=6, ge=1, le=12),
    _: CurrentUser = Depends(admin_only),
    src: AnalyticsSource = Depends(get_analytics_source),
) -> dict[str, Any]:
    """Fig 4.3.14.5 (FR-11.4), with the monthly risk-level trend (D-59)."""
    return hospital(src, datetime.now(UTC), months)


@router.get("/analytics/system")
def system_analytics(
    days: int = Query(default=7, ge=1, le=90),
    _: CurrentUser = Depends(admin_only),
    src: AnalyticsSource = Depends(get_analytics_source),
    reader: AuditReader = Depends(get_audit_reader),
) -> dict[str, Any]:
    """Fig 4.3.14.6 (FR-11.3); usage grouped by doctor specialty (D-59)."""
    now = datetime.now(UTC)
    entries = [e for _, e in reader.between(now - timedelta(days=30), now + timedelta(seconds=1))]
    return system(src, entries, now, days, uptime(reader, now))


class ReportRequest(BaseModel):
    """UC11.5 parameters: Malaysian calendar dates."""

    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    start: date = Field(alias="from")
    end: date = Field(alias="to")


@router.post("/reports")
def hospital_report(
    body: ReportRequest,
    admin: CurrentUser = Depends(admin_only),
    src: AnalyticsSource = Depends(get_analytics_source),
    reader: AuditReader = Depends(get_audit_reader),
    audit: AuditLogger = Depends(get_audit_logger),
) -> Response:
    """UC11.5: compile the report for a date range and return the PDF (E1: no data)."""
    start, end = body.start, body.end
    lo, hi = _range(start, end)
    data = report_data(src, [e for _, e in reader.between(lo, hi)], lo, hi)
    if data is None:
        raise ApiError(
            "NO_DATA",
            "There is no activity in this period, so no report was generated.",
            status.HTTP_422_UNPROCESSABLE_CONTENT,
        )
    period = f"{start:%d %b %Y} to {end:%d %b %Y}"
    generated = f"{datetime.now(UTC) + MYT:%d %b %Y, %H:%M}"
    pdf = report_pdf(data, period, generated)
    audit.log(
        user_id=admin.uid,
        action="GENERATE_REPORT",
        details=f"Hospital-wide report for {period}.",
    )
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={"Content-Disposition": 'attachment; filename="careflow-hospital-report.pdf"'},
    )


# ---------------- D-79: System health actions ----------------


@router.post("/system-health/{service}/test")
def test_one_service(
    service: str,
    admin: CurrentUser = Depends(admin_only),
    probe: Probe = Depends(get_probe),
    settings: Settings = Depends(get_settings),
    users: UserRepository = Depends(get_user_repository),
    notifier: Notifier = Depends(get_notifier),
    email: EmailClient = Depends(get_email_client),
    sms: SmsClient = Depends(get_sms_client),
    llm: LlmClient = Depends(get_llm_client),
    courier: CourierClient = Depends(get_courier_client),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, Any]:
    if service not in SERVICES:
        raise ApiError("SERVICE_NOT_FOUND", "Unknown service.", status.HTTP_404_NOT_FOUND)
    me = users.get_user(admin.uid) or {}
    result = test_service(
        service,
        {
            "settings": settings,
            "probe": probe,
            "notifier": notifier,
            "email": email,
            "sms": sms,
            "llm": llm,
            "courier": courier,
            "admin": {
                "uid": admin.uid,
                "name": me.get("name"),
                "email": me.get("email"),
                "phone": me.get("phone"),
            },
        },
    )
    audit.log(
        user_id=admin.uid,
        action="TEST_SERVICE",
        details=f"System health test of {service}: {'ok' if result['ok'] else 'failed'}.",
        target_type="system_health",
        target_id=service,
    )
    return {"service": service, **result}


@router.get("/system-health/{service}/errors")
def service_errors(service: str, _: CurrentUser = Depends(admin_only)) -> dict[str, Any]:
    if service not in SERVICES:
        raise ApiError("SERVICE_NOT_FOUND", "Unknown service.", status.HTTP_404_NOT_FOUND)
    return {"service": service, "errors": ERRORS.recent(service)}


# ---------------- D-79: custom analytics charts ----------------


class ChartsRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    charts: list[dict[str, Any]] = Field(max_length=MAX_CHARTS)


@router.get("/analytics/measures")
def chart_measures(_: CurrentUser = Depends(admin_only)) -> dict[str, Any]:
    return {
        "measures": [
            {"key": k, "label": v[0], "kind": v[1], "page": v[2]} for k, v in MEASURES.items()
        ],
        "types": list(CHART_TYPES),
        "periods": list(PERIODS),
    }


@router.get("/analytics/charts")
def my_charts(
    admin: CurrentUser = Depends(admin_only),
    users: UserRepository = Depends(get_user_repository),
) -> dict[str, Any]:
    saved = (users.get_user(admin.uid) or {}).get("analyticsCharts") or []
    return {"charts": [c for c in saved if isinstance(c, dict)]}


@router.put("/analytics/charts")
def save_charts(
    body: ChartsRequest,
    admin: CurrentUser = Depends(admin_only),
    users: UserRepository = Depends(get_user_repository),
) -> dict[str, Any]:
    try:
        charts = [clean_chart(c) for c in body.charts]
    except ValueError as e:
        raise ApiError("INVALID_CHART", str(e), status.HTTP_422_UNPROCESSABLE_CONTENT) from e
    users.update_user(admin.uid, {"analyticsCharts": charts})
    return {"charts": charts}


@router.get("/analytics/series")
def chart_series(
    measure: str,
    days: int = Query(default=30, ge=1, le=90),
    _: CurrentUser = Depends(admin_only),
    src: AnalyticsSource = Depends(get_analytics_source),
    reader: AuditReader = Depends(get_audit_reader),
) -> dict[str, Any]:
    if measure not in MEASURES:
        raise ApiError("UNKNOWN_MEASURE", "Unknown measure.", status.HTTP_404_NOT_FOUND)
    now = datetime.now(UTC)
    entries = [e for _, e in reader.between(now - timedelta(days=days), now + timedelta(seconds=1))]
    return series(measure, days, src, entries, now)

"""Custom analytics charts (D-79).

An admin picks a measure, a chart type and a period; the chart definition is saved on their
user document (`users.analyticsCharts`) and the data comes from `series()`. Measures reuse
the same collections and fields as the default analytics (aggregates only, no patient
names).

Time measures return one value per Malaysian day; category measures return one value per
category over the whole period.
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Callable
from datetime import date, datetime, timedelta
from typing import Any

from app.core.enums import Collection, UserRole
from app.services.analytics import (
    LEVELS,
    AnalyticsSource,
    _adherence,
    _latest_per_patient,
    _myt_day,
    overall_level,
)

MAX_CHARTS = 12
CHART_TYPES = ("bar", "line", "donut", "stacked")
PERIODS = (7, 30, 90)

# key -> (label, "time" | "category", page)
MEASURES: dict[str, tuple[str, str, str]] = {
    "readings_per_day": ("BP readings logged per day", "time", "hospital"),
    "new_patients_per_day": ("New patient registrations per day", "time", "hospital"),
    "risk_levels": ("Patients by latest risk level", "category", "hospital"),
    "appointments_by_status": ("Appointments by status", "category", "hospital"),
    "appointments_per_day": ("Appointments per day", "time", "hospital"),
    "adherence_per_day": ("Medication adherence per day (%)", "time", "hospital"),
    "alerts_by_severity": ("Clinical alerts by severity", "category", "hospital"),
    "symptom_checks_by_outcome": ("Symptom checks by outcome", "category", "hospital"),
    "orders_by_status": ("Medication orders by status", "category", "hospital"),
    "deliveries_by_status": ("Home deliveries by status", "category", "hospital"),
    "activity_by_role": ("Actions per day by user type", "time", "usage"),
    "logins_by_role": ("Sign-ins by user type", "category", "usage"),
    "messages_per_day": ("Secure messages per day", "time", "usage"),
    "users_by_role": ("Accounts by role", "category", "usage"),
}

ROLE_NAMES = {
    UserRole.PATIENT.value: "Patients",
    UserRole.DOCTOR.value: "Doctors",
    UserRole.PHARMACIST.value: "Pharmacists",
    UserRole.ADMIN.value: "Admins",
    UserRole.FAMILY_MEMBER.value: "Family",
}


def _days(start: datetime, days: int) -> list[date]:
    first = _myt_day(start) + timedelta(days=1)
    return [first + timedelta(days=i) for i in range(days)]


def _per_day(items: list[datetime], start: datetime, days: int) -> dict[str, Any]:
    labels = _days(start, days)
    counts = Counter(_myt_day(t) for t in items)
    return {
        "kind": "time",
        "labels": [d.isoformat() for d in labels],
        "series": {"Count": [counts.get(d, 0) for d in labels]},
    }


def _categories(counter: Counter[str], order: list[str] | None = None) -> dict[str, Any]:
    keys = order or [k for k, _ in counter.most_common()]
    return {
        "kind": "category",
        "labels": keys,
        "series": {"Count": [counter.get(k, 0) for k in keys]},
    }


def series(
    measure: str,
    days: int,
    src: AnalyticsSource,
    audit_entries: list[dict[str, Any]],
    now: datetime,
) -> dict[str, Any]:
    if measure not in MEASURES:
        raise KeyError(measure)
    start = now - timedelta(days=days)
    end = now + timedelta(seconds=1)

    def times(collection: Collection, field: str) -> list[datetime]:
        return [
            d[field]
            for d in src.in_range(collection, field, start, end)
            if isinstance(d.get(field), datetime)
        ]

    users = dict(src.users())

    def role_of(uid: Any) -> str | None:
        return users.get(str(uid), {}).get("role")

    events = [
        e
        for e in audit_entries
        if isinstance(e.get("timestamp"), datetime)
        and start <= e["timestamp"] < end
        and e.get("action") != "JOB_HEARTBEAT"
    ]

    def readings() -> dict[str, Any]:
        return _per_day(times(Collection.VITAL_READINGS, "timestamp"), start, days)

    def new_patients() -> dict[str, Any]:
        created = [
            u["createdAt"]
            for u in users.values()
            if u.get("role") == UserRole.PATIENT.value
            and isinstance(u.get("createdAt"), datetime)
            and start <= u["createdAt"] < end
        ]
        return _per_day(created, start, days)

    def risk_levels() -> dict[str, Any]:
        scores = src.in_range(Collection.RISK_SCORES, "generatedAt", start, end)
        latest = _latest_per_patient(scores).values()
        return _categories(Counter(str(overall_level(s)) for s in latest), LEVELS)

    def appts_status() -> dict[str, Any]:
        appts = src.in_range(Collection.APPOINTMENTS, "dateTime", start, end + timedelta(days=60))
        return _categories(Counter(str(a.get("status")) for a in appts))

    def appts_day() -> dict[str, Any]:
        return _per_day(times(Collection.APPOINTMENTS, "dateTime"), start, days)

    def adherence() -> dict[str, Any]:
        logs = src.in_range(Collection.DOSE_LOGS, "scheduledTime", start, end)
        by_day: dict[date, list[dict[str, Any]]] = {}
        for d in logs:
            if isinstance(d.get("scheduledTime"), datetime):
                by_day.setdefault(_myt_day(d["scheduledTime"]), []).append(d)
        labels = _days(start, days)
        return {
            "kind": "time",
            "labels": [d.isoformat() for d in labels],
            "series": {"Adherence %": [_adherence(by_day.get(d, [])) or 0 for d in labels]},
        }

    def alerts() -> dict[str, Any]:
        rows = src.in_range(Collection.CLINICAL_ALERTS, "createdAt", start, end)
        return _categories(Counter(str(a.get("severity")) for a in rows), LEVELS)

    def triage() -> dict[str, Any]:
        rows = src.in_range(Collection.TRIAGE_OUTCOMES, "generatedAt", start, end)
        return _categories(Counter(str(t.get("outcome")).replace("_", " ") for t in rows))

    def orders_status() -> dict[str, Any]:
        rows = src.in_range(Collection.MEDICATION_ORDERS, "createdAt", start, end)
        return _categories(Counter(str(o.get("fulfilmentStatus")).replace("_", " ") for o in rows))

    def deliveries() -> dict[str, Any]:
        rows = src.in_range(Collection.MEDICATION_ORDERS, "createdAt", start, end)
        return _categories(
            Counter(
                str(o.get("deliveryStatus") or "not dispatched").replace("_", " ")
                for o in rows
                if o.get("method") == "home_delivery"
            )
        )

    def activity() -> dict[str, Any]:
        labels = _days(start, days)
        per: dict[str, Counter[date]] = {name: Counter() for name in ROLE_NAMES.values()}
        for e in events:
            role = role_of(e.get("userId"))
            if role in ROLE_NAMES:
                per[ROLE_NAMES[role]][_myt_day(e["timestamp"])] += 1
        return {
            "kind": "time",
            "labels": [d.isoformat() for d in labels],
            "series": {name: [c.get(d, 0) for d in labels] for name, c in per.items()},
        }

    def logins() -> dict[str, Any]:
        c: Counter[str] = Counter()
        for e in events:
            role = role_of(e.get("userId"))
            if e.get("action") == "LOGIN" and role in ROLE_NAMES:
                c[ROLE_NAMES[role]] += 1
        return _categories(c, list(ROLE_NAMES.values()))

    def messages() -> dict[str, Any]:
        return _per_day(times(Collection.MESSAGES, "sentAt"), start, days)

    def users_by_role() -> dict[str, Any]:
        c = Counter(
            ROLE_NAMES[str(u.get("role"))] for u in users.values() if u.get("role") in ROLE_NAMES
        )
        return _categories(c, list(ROLE_NAMES.values()))

    builders: dict[str, Callable[[], dict[str, Any]]] = {
        "readings_per_day": readings,
        "new_patients_per_day": new_patients,
        "risk_levels": risk_levels,
        "appointments_by_status": appts_status,
        "appointments_per_day": appts_day,
        "adherence_per_day": adherence,
        "alerts_by_severity": alerts,
        "symptom_checks_by_outcome": triage,
        "orders_by_status": orders_status,
        "deliveries_by_status": deliveries,
        "activity_by_role": activity,
        "logins_by_role": logins,
        "messages_per_day": messages,
        "users_by_role": users_by_role,
    }
    out = builders[measure]()
    return {"measure": measure, "title": MEASURES[measure][0], "days": days, **out}


def clean_chart(c: dict[str, Any]) -> dict[str, Any]:
    """Validates one saved chart definition."""
    if c.get("measure") not in MEASURES:
        raise ValueError("Unknown measure.")
    if c.get("type") not in CHART_TYPES:
        raise ValueError("Unknown chart type.")
    if c.get("days") not in PERIODS:
        raise ValueError("Period must be 7, 30 or 90 days.")
    if c.get("page") not in ("hospital", "usage"):
        raise ValueError("Unknown page.")
    title = str(c.get("title") or MEASURES[c["measure"]][0]).strip()[:80]
    return {
        "id": str(c.get("id") or "")[:40] or f"c{abs(hash((c['measure'], title))) % 10**8}",
        "title": title,
        "measure": c["measure"],
        "type": c["type"],
        "days": c["days"],
        "page": c["page"],
    }

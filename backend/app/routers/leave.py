"""Staff leave (D-80): doctors and pharmacists apply, the admin approves or rejects.

POST /leave                  doctor / pharmacist: apply (startDate, endDate, reason)
GET  /leave                  doctor / pharmacist: their own; admin: everyone's
POST /leave/{id}/cancel      the applicant, while pending or before it starts
POST /leave/{id}/decision    admin: approve or reject (with an optional note)
GET  /leave/reschedule       admin: appointments flagged by approved leave

When a doctor's leave is approved, their active appointments in those days get
`needsReschedule = true`; each patient is told the clinic will move it and the admin is
told how many to reschedule (admin edit clears the flag). A doctor on approved leave has
no free slots on those days (appointments service).
"""

from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta
from typing import Any, Protocol

from fastapi import APIRouter, Depends, status
from firebase_admin import firestore

from app.core.audit import AuditLogger, get_audit_logger
from app.core.auth import CurrentUser, require_roles
from app.core.enums import Collection, UserRole
from app.core.errors import ApiError
from app.core.firebase import get_firestore
from app.integrations.push import PushMessage
from app.schemas.d80 import Decision, NewLeave
from app.services.appointments import (
    AppointmentRepository,
    get_appointment_repository,
)
from app.services.medications import MYT
from app.services.notifications import Notifier, get_notifier
from app.services.users import UserRepository, get_user_repository

router = APIRouter(prefix="/leave", tags=["leave"])
applicant_only = require_roles(UserRole.DOCTOR, UserRole.PHARMACIST)
staff = require_roles(UserRole.DOCTOR, UserRole.PHARMACIST, UserRole.ADMIN)
admin_only = require_roles(UserRole.ADMIN)

MAX_AHEAD = timedelta(days=365)
OPEN = ("pending", "approved")


class LeaveRepository(Protocol):
    def add(self, data: dict[str, Any]) -> str: ...

    def get(self, leave_id: str) -> dict[str, Any] | None: ...

    def update(self, leave_id: str, data: dict[str, Any]) -> None: ...

    def all(self) -> list[tuple[str, dict[str, Any]]]: ...

    def by_staff(self, uid: str) -> list[tuple[str, dict[str, Any]]]: ...


class FirestoreLeaveRepository:
    def __init__(self, db: Any) -> None:
        self._col = db.collection(Collection.LEAVE_REQUESTS.value)

    def add(self, data: dict[str, Any]) -> str:
        _, ref = self._col.add(data)
        return str(ref.id)

    def get(self, leave_id: str) -> dict[str, Any] | None:
        snap = self._col.document(leave_id).get()
        return dict(snap.to_dict()) if snap.exists else None

    def update(self, leave_id: str, data: dict[str, Any]) -> None:
        self._col.document(leave_id).update(data)

    def all(self) -> list[tuple[str, dict[str, Any]]]:
        q = self._col.order_by("createdAt", direction=firestore.Query.DESCENDING).limit(300)
        return [(d.id, dict(d.to_dict())) for d in q.stream()]

    def by_staff(self, uid: str) -> list[tuple[str, dict[str, Any]]]:
        q = self._col.where(filter=firestore.FieldFilter("staffId", "==", uid))
        return [(d.id, dict(d.to_dict())) for d in q.stream()]


def get_leave_repository() -> LeaveRepository:
    return FirestoreLeaveRepository(get_firestore())


def _today() -> date:
    return datetime.now(UTC).astimezone(MYT).date()


def _bounds(start: date, end: date) -> tuple[datetime, datetime]:
    """UTC instants covering Malaysian dates start..end inclusive."""
    return (
        datetime.combine(start, time.min, tzinfo=MYT).astimezone(UTC),
        datetime.combine(end + timedelta(days=1), time.min, tzinfo=MYT).astimezone(UTC),
    )


def _iso(v: Any) -> str | None:
    return v.isoformat() if isinstance(v, datetime) else None


def _days(r: dict[str, Any]) -> int:
    try:
        return (date.fromisoformat(r["endDate"]) - date.fromisoformat(r["startDate"])).days + 1
    except (KeyError, TypeError, ValueError):
        return 0


def _view(leave_id: str, r: dict[str, Any], affected: int | None = None) -> dict[str, Any]:
    out = {
        "id": leave_id,
        "staffId": r.get("staffId"),
        "staffName": r.get("staffName"),
        "staffRole": r.get("staffRole"),
        "startDate": r.get("startDate"),
        "endDate": r.get("endDate"),
        "days": _days(r),
        "reason": r.get("reason"),
        "status": r.get("status"),
        "decidedBy": r.get("decidedBy"),
        "decisionNote": r.get("decisionNote"),
        "createdAt": _iso(r.get("createdAt")),
        "updatedAt": _iso(r.get("updatedAt")),
    }
    if affected is not None:
        out["affectedAppointments"] = affected
    return out


def _overlaps(a_start: str, a_end: str, b_start: date, b_end: date) -> bool:
    try:
        return date.fromisoformat(a_start) <= b_end and b_start <= date.fromisoformat(a_end)
    except (TypeError, ValueError):
        return False


def _affected(appts: AppointmentRepository, r: dict[str, Any]) -> int:
    if r.get("staffRole") != UserRole.DOCTOR.value:
        return 0
    start, end = _bounds(date.fromisoformat(r["startDate"]), date.fromisoformat(r["endDate"]))
    return len(appts.active_for_doctor(str(r["staffId"]), start, end))


def _admins(users: UserRepository) -> list[str]:
    return [
        uid
        for uid, u in users.list_users()
        if u.get("role") == UserRole.ADMIN.value and u.get("isActive", True) is not False
    ]


def _range_text(r: dict[str, Any]) -> str:
    def fmt(s: str) -> str:
        return date.fromisoformat(s).strftime("%a %d %b")

    s, e = str(r["startDate"]), str(r["endDate"])
    return fmt(s) if s == e else f"{fmt(s)} - {fmt(e)}"


@router.post("", status_code=status.HTTP_201_CREATED)
def apply(
    body: NewLeave,
    user: CurrentUser = Depends(applicant_only),
    repo: LeaveRepository = Depends(get_leave_repository),
    users: UserRepository = Depends(get_user_repository),
    appts: AppointmentRepository = Depends(get_appointment_repository),
    notifier: Notifier = Depends(get_notifier),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, Any]:
    today = _today()
    if body.startDate < today:
        raise ApiError("LEAVE_IN_PAST", "Leave can't start in the past.", 422)
    if body.startDate > today + MAX_AHEAD:
        raise ApiError("LEAVE_TOO_FAR", "Apply at most a year ahead.", 422)
    for _, r in repo.by_staff(user.uid):
        if r.get("status") in OPEN and _overlaps(
            str(r.get("startDate")), str(r.get("endDate")), body.startDate, body.endDate
        ):
            raise ApiError(
                "LEAVE_OVERLAP",
                "You already have leave pending or approved on some of these days.",
                status.HTTP_409_CONFLICT,
            )
    me = users.get_user(user.uid) or {}
    now = datetime.now(UTC)
    data = {
        "staffId": user.uid,
        "staffName": me.get("name") or "Staff",
        "staffRole": user.role.value if user.role else "",
        "startDate": body.startDate.isoformat(),
        "endDate": body.endDate.isoformat(),
        "reason": body.reason,
        "status": "pending",
        "decidedBy": None,
        "decisionNote": None,
        "createdAt": now,
        "updatedAt": now,
    }
    leave_id = repo.add(data)
    affected = _affected(appts, data)
    clash = f" {affected} booked appointment(s) fall in this period." if affected else ""
    for uid in _admins(users):
        notifier.notify(
            uid,
            PushMessage(
                f"Leave request from {data['staffName']}",
                f"{_range_text(data)}: {body.reason}.{clash}",
                {"type": "leave", "id": leave_id},
            ),
        )
    audit.log(
        user_id=user.uid,
        action="LEAVE_APPLIED",
        details=f"Leave {data['startDate']} to {data['endDate']} ({_days(data)} day(s)).",
        target_type=Collection.LEAVE_REQUESTS.value,
        target_id=leave_id,
    )
    return _view(leave_id, data, affected)


@router.get("")
def list_leave(
    user: CurrentUser = Depends(staff),
    repo: LeaveRepository = Depends(get_leave_repository),
    appts: AppointmentRepository = Depends(get_appointment_repository),
) -> dict[str, Any]:
    is_admin = user.role is UserRole.ADMIN
    rows = repo.all() if is_admin else repo.by_staff(user.uid)
    out = [
        _view(i, r, _affected(appts, r) if r.get("status") == "pending" else None) for i, r in rows
    ]
    out.sort(key=lambda v: v["createdAt"] or "", reverse=True)
    return {"leave": out}


@router.post("/{leave_id}/cancel")
def cancel(
    leave_id: str,
    user: CurrentUser = Depends(applicant_only),
    repo: LeaveRepository = Depends(get_leave_repository),
    users: UserRepository = Depends(get_user_repository),
    notifier: Notifier = Depends(get_notifier),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, Any]:
    r = repo.get(leave_id)
    if r is None or r.get("staffId") != user.uid:
        raise ApiError("LEAVE_NOT_FOUND", "Leave request not found.", 404)
    started = date.fromisoformat(str(r["startDate"])) <= _today()
    if r.get("status") not in OPEN or (r.get("status") == "approved" and started):
        raise ApiError(
            "LEAVE_LOCKED",
            "Only pending leave, or approved leave that hasn't started, can be cancelled.",
            status.HTTP_409_CONFLICT,
        )
    was = r.get("status")
    changes = {"status": "cancelled", "updatedAt": datetime.now(UTC)}
    repo.update(leave_id, changes)
    if was == "approved":
        for uid in _admins(users):
            notifier.notify(
                uid,
                PushMessage(
                    f"{r.get('staffName')} cancelled approved leave",
                    f"{_range_text(r)} is a working period again.",
                    {"type": "leave", "id": leave_id},
                ),
            )
    audit.log(
        user_id=user.uid,
        action="LEAVE_CANCELLED",
        details=f"Leave {r['startDate']} to {r['endDate']} cancelled ({was}).",
        target_type=Collection.LEAVE_REQUESTS.value,
        target_id=leave_id,
    )
    return _view(leave_id, {**r, **changes})


@router.post("/{leave_id}/decision")
def decide(
    leave_id: str,
    body: Decision,
    user: CurrentUser = Depends(admin_only),
    repo: LeaveRepository = Depends(get_leave_repository),
    users: UserRepository = Depends(get_user_repository),
    appts: AppointmentRepository = Depends(get_appointment_repository),
    notifier: Notifier = Depends(get_notifier),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, Any]:
    r = repo.get(leave_id)
    if r is None:
        raise ApiError("LEAVE_NOT_FOUND", "Leave request not found.", 404)
    if r.get("status") != "pending":
        raise ApiError(
            "LEAVE_DECIDED", "This leave request was already decided.", status.HTTP_409_CONFLICT
        )
    admin = users.get_user(user.uid) or {}
    approved = body.decision == "approve"
    changes: dict[str, Any] = {
        "status": "approved" if approved else "rejected",
        "decidedBy": admin.get("name") or "Admin",
        "decisionNote": body.note or None,
        "updatedAt": datetime.now(UTC),
    }
    repo.update(leave_id, changes)
    r = {**r, **changes}
    flagged = 0
    if approved and r.get("staffRole") == UserRole.DOCTOR.value:
        start, end = _bounds(date.fromisoformat(r["startDate"]), date.fromisoformat(r["endDate"]))
        doctor_name = str(r.get("staffName") or "Your doctor")
        for a in appts.active_for_doctor(str(r["staffId"]), start, end):
            appts.update(a.id, {"needsReschedule": True})
            flagged += 1
            notifier.notify(
                str(a.data["patientId"]),
                PushMessage(
                    "Your appointment needs a new time",
                    f"{doctor_name} is on leave that day. The clinic will reschedule your "
                    "appointment and let you know the new time.",
                    {"type": "appointment", "id": a.id},
                ),
            )
        if flagged:
            for uid in _admins(users):
                notifier.notify(
                    uid,
                    PushMessage(
                        f"{flagged} appointment(s) to reschedule",
                        f"{doctor_name} is on leave {_range_text(r)}.",
                        {"type": "appointment", "id": leave_id},
                    ),
                )
    note = f" Note: {body.note}" if body.note else ""
    notifier.notify(
        str(r["staffId"]),
        PushMessage(
            f"Leave {'approved' if approved else 'not approved'}",
            f"{_range_text(r)}.{note}",
            {"type": "leave", "id": leave_id},
        ),
    )
    audit.log(
        user_id=user.uid,
        action="LEAVE_APPROVED" if approved else "LEAVE_REJECTED",
        details=(
            f"{r.get('staffName')} {r['startDate']} to {r['endDate']}; "
            f"{flagged} appointment(s) flagged for rescheduling."
        ),
        target_type=Collection.LEAVE_REQUESTS.value,
        target_id=leave_id,
    )
    return {**_view(leave_id, r), "flaggedAppointments": flagged}


@router.get("/reschedule")
def to_reschedule(
    user: CurrentUser = Depends(admin_only),
    appts: AppointmentRepository = Depends(get_appointment_repository),
) -> dict[str, Any]:
    """Active appointments flagged by approved leave, soonest first."""
    now = datetime.now(UTC)
    out = []
    for a in appts.active_between(now - timedelta(days=1), now + timedelta(days=400)):
        if a.data.get("needsReschedule") is True:
            patient = appts.user(str(a.data.get("patientId"))) or {}
            doctor = appts.user(str(a.data.get("doctorId"))) or {}
            out.append(
                {
                    "id": a.id,
                    "patientId": a.data.get("patientId"),
                    "patientName": patient.get("name"),
                    "doctorId": a.data.get("doctorId"),
                    "doctorName": doctor.get("name"),
                    "dateTime": a.data["dateTime"].isoformat(),
                    "type": a.data.get("type"),
                }
            )
    out.sort(key=lambda v: v["dateTime"])
    return {"appointments": out}

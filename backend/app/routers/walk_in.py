"""Walk-in patients (D-80): the pharmacist registers or finds a patient at the counter
and books them into a free slot with a doctor today.

GET  /walk-in/patients?q=     pharmacist / admin: find patients (name, email or IC)
POST /walk-in/patients        pharmacist / admin: open a patient account (setup email)
GET  /walk-in/doctors         pharmacist / admin: active doctors and today's free slots
POST /walk-in/appointments    pharmacist / admin: book today; bookedBy "pharmacist"

A walk-in sees their assigned doctor; a patient with no doctor is assigned the one the
pharmacist picks (caseload limit D-59). Appointments are marked `walkIn: true`.
"""

from __future__ import annotations

from datetime import UTC, date, datetime
from typing import Any

from fastapi import APIRouter, Depends, Query, status

from app.core.audit import AuditLogger, get_audit_logger
from app.core.auth import CurrentUser, require_roles
from app.core.enums import AppointmentStatus, Collection, UserRole
from app.core.errors import ApiError
from app.integrations.email import EmailClient, get_email_client
from app.integrations.push import PushMessage
from app.routers.admin import DEFAULT_MAX_PATIENTS, caseloads, open_patient_account
from app.schemas.auth import CreatePatientRequest
from app.schemas.d80 import WalkInBooking
from app.services.appointment_extras import when_text
from app.services.appointments import (
    SLOT,
    AppointmentRepository,
    DoctorOnLeaveError,
    SlotTakenError,
    clashes,
    day_slots,
    get_appointment_repository,
    period,
)
from app.services.identity import IdentityProvider, get_identity_provider
from app.services.medications import MYT
from app.services.notifications import Notifier, get_notifier
from app.services.users import UserRepository, get_user_repository

router = APIRouter(prefix="/walk-in", tags=["walk-in"])
counter = require_roles(UserRole.PHARMACIST, UserRole.ADMIN)


def _now() -> datetime:
    return datetime.now(UTC)


def _today() -> date:
    return _now().astimezone(MYT).date()


def walk_in_slots(day: date, taken: set[datetime], now: datetime) -> list[datetime]:
    """Today's slots that haven't ended and are free (no 1-hour lead time: they're here)."""
    return [s for s in day_slots(day) if s + SLOT > now and not any(clashes(s, t) for t in taken)]


def _patient_row(uid: str, u: dict[str, Any], doctors: dict[str, str]) -> dict[str, Any]:
    ic = str(u.get("icNumber") or "")
    doctor = str(u.get("assignedDoctorId") or "")
    return {
        "id": uid,
        "name": u.get("name"),
        "email": u.get("email"),
        # Only the last 4 digits: enough to tell people apart at the counter.
        "icLast4": ic[-4:] if ic else None,
        "doctorId": doctor or None,
        "doctorName": doctors.get(doctor),
        "isActive": u.get("isActive") is not False,
    }


@router.get("/patients")
def find_patients(
    q: str = Query(min_length=2, max_length=60),
    user: CurrentUser = Depends(counter),
    users: UserRepository = Depends(get_user_repository),
) -> dict[str, Any]:
    needle = q.strip().lower()
    digits = "".join(c for c in needle if c.isdigit())
    everyone = users.list_users()
    doctors = {
        uid: str(u.get("name") or "")
        for uid, u in everyone
        if u.get("role") == UserRole.DOCTOR.value
    }
    out = []
    for uid, u in everyone:
        if u.get("role") != UserRole.PATIENT.value:
            continue
        name = str(u.get("name") or "").lower()
        email = str(u.get("email") or "").lower()
        ic = str(u.get("icNumber") or "")
        if needle in name or needle in email or (len(digits) >= 4 and digits in ic):
            out.append(_patient_row(uid, u, doctors))
    out.sort(key=lambda r: str(r["name"] or "").lower())
    return {"patients": out[:20]}


@router.post("/patients", status_code=status.HTTP_201_CREATED)
def register_walk_in(
    body: CreatePatientRequest,
    user: CurrentUser = Depends(counter),
    identity: IdentityProvider = Depends(get_identity_provider),
    users: UserRepository = Depends(get_user_repository),
    email_client: EmailClient = Depends(get_email_client),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, Any]:
    uid, email_sent, link = open_patient_account(body, identity, users, email_client)
    audit.log(
        user_id=user.uid,
        action="REGISTER_WALK_IN",
        details="Walk-in patient account opened at the counter; setup link "
        f"{'emailed' if email_sent else 'shown'}.",
        target_type=Collection.USERS.value,
        target_id=uid,
    )
    return {
        "uid": uid,
        "name": body.name,
        "emailSent": email_sent,
        "setupLink": None if email_sent else link,
    }


@router.get("/doctors")
def doctors_today(
    user: CurrentUser = Depends(counter),
    users: UserRepository = Depends(get_user_repository),
    appts: AppointmentRepository = Depends(get_appointment_repository),
) -> dict[str, Any]:
    now = _now()
    day = _today()
    slots_today = day_slots(day)
    start, end = (slots_today[0], slots_today[-1] + SLOT) if slots_today else (now, now)
    everyone = users.list_users()
    loads = caseloads(everyone)
    out: list[dict[str, Any]] = []
    for uid, u in everyone:
        if u.get("role") != UserRole.DOCTOR.value or u.get("isActive") is False:
            continue
        on_leave = day in appts.leave_days(uid)
        free = [] if on_leave else walk_in_slots(day, appts.taken(uid, start, end), now)
        out.append(
            {
                "id": uid,
                "name": u.get("name"),
                "specialty": u.get("specialty"),
                "onLeave": on_leave,
                "patients": loads.get(uid, 0),
                "maxPatients": int(u.get("maxPatients") or DEFAULT_MAX_PATIENTS),
                "slots": [{"time": s.isoformat(), "period": period(s)} for s in free],
            }
        )
    out.sort(key=lambda d: (d["onLeave"], -len(d["slots"]), str(d["name"] or "")))
    return {"date": day.isoformat(), "workingDay": bool(slots_today), "doctors": out}


@router.post("/appointments", status_code=status.HTTP_201_CREATED)
def book_walk_in(
    body: WalkInBooking,
    user: CurrentUser = Depends(counter),
    users: UserRepository = Depends(get_user_repository),
    appts: AppointmentRepository = Depends(get_appointment_repository),
    notifier: Notifier = Depends(get_notifier),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, Any]:
    everyone = dict(users.list_users())
    patient = everyone.get(body.patientId)
    if patient is None or patient.get("role") != UserRole.PATIENT.value:
        raise ApiError("PATIENT_NOT_FOUND", "That patient was not found.", 404)
    if patient.get("isActive") is False:
        raise ApiError("PATIENT_INACTIVE", "This patient's account is deactivated.", 409)
    doctor = everyone.get(body.doctorId)
    if (
        doctor is None
        or doctor.get("role") != UserRole.DOCTOR.value
        or doctor.get("isActive") is False
    ):
        raise ApiError("DOCTOR_NOT_FOUND", "That doctor was not found or is not active.", 404)
    assigned = str(patient.get("assignedDoctorId") or "")
    if assigned and assigned != body.doctorId:
        their = everyone.get(assigned, {}).get("name") or "another doctor"
        raise ApiError(
            "NOT_THEIR_DOCTOR",
            f"This patient's doctor is {their}. "
            "Book with them, or ask the admin to change the doctor.",
            status.HTTP_409_CONFLICT,
        )
    if not assigned:
        cap = int(doctor.get("maxPatients") or DEFAULT_MAX_PATIENTS)
        if caseloads(list(everyone.items())).get(body.doctorId, 0) >= cap:
            raise ApiError(
                "DOCTOR_FULL",
                "This doctor has reached their patient limit. Choose another doctor.",
                status.HTTP_409_CONFLICT,
            )
    now = _now()
    moment = body.dateTime.astimezone(UTC)
    if moment not in walk_in_slots(_today(), set(), now):
        raise ApiError(
            "INVALID_TIME",
            "Choose one of today's remaining slots.",
            status.HTTP_422_UNPROCESSABLE_CONTENT,
        )
    data = {
        "patientId": body.patientId,
        "doctorId": body.doctorId,
        "dateTime": moment,
        "status": AppointmentStatus.BOOKED.value,
        "type": body.type.value,
        "bookedBy": "pharmacist",
        "walkIn": True,
    }
    try:
        appt_id = appts.book(data)
    except DoctorOnLeaveError as exc:
        raise ApiError(
            "DOCTOR_ON_LEAVE", "The doctor is on leave today.", status.HTTP_409_CONFLICT
        ) from exc
    except SlotTakenError as exc:
        raise ApiError(
            "SLOT_TAKEN", "That slot was just taken. Choose another.", status.HTTP_409_CONFLICT
        ) from exc
    if not assigned:
        users.update_user(body.patientId, {"assignedDoctorId": body.doctorId})
    when = when_text(moment)
    patient_name = str(patient.get("name") or "A walk-in patient")
    notifier.notify(
        body.doctorId,
        PushMessage(
            "Walk-in patient booked",
            f"{patient_name}: {when}.",
            {"type": "appointment", "appointmentId": appt_id},
        ),
    )
    notifier.notify(
        body.patientId,
        PushMessage(
            "Appointment booked at the counter",
            f"You're seeing {doctor.get('name') or 'the doctor'} today at {when}.",
            {"type": "appointment", "appointmentId": appt_id},
        ),
    )
    audit.log(
        user_id=user.uid,
        action="BOOK_WALK_IN",
        details=f"Walk-in {body.type.value} with {doctor.get('name')} at {when} (MYT)"
        + ("" if assigned else "; doctor assigned")
        + ".",
        target_type=Collection.APPOINTMENTS.value,
        target_id=appt_id,
    )
    return {
        "id": appt_id,
        "patientId": body.patientId,
        "doctorId": body.doctorId,
        "dateTime": moment.isoformat(),
        "type": body.type.value,
        "assignedDoctor": not assigned,
    }

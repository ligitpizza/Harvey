"""D-120: a doctor covering one visit for a colleague (e.g. on leave).

The admin moves a single appointment to another doctor; the patient stays the other
doctor's patient. That appointment carries `coverForDoctorId` (the patient's own doctor).
The covering doctor gets temporary access to the patient, from the day before the visit
until 7 days after it (Malaysian dates). Firestore rules cannot search appointments, so
the window is copied onto the patient's user document as `coverAccess`:

    users/{patient}.coverAccess = {coveringDoctorUid: {"from": ts, "until": ts}}

It is rebuilt from the patient's cover appointments whenever one is booked, moved,
cancelled or closed. During the window the covering doctor may read the patient's records
and write clinical notes; prescriptions, care plan and reports stay with the patient's own
doctor.
"""

from collections.abc import Iterable
from datetime import datetime, time, timedelta
from typing import Any

from app.core.enums import AppointmentStatus
from app.services.medications import MYT

COVER_DAYS_BEFORE = 1
COVER_DAYS_AFTER = 7

# A cancelled visit gives no access; a completed or missed one keeps it for the follow-up.
COVER_STATUSES = frozenset(
    {
        AppointmentStatus.BOOKED.value,
        AppointmentStatus.RESCHEDULED.value,
        AppointmentStatus.COMPLETED.value,
        AppointmentStatus.NO_SHOW.value,
    }
)


def cover_window(moment: datetime) -> tuple[datetime, datetime]:
    """Start of the day before the visit to the end of the 7th day after it (MYT)."""
    day = moment.astimezone(MYT).date()
    start = datetime.combine(day - timedelta(days=COVER_DAYS_BEFORE), time(0), MYT)
    end = datetime.combine(day + timedelta(days=COVER_DAYS_AFTER + 1), time(0), MYT)
    return start, end


def cover_for(doctor_id: str, patient: dict[str, Any] | None) -> str | None:
    """The patient's own doctor when the visit is with someone else, else None."""
    own = str((patient or {}).get("assignedDoctorId") or "")
    return own if own and own != doctor_id else None


def build_cover_access(appointments: Iterable[dict[str, Any]]) -> dict[str, dict[str, datetime]]:
    """One window per covering doctor, spanning all their cover visits for the patient."""
    out: dict[str, dict[str, datetime]] = {}
    for a in appointments:
        doctor = str(a.get("doctorId") or "")
        if not a.get("coverForDoctorId") or not doctor or a.get("status") not in COVER_STATUSES:
            continue
        start, end = cover_window(a["dateTime"])
        cur = out.get(doctor)
        out[doctor] = (
            {"from": start, "until": end}
            if cur is None
            else {"from": min(cur["from"], start), "until": max(cur["until"], end)}
        )
    return out


def refresh_cover_access(repo: Any, patient_id: str) -> dict[str, dict[str, datetime]]:
    """Rebuild users/{patient}.coverAccess from the patient's appointments. [repo] is an
    AppointmentRepository (all_for_patient, set_cover_access)."""
    access = build_cover_access(a.data for a in repo.all_for_patient(patient_id))
    repo.set_cover_access(patient_id, access)
    return access


def has_cover_access(patient: dict[str, Any] | None, doctor_uid: str, now: datetime) -> bool:
    entry = ((patient or {}).get("coverAccess") or {}).get(doctor_uid)
    if not isinstance(entry, dict):
        return False
    start, end = entry.get("from"), entry.get("until")
    return isinstance(start, datetime) and isinstance(end, datetime) and start <= now < end


def can_see_patient(patient: dict[str, Any] | None, doctor_uid: str, now: datetime) -> bool:
    """The patient's own doctor, or a doctor inside a cover window."""
    if patient is None:
        return False
    return patient.get("assignedDoctorId") == doctor_uid or has_cover_access(
        patient, doctor_uid, now
    )

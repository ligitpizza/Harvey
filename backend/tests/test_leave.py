"""D-80 staff leave: apply, admin decision, appointment rescheduling and blocked slots."""

from datetime import UTC, date, datetime, time, timedelta

import pytest
from fastapi.testclient import TestClient

from app.services.appointments import leave_dates
from app.services.medications import MYT
from tests.conftest import (
    InMemoryAppointmentRepository,
    InMemoryAuditLogger,
    InMemoryInboxRepository,
    InMemoryUserRepository,
    bearer,
)

P = "u-patient"
D = "u-doctor"
D2 = "u-doctor-2"
ADMIN_ID = "u-admin"
PATIENT = bearer("patient-token")
DOCTOR = bearer("doctor-token")
PHARM = bearer("pharmacist-token")
ADMIN = bearer("admin-token")


@pytest.fixture(autouse=True)
def people(repo: InMemoryUserRepository) -> None:
    repo.users[P] = {"role": "patient", "name": "Siti", "email": "s@x.my", "assignedDoctorId": D}
    repo.users[D] = {"role": "doctor", "name": "Dr John", "specialty": "Cardiology"}
    repo.users[D2] = {"role": "doctor", "name": "Dr Aisha", "specialty": "General"}
    repo.users[ADMIN_ID] = {"role": "admin", "name": "Admin Woo"}
    repo.users["u-pharm"] = {"role": "pharmacist", "name": "Jane"}


def next_weekday(after: date, skip: int = 1) -> date:
    day = after
    for _ in range(skip):
        day += timedelta(days=1)
        while day.weekday() > 4:
            day += timedelta(days=1)
    return day


def today() -> date:
    return datetime.now(UTC).astimezone(MYT).date()


def at(day: date, hour: int) -> datetime:
    return datetime.combine(day, time(hour), tzinfo=MYT).astimezone(UTC)


def apply(client: TestClient, start: date, end: date, who: dict[str, str] = DOCTOR) -> dict:
    res = client.post(
        "/api/v1/leave",
        json={"startDate": start.isoformat(), "endDate": end.isoformat(), "reason": "Family trip"},
        headers=who,
    )
    assert res.status_code == 201, res.text
    return res.json()


def titles(inbox: InMemoryInboxRepository, uid: str) -> list[str]:
    return [n["title"] for n in inbox.items.values() if n.get("userId") == uid]


def test_leave_dates_cover_every_day() -> None:
    days = leave_dates([("2026-11-09", "2026-11-11"), ("bad", "2026-11-01")])
    assert days == {date(2026, 11, 9), date(2026, 11, 10), date(2026, 11, 11)}


def test_doctor_applies_admin_is_told_with_the_clash_count(
    client: TestClient, inbox: InMemoryInboxRepository, audit: InMemoryAuditLogger
) -> None:
    day = next_weekday(today(), 2)
    booked = client.post(
        "/api/v1/appointments", json={"dateTime": at(day, 10).isoformat()}, headers=PATIENT
    )
    assert booked.status_code == 201
    leave = apply(client, day, day)
    assert leave["status"] == "pending"
    assert leave["affectedAppointments"] == 1
    assert "Leave request from Dr John" in titles(inbox, ADMIN_ID)
    assert any(e["action"] == "LEAVE_APPLIED" for e in audit.entries)
    # The applicant sees their own; the admin sees everyone's.
    mine = client.get("/api/v1/leave", headers=DOCTOR).json()["leave"]
    assert [m["id"] for m in mine] == [leave["id"]]
    assert len(client.get("/api/v1/leave", headers=ADMIN).json()["leave"]) == 1
    assert client.get("/api/v1/leave", headers=PATIENT).status_code == 403


def test_bad_ranges_and_overlaps_are_refused(client: TestClient) -> None:
    day = next_weekday(today(), 3)
    res = client.post(
        "/api/v1/leave",
        json={
            "startDate": day.isoformat(),
            "endDate": (day - timedelta(days=1)).isoformat(),
            "reason": "x" * 5,
        },
        headers=DOCTOR,
    )
    assert res.status_code == 422
    res = client.post(
        "/api/v1/leave",
        json={
            "startDate": (today() - timedelta(days=2)).isoformat(),
            "endDate": today().isoformat(),
            "reason": "Sick leave",
        },
        headers=DOCTOR,
    )
    assert res.json()["error"]["code"] == "LEAVE_IN_PAST"
    apply(client, day, day + timedelta(days=2))
    res = client.post(
        "/api/v1/leave",
        json={
            "startDate": (day + timedelta(days=1)).isoformat(),
            "endDate": (day + timedelta(days=5)).isoformat(),
            "reason": "Another",
        },
        headers=DOCTOR,
    )
    assert res.json()["error"]["code"] == "LEAVE_OVERLAP"


def test_approval_flags_appointments_and_tells_patient_admin_and_doctor(
    client: TestClient,
    appointment_repo: InMemoryAppointmentRepository,
    inbox: InMemoryInboxRepository,
) -> None:
    day = next_weekday(today(), 2)
    appt_id = client.post(
        "/api/v1/appointments", json={"dateTime": at(day, 11).isoformat()}, headers=PATIENT
    ).json()["id"]
    leave = apply(client, day, day)
    res = client.post(
        f"/api/v1/leave/{leave['id']}/decision",
        json={"decision": "approve", "note": "Enjoy"},
        headers=ADMIN,
    )
    assert res.status_code == 200, res.text
    assert res.json()["status"] == "approved"
    assert res.json()["flaggedAppointments"] == 1
    assert appointment_repo.appointments[appt_id]["needsReschedule"] is True
    assert "Your appointment needs a new time" in titles(inbox, P)
    assert "1 appointment(s) to reschedule" in titles(inbox, ADMIN_ID)
    assert "Leave approved" in titles(inbox, D)
    # The admin's to-do list.
    todo = client.get("/api/v1/leave/reschedule", headers=ADMIN).json()["appointments"]
    assert [t["id"] for t in todo] == [appt_id]
    assert todo[0]["doctorName"] == "Dr John" and todo[0]["patientName"] == "Siti"
    # A decided request can't be decided again.
    again = client.post(
        f"/api/v1/leave/{leave['id']}/decision", json={"decision": "reject"}, headers=ADMIN
    )
    assert again.status_code == 409


def test_admin_reschedule_clears_the_flag(
    client: TestClient, appointment_repo: InMemoryAppointmentRepository
) -> None:
    day = next_weekday(today(), 2)
    appt_id = client.post(
        "/api/v1/appointments", json={"dateTime": at(day, 11).isoformat()}, headers=PATIENT
    ).json()["id"]
    leave = apply(client, day, day)
    client.post(
        f"/api/v1/leave/{leave['id']}/decision", json={"decision": "approve"}, headers=ADMIN
    )
    # Same doctor, same (leave) day: refused with a clear reason.
    res = client.patch(
        f"/api/v1/admin/appointments/{appt_id}",
        json={"dateTime": at(day, 15).isoformat()},
        headers=ADMIN,
    )
    assert res.json()["error"]["code"] == "DOCTOR_ON_LEAVE"
    # Another doctor that day works and clears the flag.
    res = client.patch(
        f"/api/v1/admin/appointments/{appt_id}", json={"doctorId": D2}, headers=ADMIN
    )
    assert res.status_code == 200, res.text
    assert appointment_repo.appointments[appt_id]["needsReschedule"] is False
    assert client.get("/api/v1/leave/reschedule", headers=ADMIN).json()["appointments"] == []


def test_doctor_on_leave_has_no_free_slots(client: TestClient) -> None:
    day = next_weekday(today(), 2)
    leave = apply(client, day, day)
    before = client.get(f"/api/v1/appointments/slots?date={day.isoformat()}", headers=PATIENT)
    assert any(s["available"] for s in before.json()["slots"])  # pending leave blocks nothing
    client.post(
        f"/api/v1/leave/{leave['id']}/decision", json={"decision": "approve"}, headers=ADMIN
    )
    after = client.get(f"/api/v1/appointments/slots?date={day.isoformat()}", headers=PATIENT)
    assert not any(s["available"] for s in after.json()["slots"])
    res = client.post(
        "/api/v1/appointments", json={"dateTime": at(day, 10).isoformat()}, headers=PATIENT
    )
    assert res.status_code == 409


def test_rejection_and_cancellation(client: TestClient, inbox: InMemoryInboxRepository) -> None:
    day = next_weekday(today(), 4)
    leave = apply(client, day, day, who=PHARM)
    res = client.post(
        f"/api/v1/leave/{leave['id']}/decision",
        json={"decision": "reject", "note": "Short-staffed that week"},
        headers=ADMIN,
    )
    assert res.json()["status"] == "rejected"
    assert "Leave not approved" in titles(inbox, "u-pharm")
    # Rejected leave can't be cancelled; a new pending one can.
    res = client.post(f"/api/v1/leave/{leave['id']}/cancel", headers=PHARM)
    assert res.status_code == 409
    second = apply(client, day, day, who=PHARM)
    res = client.post(f"/api/v1/leave/{second['id']}/cancel", headers=PHARM)
    assert res.json()["status"] == "cancelled"
    # Someone else's leave is not found.
    assert client.post(f"/api/v1/leave/{second['id']}/cancel", headers=DOCTOR).status_code == 404

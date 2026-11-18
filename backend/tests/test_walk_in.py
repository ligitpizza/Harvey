"""D-80 walk-in patients: the pharmacist finds or registers a patient and books today."""

from datetime import UTC, date, datetime, time
from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.routers import walk_in
from app.services.medications import MYT
from tests.conftest import (
    ConsoleEmailClient,
    InMemoryAppointmentRepository,
    InMemoryInboxRepository,
    InMemoryUserRepository,
    bearer,
)

PHARM = bearer("pharmacist-token")
ADMIN = bearer("admin-token")
PATIENT = bearer("patient-token")
DOCTOR = bearer("doctor-token")
D = "u-doctor"
D2 = "u-doctor-2"
DAY = date(2026, 11, 5)  # a Thursday


def at(hour: int, minute: int = 0) -> datetime:
    return datetime.combine(DAY, time(hour, minute), tzinfo=MYT).astimezone(UTC)


@pytest.fixture(autouse=True)
def clock(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(walk_in, "_now", lambda: at(10, 10))


@pytest.fixture(autouse=True)
def people(repo: InMemoryUserRepository) -> None:
    repo.users[D] = {"role": "doctor", "name": "Dr John", "specialty": "Cardiology"}
    repo.users[D2] = {"role": "doctor", "name": "Dr Aisha", "maxPatients": 1}
    repo.users["u-siti"] = {
        "role": "patient",
        "name": "Siti Aminah",
        "email": "siti@x.my",
        "icNumber": "900101145678",
        "assignedDoctorId": D,
    }
    repo.users["u-ali"] = {"role": "patient", "name": "Ali", "email": "ali@x.my"}
    repo.users["u-busy"] = {"role": "patient", "name": "Busy", "assignedDoctorId": D2}


def book(client: TestClient, patient: str, doctor: str, moment: datetime) -> Any:
    return client.post(
        "/api/v1/walk-in/appointments",
        json={"patientId": patient, "doctorId": doctor, "dateTime": moment.isoformat()},
        headers=PHARM,
    )


def test_search_by_name_email_or_ic_shows_only_the_last_four_digits(client: TestClient) -> None:
    rows = client.get("/api/v1/walk-in/patients?q=siti", headers=PHARM).json()["patients"]
    assert [r["id"] for r in rows] == ["u-siti"]
    assert rows[0]["icLast4"] == "5678" and rows[0]["doctorName"] == "Dr John"
    assert "icNumber" not in rows[0]
    by_ic = client.get("/api/v1/walk-in/patients?q=1456", headers=PHARM).json()["patients"]
    assert [r["id"] for r in by_ic] == ["u-siti"]
    assert client.get("/api/v1/walk-in/patients?q=siti", headers=DOCTOR).status_code == 403
    assert client.get("/api/v1/walk-in/patients?q=siti", headers=PATIENT).status_code == 403


def test_register_walk_in_opens_an_account_and_emails_the_setup_link(
    client: TestClient, repo: InMemoryUserRepository, emails: ConsoleEmailClient
) -> None:
    res = client.post(
        "/api/v1/walk-in/patients",
        json={"name": "Mei Ling", "email": "mei@x.my", "icNumber": "880202-14-5566"},
        headers=PHARM,
    )
    assert res.status_code == 201, res.text
    uid = res.json()["uid"]
    assert repo.users[uid]["role"] == "patient"
    assert repo.users[uid]["onboardingComplete"] is False
    assert emails.sent[-1].to_email == "mei@x.my"


def test_d103_walk_in_with_a_passport_and_find_by_it(
    client: TestClient, repo: InMemoryUserRepository
) -> None:
    body = {"name": "Budi Santoso", "email": "budi@x.id", "icNumber": "B9876543"}
    res = client.post("/api/v1/walk-in/patients", json=body, headers=PHARM)
    assert res.json()["error"]["code"] == "NATIONALITY_REQUIRED"
    res = client.post(
        "/api/v1/walk-in/patients", json={**body, "nationality": "Indonesia"}, headers=PHARM
    )
    assert res.status_code == 201, res.text
    uid = res.json()["uid"]
    assert repo.users[uid]["passportNumber"] == "B9876543"
    rows = client.get("/api/v1/walk-in/patients?q=b9876", headers=PHARM).json()["patients"]
    assert [r["id"] for r in rows] == [uid]
    assert rows[0]["idKind"] == "passport" and rows[0]["icLast4"] == "6543"


def test_doctors_today_lists_free_slots_from_now(
    client: TestClient, appointment_repo: InMemoryAppointmentRepository
) -> None:
    appointment_repo.appointments["a1"] = {
        "patientId": "u-siti",
        "doctorId": D,
        "dateTime": at(11),
        "status": "booked",
    }
    res = client.get("/api/v1/walk-in/doctors", headers=PHARM).json()
    assert res["date"] == DAY.isoformat() and res["workingDay"] is True
    john = next(d for d in res["doctors"] if d["id"] == D)
    times = [datetime.fromisoformat(s["time"]) for s in john["slots"]]
    assert at(10) in times  # the 10:00 slot is still running at 10:10
    assert at(9, 30) not in times and at(11) not in times


def test_book_with_their_doctor_today(
    client: TestClient,
    appointment_repo: InMemoryAppointmentRepository,
    inbox: InMemoryInboxRepository,
) -> None:
    res = book(client, "u-siti", D, at(10, 30))
    assert res.status_code == 201, res.text
    a = appointment_repo.appointments[res.json()["id"]]
    assert a["bookedBy"] == "pharmacist" and a["walkIn"] is True
    titles = {n["userId"]: n["title"] for n in inbox.items.values()}
    assert titles[D] == "Walk-in patient booked"
    assert titles["u-siti"] == "Appointment booked at the counter"
    # The same slot can't be taken twice.
    assert book(client, "u-ali", D, at(10, 30)).json()["error"]["code"] == "SLOT_TAKEN"


def test_wrong_doctor_past_or_odd_times_are_refused(client: TestClient) -> None:
    assert book(client, "u-siti", D2, at(11)).json()["error"]["code"] == "NOT_THEIR_DOCTOR"
    assert book(client, "u-siti", D, at(9)).json()["error"]["code"] == "INVALID_TIME"
    assert book(client, "u-siti", D, at(11, 10)).json()["error"]["code"] == "INVALID_TIME"


def test_patient_without_a_doctor_is_assigned_unless_the_doctor_is_full(
    client: TestClient, repo: InMemoryUserRepository
) -> None:
    assert book(client, "u-ali", D2, at(11)).json()["error"]["code"] == "DOCTOR_FULL"
    res = book(client, "u-ali", D, at(11))
    assert res.status_code == 201 and res.json()["assignedDoctor"] is True
    assert repo.users["u-ali"]["assignedDoctorId"] == D


def test_doctor_on_leave_today_has_no_walk_in_slots(
    client: TestClient, appointment_repo: InMemoryAppointmentRepository
) -> None:
    appointment_repo.leave["l1"] = {
        "staffId": D,
        "status": "approved",
        "startDate": DAY.isoformat(),
        "endDate": DAY.isoformat(),
    }
    john = next(
        d
        for d in client.get("/api/v1/walk-in/doctors", headers=PHARM).json()["doctors"]
        if d["id"] == D
    )
    assert john["onLeave"] is True and john["slots"] == []
    assert book(client, "u-siti", D, at(11)).json()["error"]["code"] == "DOCTOR_ON_LEAVE"

"""D-120: a doctor covers one visit for the patient's own doctor (e.g. on leave)."""

from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from app.integrations.push import LogPushClient
from app.services.cover import (
    build_cover_access,
    can_see_patient,
    cover_for,
    cover_window,
    has_cover_access,
)
from app.services.medications import MYT
from tests.conftest import (
    InMemoryAppointmentRepository,
    InMemoryProviderRepository,
    InMemoryTokenRepository,
    InMemoryUserRepository,
    bearer,
)

ADMIN, COVER = bearer("admin-token"), bearer("doctor-token")
P, OWN, COVERING = "u-patient", "u-doc2", "u-doctor"


@pytest.fixture(autouse=True)
def people(repo: InMemoryUserRepository, tokens: InMemoryTokenRepository) -> None:
    # The patient's own doctor is Dr Lim; Dr John (the test doctor token) covers.
    repo.users.update(
        {
            "u-admin": {"role": "admin", "name": "Ada"},
            P: {"role": "patient", "name": "Siti", "assignedDoctorId": OWN},
            COVERING: {"role": "doctor", "name": "Dr John"},
            OWN: {"role": "doctor", "name": "Dr Lim"},
        }
    )
    for uid in (P, OWN, COVERING):
        tokens.add(uid, f"token-{uid}", "android")


def soon(hours: int) -> datetime:
    return (datetime.now(UTC) + timedelta(hours=hours)).replace(second=0, microsecond=0)


def admin_book(client: TestClient, doctor: str, when: datetime) -> str:
    res = client.post(
        "/api/v1/admin/appointments",
        json={"patientId": P, "doctorId": doctor, "dateTime": when.isoformat()},
        headers=ADMIN,
    )
    assert res.status_code == 201, res.text
    return str(res.json()["id"])


# ---------- the window ----------


def test_window_is_the_day_before_to_seven_days_after_in_malaysia() -> None:
    visit = datetime(2026, 11, 20, 2, 0, tzinfo=UTC)  # 10:00 MYT, 20 Nov
    start, end = cover_window(visit)
    assert start == datetime(2026, 11, 19, 0, 0, tzinfo=MYT)
    assert end == datetime(2026, 11, 28, 0, 0, tzinfo=MYT)  # through 27 Nov


def test_cover_only_when_the_visit_is_with_someone_else() -> None:
    assert cover_for("b", {"assignedDoctorId": "a"}) == "a"
    assert cover_for("a", {"assignedDoctorId": "a"}) is None
    assert cover_for("b", {"assignedDoctorId": None}) is None


def test_access_spans_all_cover_visits_and_ignores_cancelled_ones() -> None:
    d1 = datetime(2026, 11, 20, 2, tzinfo=UTC)
    d2 = datetime(2026, 12, 1, 2, tzinfo=UTC)
    access = build_cover_access(
        [
            {"doctorId": "b", "coverForDoctorId": "a", "dateTime": d1, "status": "completed"},
            {"doctorId": "b", "coverForDoctorId": "a", "dateTime": d2, "status": "booked"},
            {"doctorId": "c", "coverForDoctorId": "a", "dateTime": d2, "status": "cancelled"},
            {"doctorId": "a", "dateTime": d2, "status": "booked"},  # own visit
        ]
    )
    assert set(access) == {"b"}
    assert access["b"]["from"] == cover_window(d1)[0]
    assert access["b"]["until"] == cover_window(d2)[1]


def test_access_is_checked_against_the_time() -> None:
    start, end = cover_window(datetime(2026, 11, 20, 2, tzinfo=UTC))
    patient = {"assignedDoctorId": "a", "coverAccess": {"b": {"from": start, "until": end}}}
    assert has_cover_access(patient, "b", start)
    assert not has_cover_access(patient, "b", start - timedelta(seconds=1))
    assert not has_cover_access(patient, "b", end)
    assert can_see_patient(patient, "a", end + timedelta(days=99))  # own doctor always
    assert not can_see_patient(patient, "c", start)


# ---------- API ----------


def test_d120_admin_moving_a_visit_to_another_doctor_makes_it_a_cover_visit(
    client: TestClient, appointment_repo: InMemoryAppointmentRepository, repo: InMemoryUserRepository
) -> None:
    appt_id = admin_book(client, OWN, soon(30))
    assert appointment_repo.appointments[appt_id].get("coverForDoctorId") is None
    assert repo.users[P].get("coverAccess") in (None, {})

    res = client.patch(
        f"/api/v1/admin/appointments/{appt_id}", json={"doctorId": COVERING}, headers=ADMIN
    )
    assert res.status_code == 200, res.text
    assert appointment_repo.appointments[appt_id]["coverForDoctorId"] == OWN
    assert repo.users[P]["assignedDoctorId"] == OWN  # still the own doctor's patient
    assert set(repo.users[P]["coverAccess"]) == {COVERING}

    # Moved back to the own doctor: no longer a cover visit, access removed.
    client.patch(f"/api/v1/admin/appointments/{appt_id}", json={"doctorId": OWN}, headers=ADMIN)
    assert appointment_repo.appointments[appt_id]["coverForDoctorId"] is None
    assert repo.users[P]["coverAccess"] == {}


def test_d120_admin_booking_with_another_doctor_is_a_cover_visit(
    client: TestClient, appointment_repo: InMemoryAppointmentRepository, repo: InMemoryUserRepository
) -> None:
    appt_id = admin_book(client, COVERING, soon(30))
    assert appointment_repo.appointments[appt_id]["coverForDoctorId"] == OWN
    assert COVERING in repo.users[P]["coverAccess"]


def test_d120_covering_doctor_writes_a_note_only_inside_the_window(
    client: TestClient,
    provider_repo: InMemoryProviderRepository,
    repo: InMemoryUserRepository,
) -> None:
    note = {"content": "Seen while Dr Lim was on leave. BP 150/95, continue amlodipine."}
    url = f"/api/v1/provider/patients/{P}/notes"
    assert client.post(url, json=note, headers=COVER).status_code == 403  # no cover yet

    admin_book(client, COVERING, soon(30))
    res = client.post(url, json=note, headers=COVER)
    assert res.status_code == 201, res.text
    assert provider_repo.notes[-1]["doctorId"] == COVERING  # saved with the covering doctor

    # Prescribing and the care plan stay with the own doctor.
    plan = client.put(
        f"/api/v1/provider/patients/{P}/care-plan", json={"content": "x" * 20}, headers=COVER
    )
    assert plan.status_code == 403

    # After the window the access ends.
    past = datetime.now(UTC) - timedelta(days=1)
    repo.users[P]["coverAccess"] = {
        COVERING: {"from": past - timedelta(days=9), "until": past}
    }
    assert client.post(url, json=note, headers=COVER).status_code == 403


def test_d120_cancelling_a_cover_visit_ends_the_access(
    client: TestClient, repo: InMemoryUserRepository
) -> None:
    appt_id = admin_book(client, COVERING, soon(30))
    res = client.post(
        f"/api/v1/appointments/{appt_id}/staff-cancel",
        json={"reason": "Patient asked to see their own doctor."},
        headers=ADMIN,
    )
    assert res.status_code == 200, res.text
    assert repo.users[P]["coverAccess"] == {}


def test_d120_completing_a_cover_visit_hands_over_to_the_own_doctor(
    client: TestClient, appointment_repo: InMemoryAppointmentRepository, push: LogPushClient
) -> None:
    appt_id = admin_book(client, COVERING, soon(30))
    appointment_repo.appointments[appt_id]["dateTime"] = datetime.now(UTC) - timedelta(minutes=5)
    res = client.post(
        f"/api/v1/appointments/{appt_id}/outcome", json={"outcome": "completed"}, headers=COVER
    )
    assert res.status_code == 200, res.text
    tokens, message = push.sent[-1]
    assert tokens == [f"token-{OWN}"]
    assert message.title == "Visit covered for you"
    assert "Dr John saw Siti" in message.body and "Read the note" in message.body
    assert message.data == {"type": "cover_handover", "patientId": P}


def test_d120_no_handover_for_a_no_show_or_an_own_visit(
    client: TestClient, appointment_repo: InMemoryAppointmentRepository, push: LogPushClient
) -> None:
    appt_id = admin_book(client, COVERING, soon(30))
    appointment_repo.appointments[appt_id]["dateTime"] = datetime.now(UTC) - timedelta(minutes=5)
    before = len(push.sent)
    client.post(
        f"/api/v1/appointments/{appt_id}/outcome", json={"outcome": "no_show"}, headers=COVER
    )
    assert all(m.title != "Visit covered for you" for _, m in push.sent[before:])

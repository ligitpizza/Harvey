"""D-86 an emergency becomes a PDF summary in the patient's Health Records."""

import pytest
from fastapi.testclient import TestClient

from tests.conftest import (
    InMemoryFileStore,
    InMemoryRecordRepository,
    InMemoryUserRepository,
    InMemoryVitalsRepository,
    bearer,
)
from tests.test_triage import post as triage_post

PATIENT = bearer("patient-token")


@pytest.fixture(autouse=True)
def people(repo: InMemoryUserRepository) -> None:
    repo.users["u-patient"] = {
        "role": "patient",
        "name": "Siti",
        "email": "s@x.my",
        "assignedDoctorId": "u-doctor",
    }
    repo.users["u-doctor"] = {"role": "doctor", "name": "Dr John"}


def _emergency_records(records: InMemoryRecordRepository) -> list[dict]:
    return [r for r in records.records.values() if r.get("category") == "emergency"]


def test_crisis_reading_saves_an_emergency_summary_shared_with_the_doctor(
    client: TestClient,
    repo: InMemoryUserRepository,
    record_repo: InMemoryRecordRepository,
    file_store: InMemoryFileStore,
) -> None:
    res = client.post("/api/v1/vitals", json={"systolic": 185, "diastolic": 122}, headers=PATIENT)
    assert res.status_code == 201
    [rec] = _emergency_records(record_repo)
    assert rec["patientId"] == "u-patient"
    assert rec["sharedWithDoctor"] is True
    assert rec["contentType"] == "application/pdf"
    assert rec["fileName"].startswith("Emergency event")
    data, kind = file_store.files[rec["fileUrl"]]
    assert kind == "application/pdf" and data.startswith(b"%PDF")


def test_normal_reading_saves_no_summary(
    client: TestClient, record_repo: InMemoryRecordRepository
) -> None:
    client.post("/api/v1/vitals", json={"systolic": 118, "diastolic": 76}, headers=PATIENT)
    assert _emergency_records(record_repo) == []


def test_emergency_symptom_check_saves_a_summary(
    client: TestClient,
    vitals_repo: InMemoryVitalsRepository,
    record_repo: InMemoryRecordRepository,
) -> None:
    body = triage_post(client, vitals_repo, symptoms=["chest_pain"], severity="severe").json()
    assert body["outcome"] == "seek_emergency_care"
    [rec] = _emergency_records(record_repo)
    assert rec["sharedWithDoctor"] is True


def test_the_pdf_lists_vitals_risk_and_who_was_told() -> None:
    from datetime import UTC, datetime

    from app.services.emergency_record import EmergencyEvent, emergency_pdf

    pdf = emergency_pdf(
        EmergencyEvent(
            patient_id="p",
            patient_name="Siti",
            trigger="Crisis BP",
            at=datetime(2026, 11, 13, 4, tzinfo=UTC),
            systolic=190,
            diastolic=125,
            heart_rate=110,
            risk_lines=["Stroke: high (31%)"],
            notified=["Assigned doctor: Dr John"],
            appointment="Fri 13 Nov, 1:00 PM with Dr John",
        )
    )
    assert pdf.startswith(b"%PDF") and len(pdf) > 1000

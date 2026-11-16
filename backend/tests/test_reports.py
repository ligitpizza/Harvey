"""D-100: health summary, weekly summary PDF and doctor report saved to Health Records."""

from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from app.integrations.push import LogPushClient
from app.services.health_report import report_pdf, snapshot
from tests.conftest import (
    InMemoryAgentDataRepository,
    InMemoryAuditLogger,
    InMemoryFileStore,
    InMemoryRecordRepository,
    InMemoryTokenRepository,
    InMemoryUserRepository,
    InMemoryVitalsRepository,
    bearer,
)

P, D = "u-patient", "u-doctor"
PATIENT, DOCTOR = bearer("patient-token"), bearer("doctor-token")


@pytest.fixture(autouse=True)
def people(
    repo: InMemoryUserRepository,
    tokens: InMemoryTokenRepository,
    vitals_repo: InMemoryVitalsRepository,
    agent_repo: InMemoryAgentDataRepository,
) -> None:
    repo.users[P] = {"role": "patient", "name": "Siti", "assignedDoctorId": D}
    repo.users[D] = {"role": "doctor", "name": "Dr John"}
    tokens.add(P, "token-of-patient", "android")
    now = datetime.now(UTC)
    for i, (s, d) in enumerate([(150, 95), (132, 84), (120, 78)]):
        vitals_repo.readings[f"v{i}"] = {
            "patientId": P,
            "systolic": s,
            "diastolic": d,
            "heartRate": 72,
            "timestamp": now - timedelta(days=i),
        }
    agent_repo.meds[P] = [
        {"name": "Amlodipine 5mg", "dosage": "1 tablet", "schedule": "08:00", "adherenceRate": 90}
    ]


def test_snapshot_reads_the_last_30_days(agent_repo: InMemoryAgentDataRepository) -> None:
    s = snapshot(agent_repo, P, datetime.now(UTC))
    assert (s.patient_name, s.doctor_name, s.readings) == ("Siti", "Dr John", 3)
    assert s.highest and s.highest.startswith("150/95")
    assert s.lowest and s.lowest.startswith("120/78")
    assert s.average and s.average.startswith("134/86")
    assert s.medicines == [("Amlodipine 5mg 1 tablet", "08:00", "90%")]
    pdf = report_pdf("Health summary", s, datetime.now(UTC), text="Hello", text_heading="Note")
    assert pdf.startswith(b"%PDF") and b"/Subtype /Image" in pdf  # the logo


def test_patient_creates_a_health_summary(
    client: TestClient,
    record_repo: InMemoryRecordRepository,
    file_store: InMemoryFileStore,
    audit: InMemoryAuditLogger,
) -> None:
    res = client.post("/api/v1/records/health-summary", headers=PATIENT)
    assert res.status_code == 201
    body = res.json()
    assert body["category"] == "health_summary" and body["sharedWithDoctor"] is False
    r = record_repo.records[body["id"]]
    assert r["patientId"] == P and r["fileName"].startswith("Health summary")
    assert file_store.files[r["fileUrl"]][0].startswith(b"%PDF")
    assert audit.entries[-1]["action"] == "CREATE_HEALTH_SUMMARY"
    # The patient may share it like any record.
    assert client.post(f"/api/v1/records/{body['id']}/share", headers=PATIENT).status_code == 200
    assert client.post("/api/v1/records/health-summary", headers=DOCTOR).status_code == 403


def test_weekly_summary_saved_once_from_the_stored_text(
    client: TestClient,
    agent_repo: InMemoryAgentDataRepository,
    record_repo: InMemoryRecordRepository,
) -> None:
    agent_repo.add_message(P, "agent", "Your weekly health summary", {"kind": "weekly_summary"})
    agent_repo.add_message(P, "agent", "An ordinary reply")
    url = "/api/v1/agent/messages/{}/save-pdf"
    res = client.post(url.format("msg1"), headers=PATIENT)
    assert res.status_code == 201
    assert res.json()["category"] == "health_summary"
    assert res.json()["fileName"].startswith("Weekly health summary")
    assert agent_repo.messages[0]["savedRecordId"] == res.json()["id"]
    again = client.post(url.format("msg1"), headers=PATIENT)
    assert again.json()["error"]["code"] == "SUMMARY_ALREADY_SAVED"
    # Only weekly summaries, only the patient's own.
    assert client.post(url.format("msg2"), headers=PATIENT).status_code == 404
    agent_repo.add_message("someone-else", "agent", "x", {"kind": "weekly_summary"})
    assert client.post(url.format("msg3"), headers=PATIENT).status_code == 404
    # Deleted from Records: it can be saved again.
    record_repo.records.pop(res.json()["id"])
    assert client.post(url.format("msg1"), headers=PATIENT).status_code == 201


def test_doctor_report_is_shared_and_read_only_for_the_patient(
    client: TestClient,
    repo: InMemoryUserRepository,
    record_repo: InMemoryRecordRepository,
    push: LogPushClient,
) -> None:
    url = f"/api/v1/provider/patients/{P}/reports"
    body = {"title": "Review after 4 weeks", "content": "BP improving. Continue amlodipine."}
    assert client.post(url, json={**body, "content": "short"}, headers=DOCTOR).status_code == 422
    assert client.post(url, json=body, headers=PATIENT).status_code == 403
    res = client.post(url, json=body, headers=DOCTOR)
    assert res.status_code == 201
    rid = res.json()["id"]
    r = record_repo.records[rid]
    assert r["category"] == "doctor_report" and r["sharedWithDoctor"] is True
    assert (r["authorId"], r["authorName"]) == (D, "Dr John")
    assert "New report from your doctor" in [m.title for _, m in push.sent]
    # Both can open it.
    assert client.get(f"/api/v1/records/{rid}/file", headers=PATIENT).status_code == 200
    assert client.get(f"/api/v1/records/{rid}/file", headers=DOCTOR).status_code == 200
    # The patient can't change, unshare or delete it.
    for res in (
        client.patch(f"/api/v1/records/{rid}", json={"category": "other"}, headers=PATIENT),
        client.delete(f"/api/v1/records/{rid}/share", headers=PATIENT),
        client.delete(f"/api/v1/records/{rid}", headers=PATIENT),
    ):
        assert res.json()["error"]["code"] == "RECORD_LOCKED"
    # Only the assigned doctor writes reports.
    repo.users[P]["assignedDoctorId"] = "someone-else"
    assert client.post(url, json=body, headers=DOCTOR).status_code == 403

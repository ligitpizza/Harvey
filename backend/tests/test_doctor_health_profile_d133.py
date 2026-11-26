"""D-133: the assigned doctor views and corrects the patient's health profile (UC12.2 data).
Changed fields are tagged with the doctor's name; the patient is told and can change them
back, which removes the tag. Risk inputs changed -> re-scored."""

import json
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.integrations.push import LogPushClient
from tests.conftest import (
    InMemoryAuditLogger,
    InMemoryRiskRepository,
    InMemoryTokenRepository,
    InMemoryUserRepository,
    InMemoryVitalsRepository,
    bearer,
)

P = "u-patient"
DOCTOR = bearer("doctor-token")
PATIENT = bearer("patient-token")
URL = f"/api/v1/provider/patients/{P}/health-profile"

HISTORY = {
    "hypertensionDiagnosedYear": 2020,
    "conditions": [],
    "familyHistory": ["heart_disease"],
    "allergies": "",
    "notes": "",
}
LIFESTYLE = {
    "smokingStatus": "never",
    "alcohol": "none",
    "exerciseDaysPerWeek": 3,
    "saltIntake": "moderate",
}


@pytest.fixture(autouse=True)
def people(repo: InMemoryUserRepository, vitals_repo: InMemoryVitalsRepository) -> None:
    repo.users[P] = {
        "role": "patient",
        "name": "Siti",
        "isActive": True,
        "onboardingComplete": True,
        "gender": "female",
        "dateOfBirth": datetime(1970, 3, 1, tzinfo=UTC),
        "assignedDoctorId": "u-doctor",
    }
    repo.users["u-doctor"] = {"role": "doctor", "name": "Tan Mei Ling", "isActive": True}
    repo.health_profiles[P] = {
        "patientId": P,
        "personalInfo": json.dumps({"heightCm": 165, "weightKg": 70, "phone": "+60 12-345 6789"}),
        "medicalHistory": json.dumps(HISTORY),
        "lifestyleFactors": json.dumps(LIFESTYLE),
    }
    for i, (s, d) in enumerate([(150, 95), (145, 92), (148, 94)]):
        vitals_repo.add_reading(
            {
                "patientId": P,
                "systolic": s,
                "diastolic": d,
                "timestamp": datetime.now(UTC) - timedelta(days=3 - i),
            }
        )


def body(**changes: Any) -> dict[str, Any]:
    b: dict[str, Any] = {
        "heightCm": 165,
        "weightKg": 70,
        "medicalHistory": dict(HISTORY),
        "lifestyleFactors": dict(LIFESTYLE),
    }
    b.update(changes)
    return b


def test_d133_doctor_edit_tags_only_changed_fields_and_rescores(
    client: TestClient,
    repo: InMemoryUserRepository,
    risk_repo: InMemoryRiskRepository,
    audit: InMemoryAuditLogger,
    push: LogPushClient,
) -> None:
    b = body(weightKg=82, lifestyleFactors={**LIFESTYLE, "smokingStatus": "current"})
    r = client.put(URL, json=b, headers=DOCTOR)
    assert r.status_code == 200, r.text
    assert r.json()["changed"] == ["weightKg", "smokingStatus"]
    assert r.json()["rescored"] is True and len(risk_repo.saved) == 1

    hp = repo.health_profiles[P]
    assert json.loads(hp["personalInfo"])["weightKg"] == 82
    assert json.loads(hp["personalInfo"])["phone"] == "+60 12-345 6789"  # contact kept
    assert set(hp["doctorEdits"]) == {"weightKg", "smokingStatus"}
    tag = hp["doctorEdits"]["smokingStatus"]
    assert tag["by"] == "u-doctor" and tag["byName"] == "Dr Tan Mei Ling"
    assert isinstance(tag["at"], datetime)
    assert "DOCTOR_UPDATE_HEALTH_PROFILE" in audit.actions()


def test_d133_patient_is_notified(
    client: TestClient, tokens: InMemoryTokenRepository, push: LogPushClient
) -> None:
    tokens.add(P, "patient-phone", "android")
    client.put(
        URL, json=body(medicalHistory={**HISTORY, "allergies": "Penicillin"}), headers=DOCTOR
    )
    msgs = [m for t, m in push.sent if "patient-phone" in t]
    assert msgs and msgs[-1].title == "Dr Tan Mei Ling updated your health profile"
    assert "Allergies" in msgs[-1].body and msgs[-1].data["type"] == "health_profile"


def test_d133_no_change_saves_nothing_and_sends_nothing(
    client: TestClient, repo: InMemoryUserRepository, push: LogPushClient
) -> None:
    r = client.put(URL, json=body(), headers=DOCTOR)
    assert r.json() == {"status": "ok", "changed": [], "rescored": False}
    assert not repo.health_profiles[P].get("doctorEdits")
    assert push.sent == []


def test_d133_patient_change_removes_only_that_tag(
    client: TestClient, repo: InMemoryUserRepository
) -> None:
    b = body(weightKg=82, lifestyleFactors={**LIFESTYLE, "smokingStatus": "current"})
    client.put(URL, json=b, headers=DOCTOR)
    # The patient changes smoking back and leaves the doctor's weight alone.
    mine = body(weightKg=82)
    r = client.put("/api/v1/settings/health-profile", json=mine, headers=PATIENT)
    assert r.status_code == 200, r.text
    assert set(repo.health_profiles[P]["doctorEdits"]) == {"weightKg"}


def test_d133_only_the_assigned_doctor_may_edit(
    client: TestClient, repo: InMemoryUserRepository
) -> None:
    repo.users[P]["assignedDoctorId"] = "someone-else"
    r = client.put(URL, json=body(weightKg=82), headers=DOCTOR)
    assert r.status_code == 403
    assert json.loads(repo.health_profiles[P]["personalInfo"])["weightKg"] == 70
    # Patients and other roles can't use the doctor endpoint.
    assert client.put(URL, json=body(weightKg=82), headers=PATIENT).status_code == 403


def test_d133_needs_a_finished_onboarding(client: TestClient, repo: InMemoryUserRepository) -> None:
    repo.users[P]["onboardingComplete"] = False
    r = client.put(URL, json=body(weightKg=82), headers=DOCTOR)
    assert r.status_code == 409


def test_d133_out_of_range_values_are_rejected(client: TestClient) -> None:
    assert client.put(URL, json=body(heightCm=20), headers=DOCTOR).status_code == 422

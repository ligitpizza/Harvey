"""D-130: a MyKad/passport patient (D-129) adds a verified contact email for reminders and
password reset (FR-1.2 forgot password, FR-12.x settings, D-80 email codes)."""

import re
from typing import Any

from fastapi.testclient import TestClient

from tests.conftest import (
    ConsoleEmailClient,
    FakeIdentityProvider,
    InMemoryUserRepository,
    bearer,
)

PATIENT = bearer("patient-token")  # uid u-patient
PHARM = bearer("pharmacist-token")
DOCTOR = bearer("doctor-token")
BASE = "/api/v1/settings/contact-email"
ALIAS = "880202145566@id.harvey.invalid"


def _id_patient(repo: InMemoryUserRepository, identity: FakeIdentityProvider) -> None:
    repo.users["u-patient"] = {
        "role": "patient",
        "name": "Ah Kow",
        "email": None,
        "icNumber": "880202-14-5566",
        "isActive": True,
    }
    identity.emails[ALIAS] = "u-patient"


def _last_code(emails: ConsoleEmailClient) -> str:
    m = re.search(r"\b(\d{6})\b", emails.sent[-1].text)
    assert m
    return m.group(1)


def _add(client: TestClient, emails: ConsoleEmailClient, email: str = "kow@x.my") -> Any:
    assert client.post(f"{BASE}/request", json={"email": email}, headers=PATIENT).status_code == 200
    return client.post(
        f"{BASE}/verify", json={"email": email, "code": _last_code(emails)}, headers=PATIENT
    )


def test_d130_patient_adds_a_verified_contact_email(
    client: TestClient,
    repo: InMemoryUserRepository,
    identity: FakeIdentityProvider,
    emails: ConsoleEmailClient,
) -> None:
    _id_patient(repo, identity)
    r = client.post(f"{BASE}/request", json={"email": "Kow@X.my"}, headers=PATIENT)
    assert r.status_code == 200, r.text
    assert emails.sent[-1].to_email == "kow@x.my"
    assert "contactEmail" not in repo.users["u-patient"]  # not saved before the code

    bad = client.post(
        f"{BASE}/verify", json={"email": "kow@x.my", "code": "000000"}, headers=PATIENT
    )
    assert bad.status_code == 400 and "4 tries left" in bad.json()["error"]["message"]

    ok = client.post(
        f"{BASE}/verify", json={"email": "kow@x.my", "code": _last_code(emails)}, headers=PATIENT
    )
    assert ok.status_code == 200, ok.text
    assert repo.users["u-patient"]["contactEmail"] == "kow@x.my"
    # Sign-in is unchanged: still the MyKad alias.
    assert identity.emails[ALIAS] == "u-patient"

    assert client.delete(BASE, headers=PATIENT).status_code == 204
    assert repo.users["u-patient"].get("contactEmail") is None


def test_d130_code_is_for_the_address_it_was_sent_to(
    client: TestClient,
    repo: InMemoryUserRepository,
    identity: FakeIdentityProvider,
    emails: ConsoleEmailClient,
) -> None:
    _id_patient(repo, identity)
    client.post(f"{BASE}/request", json={"email": "kow@x.my"}, headers=PATIENT)
    r = client.post(
        f"{BASE}/verify", json={"email": "other@x.my", "code": _last_code(emails)}, headers=PATIENT
    )
    assert r.status_code == 400
    assert "contactEmail" not in repo.users["u-patient"]


def test_d130_email_already_used_or_email_login_is_refused(
    client: TestClient,
    repo: InMemoryUserRepository,
    identity: FakeIdentityProvider,
) -> None:
    _id_patient(repo, identity)
    identity.emails["taken@x.my"] = "u-someone"
    repo.users["u-other"] = {"role": "patient", "contactEmail": "used@x.my"}
    for email in ("taken@x.my", "used@x.my"):
        r = client.post(f"{BASE}/request", json={"email": email}, headers=PATIENT)
        assert r.status_code == 409 and r.json()["error"]["code"] == "EMAIL_IN_USE"
    repo.users["u-patient"]["email"] = "real@x.my"
    r = client.post(f"{BASE}/request", json={"email": "kow@x.my"}, headers=PATIENT)
    assert r.status_code == 409 and r.json()["error"]["code"] == "HAS_EMAIL"


def test_d130_three_codes_per_15_minutes(
    client: TestClient, repo: InMemoryUserRepository, identity: FakeIdentityProvider
) -> None:
    _id_patient(repo, identity)
    for _ in range(3):
        assert (
            client.post(f"{BASE}/request", json={"email": "kow@x.my"}, headers=PATIENT).status_code
            == 200
        )
    r = client.post(f"{BASE}/request", json={"email": "kow@x.my"}, headers=PATIENT)
    assert r.status_code == 429


def test_d130_forgot_password_code_goes_to_the_contact_email(
    client: TestClient,
    repo: InMemoryUserRepository,
    identity: FakeIdentityProvider,
    emails: ConsoleEmailClient,
) -> None:
    _id_patient(repo, identity)
    assert _add(client, emails).status_code == 200
    r = client.post("/api/v1/auth/password-otp/request", json={"email": "kow@x.my"})
    assert r.status_code == 202
    assert emails.sent[-1].to_email == "kow@x.my"
    ok = client.post(
        "/api/v1/auth/password-otp/verify",
        json={"email": "kow@x.my", "code": _last_code(emails), "newPassword": "NewPass123"},
    )
    assert ok.status_code == 200, ok.text
    assert identity.passwords["u-patient"] == "NewPass123"


def test_d130_counter_adds_it_with_the_patient_present(
    client: TestClient,
    repo: InMemoryUserRepository,
    identity: FakeIdentityProvider,
    emails: ConsoleEmailClient,
) -> None:
    _id_patient(repo, identity)
    url = "/api/v1/walk-in/patients/u-patient/contact-email"
    assert (
        client.post(f"{url}/request", json={"email": "kow@x.my"}, headers=DOCTOR).status_code == 403
    )
    assert (
        client.post(f"{url}/request", json={"email": "kow@x.my"}, headers=PHARM).status_code == 200
    )
    r = client.post(
        f"{url}/verify", json={"email": "kow@x.my", "code": _last_code(emails)}, headers=PHARM
    )
    assert r.status_code == 200, r.text
    assert repo.users["u-patient"]["contactEmail"] == "kow@x.my"
    rows = client.get("/api/v1/walk-in/patients?q=kow@x", headers=PHARM).json()["patients"]
    assert rows[0]["contactEmail"] == "kow@x.my" and rows[0]["hasEmail"] is False

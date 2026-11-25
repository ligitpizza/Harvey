"""D-129: a walk-in patient without an email signs in with MyKad/passport and a counter code
(UC1.1 registration at the counter, UC1.2 sign-in, D-80 walk-in, D-103 MyKad or passport)."""

from typing import Any

from fastapi.testclient import TestClient

from app.services.login_alias import is_alias, login_alias
from tests.conftest import (
    ConsoleEmailClient,
    FakeIdentityProvider,
    InMemoryAuditLogger,
    InMemoryUserRepository,
    bearer,
)

PHARM = bearer("pharmacist-token")
DOCTOR = bearer("doctor-token")
IC = "880202-14-5566"
ALIAS = "880202145566@id.harvey.invalid"


def register(client: TestClient, **extra: Any) -> Any:
    return client.post(
        "/api/v1/walk-in/patients",
        json={"name": "Mei Ling", "icNumber": IC, **extra},
        headers=PHARM,
    )


def verify(client: TestClient, email: str, code: str, password: str = "NewPass123") -> Any:
    return client.post(
        "/api/v1/auth/password-otp/verify",
        json={"email": email, "code": code, "newPassword": password},
    )


def test_d129_alias_matches_the_app_rule() -> None:
    assert login_alias("880202-14-5566") == ALIAS
    assert login_alias(" A1234567 ") == "a1234567@id.harvey.invalid"
    assert is_alias(ALIAS) and not is_alias("mei@x.my") and not is_alias(None)


def test_d129_no_email_gives_a_counter_code_that_sets_the_password(
    client: TestClient,
    repo: InMemoryUserRepository,
    identity: FakeIdentityProvider,
    emails: ConsoleEmailClient,
    audit: InMemoryAuditLogger,
) -> None:
    sent_before = len(emails.sent)
    res = register(client, phone="012-345 6789")

    assert res.status_code == 201, res.text
    body = res.json()
    uid = body["uid"]
    assert len(body["setupCode"]) == 6 and body["setupLink"] is None
    assert body["emailSent"] is False and len(emails.sent) == sent_before
    assert identity.emails[ALIAS] == uid  # the Firebase login is the alias
    user = repo.users[uid]
    assert user["email"] is None and user["phone"] == "+60123456789"
    assert user["icNumber"] and user["onboardingComplete"] is False
    assert any("counter setup code" in e["details"] for e in audit.entries)

    ok = verify(client, ALIAS, body["setupCode"])
    assert ok.status_code == 200, ok.text
    assert identity.passwords[uid] == "NewPass123"
    assert verify(client, ALIAS, body["setupCode"]).status_code == 400  # used once


def test_d129_email_and_phone_are_optional_but_checked(client: TestClient) -> None:
    assert register(client, phone="12345").status_code == 422
    assert register(client, email="not-an-email").status_code == 422
    with_email = register(client, email="mei@x.my", phone="")
    assert with_email.status_code == 201
    assert with_email.json()["setupCode"] is None


def test_d129_forgot_password_never_emails_or_replaces_a_counter_code(
    client: TestClient, emails: ConsoleEmailClient
) -> None:
    code = register(client).json()["setupCode"]
    sent = len(emails.sent)
    for path in ("/api/v1/auth/password-otp/request", "/api/v1/auth/password-reset"):
        r = client.post(path, json={"email": ALIAS})
        assert r.status_code == 202
    assert len(emails.sent) == sent
    assert verify(client, ALIAS, code).status_code == 200


def test_d129_counter_issues_a_new_code_for_a_no_email_patient_only(
    client: TestClient, repo: InMemoryUserRepository, identity: FakeIdentityProvider
) -> None:
    first = register(client).json()
    uid = first["uid"]

    again = client.post(f"/api/v1/walk-in/patients/{uid}/setup-code", headers=PHARM)
    assert again.status_code == 200, again.text
    new = again.json()["setupCode"]
    assert verify(client, ALIAS, first["setupCode"]).status_code == 400  # replaced
    assert verify(client, ALIAS, new).status_code == 200

    repo.users["u-mail"] = {"role": "patient", "name": "Ali", "email": "ali@x.my"}
    r = client.post("/api/v1/walk-in/patients/u-mail/setup-code", headers=PHARM)
    assert r.status_code == 409 and r.json()["error"]["code"] == "HAS_EMAIL"
    assert (
        client.post("/api/v1/walk-in/patients/nobody/setup-code", headers=PHARM).status_code == 404
    )
    assert (
        client.post(f"/api/v1/walk-in/patients/{uid}/setup-code", headers=DOCTOR).status_code == 403
    )


def test_d129_find_a_patient_by_phone(client: TestClient) -> None:
    uid = register(client, phone="012-345 6789").json()["uid"]
    rows = client.get("/api/v1/walk-in/patients?q=0123456789", headers=PHARM).json()["patients"]
    assert [r["id"] for r in rows] == [uid]
    assert rows[0]["hasEmail"] is False and rows[0]["phone"] == "+60123456789"

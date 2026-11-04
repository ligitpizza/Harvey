"""D-80 password reset by email OTP (UC1.2 forgot password, FR-1.2)."""

import re
from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient

from app.routers.password_otp import email_key
from tests.conftest import (
    ConsoleEmailClient,
    FakeIdentityProvider,
    InMemoryAuditLogger,
    InMemoryPasswordOtpRepository,
)

BASE = "/api/v1/auth/password-otp"
EMAIL = "taken@example.com"  # exists in FakeIdentityProvider as u-existing


def _code(emails: ConsoleEmailClient) -> str:
    m = re.search(r"\b(\d{6})\b", emails.sent[-1].text)
    assert m
    return m.group(1)


def test_request_emails_a_code_and_stores_only_a_hash(
    client: TestClient, emails: ConsoleEmailClient, password_otps: InMemoryPasswordOtpRepository
) -> None:
    r = client.post(f"{BASE}/request", json={"email": "Taken@Example.com"})
    assert r.status_code == 202
    assert r.json() == {"status": "sent_if_exists"}
    code = _code(emails)
    assert emails.sent[-1].to_email == EMAIL
    stored = password_otps.items[email_key(EMAIL)]
    assert code not in str(stored)  # never the plain code
    assert EMAIL not in str(stored)  # nor the address
    assert stored["uid"] == "u-existing"


def test_unknown_email_gets_the_same_answer_and_no_email(
    client: TestClient, emails: ConsoleEmailClient, password_otps: InMemoryPasswordOtpRepository
) -> None:
    r = client.post(f"{BASE}/request", json={"email": "nobody@example.com"})
    assert r.status_code == 202
    assert r.json() == {"status": "sent_if_exists"}
    assert emails.sent == []
    assert password_otps.items == {}


def test_verify_sets_the_password_and_signs_out_other_devices(
    client: TestClient,
    emails: ConsoleEmailClient,
    identity: FakeIdentityProvider,
    audit: InMemoryAuditLogger,
) -> None:
    client.post(f"{BASE}/request", json={"email": EMAIL})
    r = client.post(
        f"{BASE}/verify",
        json={"email": EMAIL, "code": _code(emails), "newPassword": "NewPass123"},
    )
    assert r.status_code == 200, r.text
    assert identity.passwords["u-existing"] == "NewPass123"
    assert "u-existing" in identity.revoked
    assert any(e["action"] == "PASSWORD_RESET_BY_OTP" for e in audit.entries)
    # A code works once.
    again = client.post(
        f"{BASE}/verify",
        json={"email": EMAIL, "code": _code(emails), "newPassword": "Another123"},
    )
    assert again.status_code == 400
    assert again.json()["error"]["code"] == "INVALID_CODE"


def test_wrong_code_counts_down_then_locks(
    client: TestClient, emails: ConsoleEmailClient, identity: FakeIdentityProvider
) -> None:
    client.post(f"{BASE}/request", json={"email": EMAIL})
    good = _code(emails)
    wrong = "000000" if good != "000000" else "111111"
    for left in (4, 3, 2, 1):
        r = client.post(
            f"{BASE}/verify", json={"email": EMAIL, "code": wrong, "newPassword": "NewPass123"}
        )
        assert r.status_code == 400
        assert f"{left} tr" in r.json()["error"]["message"]
    r = client.post(
        f"{BASE}/verify", json={"email": EMAIL, "code": wrong, "newPassword": "NewPass123"}
    )
    assert r.json()["error"]["code"] == "TOO_MANY_TRIES"
    # Even the right code no longer works.
    r = client.post(
        f"{BASE}/verify", json={"email": EMAIL, "code": good, "newPassword": "NewPass123"}
    )
    assert r.status_code == 400
    assert "u-existing" not in identity.passwords


def test_expired_code_is_refused(
    client: TestClient, emails: ConsoleEmailClient, password_otps: InMemoryPasswordOtpRepository
) -> None:
    client.post(f"{BASE}/request", json={"email": EMAIL})
    key = email_key(EMAIL)
    password_otps.items[key]["expiresAt"] = datetime.now(UTC) - timedelta(seconds=1)
    r = client.post(
        f"{BASE}/verify",
        json={"email": EMAIL, "code": _code(emails), "newPassword": "NewPass123"},
    )
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "INVALID_CODE"


def test_at_most_three_codes_per_15_minutes(client: TestClient) -> None:
    for _ in range(3):
        assert client.post(f"{BASE}/request", json={"email": EMAIL}).status_code == 202
    r = client.post(f"{BASE}/request", json={"email": EMAIL})
    assert r.status_code == 429


def test_weak_password_is_refused_before_the_code_is_used(
    client: TestClient, emails: ConsoleEmailClient, identity: FakeIdentityProvider
) -> None:
    client.post(f"{BASE}/request", json={"email": EMAIL})
    r = client.post(
        f"{BASE}/verify",
        json={"email": EMAIL, "code": _code(emails), "newPassword": "lettersonly"},
    )
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "WEAK_PASSWORD"
    ok = client.post(
        f"{BASE}/verify",
        json={"email": EMAIL, "code": _code(emails), "newPassword": "Letters123"},
    )
    assert ok.status_code == 200
    assert identity.passwords["u-existing"] == "Letters123"

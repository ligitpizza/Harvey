"""D-131: a patient signs in with any of their identifiers (UC1.2): the login email, the
MyKad/passport number (D-129) or the verified contact email (D-130)."""

from fastapi.testclient import TestClient

from tests.conftest import FakeIdentityProvider, InMemoryUserRepository

URL = "/api/v1/auth/resolve-sign-in"
ALIAS = "041229070447@id.harvey.invalid"


def _people(repo: InMemoryUserRepository, identity: FakeIdentityProvider) -> None:
    # Walk-in, MyKad login, contact email added later.
    repo.users["u-ic"] = {
        "role": "patient",
        "email": None,
        "icNumber": "041229-07-0447",
        "contactEmail": "kow+user1@x.my",
    }
    identity.emails[ALIAS] = "u-ic"
    identity.passwords["u-ic"] = "Yoo_jews1"
    # Self-registered with email, MyKad added in the profile later.
    repo.users["u-mail"] = {
        "role": "patient",
        "email": "kow@x.my",
        "icNumber": "081229-78-0003",
    }
    identity.emails["kow@x.my"] = "u-mail"
    identity.passwords["u-mail"] = "Secret123"
    repo.users["u-doc"] = {"role": "doctor", "email": "doc@x.my", "contactEmail": "d@x.my"}
    identity.emails["doc@x.my"] = "u-doc"
    identity.passwords["u-doc"] = "Doctor123"


def test_d131_contact_email_resolves_to_the_id_login(
    client: TestClient, repo: InMemoryUserRepository, identity: FakeIdentityProvider
) -> None:
    _people(repo, identity)
    r = client.post(URL, json={"identifier": "Kow+User1@x.my", "password": "Yoo_jews1"})
    assert r.status_code == 200, r.text
    assert r.json() == {"email": ALIAS}


def test_d131_mykad_resolves_to_the_email_login(
    client: TestClient, repo: InMemoryUserRepository, identity: FakeIdentityProvider
) -> None:
    _people(repo, identity)
    for typed in ("081229-78-0003", "081229780003"):
        r = client.post(URL, json={"identifier": typed, "password": "Secret123"})
        assert r.status_code == 200, r.text
        assert r.json() == {"email": "kow@x.my"}


def test_d131_nothing_is_revealed_without_the_right_password(
    client: TestClient, repo: InMemoryUserRepository, identity: FakeIdentityProvider
) -> None:
    _people(repo, identity)
    cases = [
        {"identifier": "081229780003", "password": "wrong"},  # real IC, wrong password
        {"identifier": "kow+user1@x.my", "password": "nope"},
        {"identifier": "900101145678", "password": "Secret123"},  # nobody's IC
        {"identifier": "nobody@x.my", "password": "Secret123"},
        {"identifier": "1234", "password": "Secret123"},  # not an ID
        {"identifier": "d@x.my", "password": "Doctor123"},  # staff: patients only
    ]
    for body in cases:
        r = client.post(URL, json=body)
        assert r.status_code == 400, body
        err = r.json()["error"]
        assert err["code"] == "INVALID_CREDENTIALS"
        assert err["message"] == "Incorrect email or password."
        assert "email" not in r.json()


def test_d131_deactivated_login_is_not_resolved(
    client: TestClient, repo: InMemoryUserRepository, identity: FakeIdentityProvider
) -> None:
    _people(repo, identity)
    identity.disabled.add("u-mail")
    r = client.post(URL, json={"identifier": "081229780003", "password": "Secret123"})
    assert r.status_code == 400


def test_d131_passport_resolves_both_ways(
    client: TestClient, repo: InMemoryUserRepository, identity: FakeIdentityProvider
) -> None:
    # Email account with a passport added later: the passport (any case) finds the email login.
    repo.users["u-pp"] = {
        "role": "patient",
        "email": "budi@x.id",
        "passportNumber": "B9876543",
        "nationality": "Indonesia",
    }
    identity.emails["budi@x.id"] = "u-pp"
    identity.passwords["u-pp"] = "Secret123"
    for typed in ("B9876543", "b9876543"):
        r = client.post(URL, json={"identifier": typed, "password": "Secret123"})
        assert r.json() == {"email": "budi@x.id"}, typed
    # Walk-in passport login with a contact email: the email finds the passport alias.
    repo.users["u-pp2"] = {
        "role": "patient",
        "email": None,
        "passportNumber": "A1234567",
        "contactEmail": "siti@x.id",
    }
    identity.emails["a1234567@id.harvey.invalid"] = "u-pp2"
    identity.passwords["u-pp2"] = "Secret123"
    r = client.post(URL, json={"identifier": "siti@x.id", "password": "Secret123"})
    assert r.json() == {"email": "a1234567@id.harvey.invalid"}
    bad = client.post(URL, json={"identifier": "A1234567", "password": "wrong"})
    assert bad.status_code == 400

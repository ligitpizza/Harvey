"""D-128: a device's push token belongs only to the account signed in on it (D-33, FR-14.2)."""

from __future__ import annotations

from typing import Any

from fastapi.testclient import TestClient

from app.services.notifications import FirestoreTokenRepository
from tests.conftest import InMemoryTokenRepository, bearer

BODY = {"token": "fcm-token-shared-phone", "platform": "android"}


def test_d128_family_sign_in_takes_the_token_from_the_patient(
    client: TestClient, tokens: InMemoryTokenRepository
) -> None:
    # The patient signed out but the unregister call failed, so the token stayed.
    tokens.add("u-patient", BODY["token"], "android")
    tokens.add("u-patient", "patient-other-phone", "android")

    res = client.post("/api/v1/devices/fcm-token", json=BODY, headers=bearer("family-token"))

    assert res.status_code == 204
    assert tokens.tokens("u-family") == [BODY["token"]]
    # The patient's alerts no longer reach this phone; their other phone keeps them.
    assert tokens.tokens("u-patient") == ["patient-other-phone"]


# ---------- Firestore implementation (collection-group scan) ----------


class _Owner:
    def __init__(self, uid: str) -> None:
        self.id = uid


class _Parent:
    def __init__(self, uid: str) -> None:
        self.parent = _Owner(uid)


class _Ref:
    """A users/{uid}/fcmTokens/{token} reference."""

    def __init__(self, store: dict[str, dict[str, Any]], uid: str, doc_id: str) -> None:
        self._store, self._uid, self.id = store, uid, doc_id
        self.parent = _Parent(uid)

    def delete(self) -> None:
        self._store[self._uid].pop(self.id, None)

    def set(self, data: dict[str, Any]) -> None:
        self._store.setdefault(self._uid, {})[self.id] = data


class _TokenDoc:
    def __init__(self, store: dict[str, dict[str, Any]], uid: str, doc_id: str) -> None:
        self.id = doc_id
        self.reference = _Ref(store, uid, doc_id)


class _FakeDb:
    def __init__(self) -> None:
        self.store: dict[str, dict[str, Any]] = {}

    def collection_group(self, name: str) -> Any:
        assert name == "fcmTokens"
        db = self

        class _Q:
            def select(self, _fields: list[str]) -> _Q:
                return self

            def stream(self) -> list[_TokenDoc]:
                return [
                    _TokenDoc(db.store, uid, t)
                    for uid, toks in db.store.items()
                    for t in list(toks)
                ]

        return _Q()

    def collection(self, _users: str) -> Any:
        db = self

        class _Users:
            def document(self, uid: str) -> Any:
                class _User:
                    def collection(self, _t: str) -> Any:
                        class _Tokens:
                            def document(self, token: str) -> _Ref:
                                return _Ref(db.store, uid, token)

                            def stream(self) -> list[_TokenDoc]:
                                return [_TokenDoc(db.store, uid, t) for t in db.store.get(uid, {})]

                        return _Tokens()

                return _User()

        return _Users()


def test_d128_firestore_add_removes_the_token_from_other_users() -> None:
    db = _FakeDb()
    db.store = {"u-patient": {"shared": {}, "own": {}}, "u-doctor": {"doc-phone": {}}}
    repo = FirestoreTokenRepository(db)

    repo.add("u-family", "shared", "android")

    assert repo.tokens("u-family") == ["shared"]
    assert repo.tokens("u-patient") == ["own"]
    assert repo.tokens("u-doctor") == ["doc-phone"]


def test_d128_firestore_re_register_keeps_own_token() -> None:
    db = _FakeDb()
    db.store = {"u-family": {"shared": {}}}
    repo = FirestoreTokenRepository(db)

    repo.add("u-family", "shared", "android")

    assert repo.tokens("u-family") == ["shared"]

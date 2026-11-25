"""D-131: check an email + password with Firebase Authentication (Identity Toolkit REST).

Used by POST /auth/resolve-sign-in before it tells the app which login an IC, passport or
contact email belongs to, so that answer is only given to someone who knows the password.
Locally it talks to the Auth emulator (FIREBASE_AUTH_EMULATOR_HOST).
"""

from __future__ import annotations

import logging
import os
from typing import Protocol

import httpx

from app.core.config import get_settings

log = logging.getLogger("careflow.password_check")
PATH = "identitytoolkit.googleapis.com/v1/accounts:signInWithPassword"


class PasswordVerifier(Protocol):
    def check(self, email: str, password: str) -> bool:
        """True if this email + password signs in (the account is enabled)."""
        ...


class FirebasePasswordVerifier:
    def __init__(self, api_key: str, emulator_host: str | None) -> None:
        self._key = api_key
        self._emulator = emulator_host

    def check(self, email: str, password: str) -> bool:
        if self._emulator:
            url = f"http://{self._emulator}/{PATH}?key={self._key or 'emulator'}"
        elif self._key:
            url = f"https://{PATH}?key={self._key}"
        else:
            log.warning("FIREBASE_WEB_API_KEY is not set; sign-in by IC/contact email is off")
            return False
        try:
            res = httpx.post(
                url,
                json={"email": email, "password": password, "returnSecureToken": False},
                timeout=10,
            )
        except httpx.HTTPError:
            log.warning("Password check could not reach Firebase Auth")
            return False
        return res.status_code == 200


def get_password_verifier() -> PasswordVerifier:
    return FirebasePasswordVerifier(
        get_settings().firebase_web_api_key, os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")
    )

"""Password reset by email OTP (D-80; UC1.2 forgot password).

POST /auth/password-otp/request  {email}                       -> 202, always the same answer
POST /auth/password-otp/verify   {email, code, newPassword}     -> 200 or 400

A 6-digit code is emailed (Brevo adapter, D-65). It is valid for 10 minutes and allows
5 wrong tries; at most 3 codes are sent per email in 15 minutes. Only a salted hash of
the code is stored, in `password_otps` (server-only), keyed by a hash of the email so the
collection holds no addresses. The answer never says whether the account exists.
"""

from __future__ import annotations

import hashlib
import hmac
import html
import logging
import secrets
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from typing import Any, Protocol

from fastapi import APIRouter, Depends, Request, status
from pydantic import BaseModel, ConfigDict, Field

from app.core.audit import AuditLogger, get_audit_logger
from app.core.enums import Collection
from app.core.errors import ApiError
from app.core.firebase import get_firestore
from app.core.rate_limit import RateLimiter
from app.integrations.email import EmailClient, EmailMessage, get_email_client
from app.services.identity import IdentityProvider, get_identity_provider
from app.services.login_alias import is_alias
from app.services.users import UserRepository, get_user_repository

log = logging.getLogger("careflow.password_otp")
router = APIRouter(prefix="/auth/password-otp", tags=["auth"])

CODE_TTL = timedelta(minutes=10)
SETUP_CODE_TTL = timedelta(days=7)  # D-129: counter code for a patient without an email
MAX_TRIES = 5
SEND_WINDOW = timedelta(minutes=15)
MAX_SENDS = 3
ANONYMOUS_USER = "anonymous"


class PasswordOtpRepository(Protocol):
    def get(self, key: str) -> dict[str, Any] | None: ...

    def put(self, key: str, data: dict[str, Any]) -> None: ...

    def delete(self, key: str) -> None: ...


class FirestorePasswordOtpRepository:
    def __init__(self, db: Any) -> None:
        self._col = db.collection(Collection.PASSWORD_OTPS.value)

    def get(self, key: str) -> dict[str, Any] | None:
        snap = self._col.document(key).get()
        return dict(snap.to_dict()) if snap.exists else None

    def put(self, key: str, data: dict[str, Any]) -> None:
        self._col.document(key).set(data)

    def delete(self, key: str) -> None:
        self._col.document(key).delete()


def get_password_otp_repository() -> PasswordOtpRepository:
    return FirestorePasswordOtpRepository(get_firestore())


@lru_cache
def _ip_limiter() -> RateLimiter:
    # Per IP, across emails: stops one caller spraying codes at many addresses.
    return RateLimiter(10, window_seconds=15 * 60)


def get_otp_ip_limiter() -> RateLimiter:
    return _ip_limiter()


def email_key(email: str) -> str:
    return hashlib.sha256(email.encode()).hexdigest()


def code_hash(code: str, salt: str) -> str:
    return hashlib.sha256(f"{salt}:{code}".encode()).hexdigest()


def new_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def issue_setup_code(repo: PasswordOtpRepository, login_email: str, uid: str) -> str:
    """D-129: a 6-digit code the counter hands to a patient without an email. It is
    verified by POST /verify like an emailed code (login email = the MyKad/passport alias),
    lasts 7 days, allows 5 wrong tries and replaces any earlier code."""
    code = new_code()
    salt = secrets.token_hex(8)
    now = _now()
    repo.put(
        email_key(login_email.lower()),
        {
            "uid": uid,
            "salt": salt,
            "codeHash": code_hash(code, salt),
            "expiresAt": now + SETUP_CODE_TTL,
            "attempts": 0,
            "sentAt": [],
            "createdAt": now,
            "kind": "counter",
        },
    )
    return code


def otp_email(name: str, email: str, code: str) -> EmailMessage:
    greeting = f"Hello {name}," if name else "Hello,"
    text = (
        f"{greeting}\n\nYour Harvey password reset code is: {code}\n\n"
        "Enter it in the app within 10 minutes to choose a new password.\n"
        "If you did not ask for this, ignore this email; your password stays the same.\n"
        "Harvey staff will never ask you for this code.\n"
    )
    body = (
        f"<p>{html.escape(greeting)}</p>"
        "<p>Your <b>Harvey</b> password reset code is:</p>"
        f'<p style="font-size:28px;font-weight:bold;letter-spacing:6px">{code}</p>'
        "<p>Enter it in the app within 10 minutes to choose a new password.</p>"
        "<p>If you did not ask for this, ignore this email; your password stays the same. "
        "Harvey staff will never ask you for this code.</p>"
    )
    return EmailMessage(
        to_email=email,
        to_name=name or email,
        subject=f"Your Harvey reset code: {code}",
        text=text,
        html=body,
    )


class OtpRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    email: str = Field(min_length=3, max_length=254, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class OtpVerify(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True, populate_by_name=True)
    email: str = Field(min_length=3, max_length=254)
    code: str = Field(pattern=r"^\d{6}$")
    new_password: str = Field(alias="newPassword", min_length=8, max_length=128)


def _client_ip(request: Request) -> str:
    forwarded = request.headers.get("x-forwarded-for", "")
    return forwarded.split(",")[0].strip() or (request.client.host if request.client else "-")


def _strong(password: str) -> bool:
    # Same rule as registration: at least 8 characters with a letter and a number.
    return any(c.isalpha() for c in password) and any(c.isdigit() for c in password)


def _now() -> datetime:
    return datetime.now(UTC)


def _as_dt(v: Any) -> datetime | None:
    if isinstance(v, datetime):
        return v if v.tzinfo else v.replace(tzinfo=UTC)
    return None


@router.post("/request", status_code=status.HTTP_202_ACCEPTED)
def request_code(
    body: OtpRequest,
    request: Request,
    repo: PasswordOtpRepository = Depends(get_password_otp_repository),
    identity: IdentityProvider = Depends(get_identity_provider),
    email_client: EmailClient = Depends(get_email_client),
    ip_limiter: RateLimiter = Depends(get_otp_ip_limiter),
    audit: AuditLogger = Depends(get_audit_logger),
    users: UserRepository = Depends(get_user_repository),
) -> dict[str, str]:
    if not ip_limiter.allow(_client_ip(request)):
        raise ApiError(
            "RATE_LIMITED", "Too many attempts. Try again later.", status.HTTP_429_TOO_MANY_REQUESTS
        )
    email = body.email.lower()
    if is_alias(email):
        # D-129: no mailbox behind a MyKad/passport login; keep any counter code intact.
        return {"status": "sent_if_exists"}
    key = email_key(email)
    now = _now()
    existing = repo.get(key) or {}
    sends = [
        t for t in (_as_dt(x) for x in existing.get("sentAt", [])) if t and now - t < SEND_WINDOW
    ]
    if len(sends) >= MAX_SENDS:
        raise ApiError(
            "RATE_LIMITED",
            "Too many codes requested. Wait 15 minutes and try again.",
            status.HTTP_429_TOO_MANY_REQUESTS,
        )
    found = identity.find_by_email(email)
    if found is None:
        # D-130: a MyKad/passport patient's verified contact email also gets reset codes.
        owner = users.contact_email_owner(email)
        if owner is not None:
            found = (owner, str((users.get_user(owner) or {}).get("name") or ""))
    if found is None:
        # Same answer and no stored code: an unknown email can't be probed.
        return {"status": "sent_if_exists"}
    uid, name = found
    code = new_code()
    salt = secrets.token_hex(8)
    repo.put(
        key,
        {
            "uid": uid,
            "salt": salt,
            "codeHash": code_hash(code, salt),
            "expiresAt": now + CODE_TTL,
            "attempts": 0,
            "sentAt": [*sends, now],
            "createdAt": now,
        },
    )
    try:
        email_client.send(otp_email(name, email, code))
    except Exception:  # never reveal provider problems to an anonymous caller
        log.exception("Password OTP email failed")
    audit.log(
        user_id=uid,
        action="PASSWORD_OTP_SENT",
        details=f"Reset code emailed; emailDomain={email.rsplit('@', 1)[-1]}.",
    )
    return {"status": "sent_if_exists"}


def _bad_code() -> ApiError:
    return ApiError(
        "INVALID_CODE",
        "That code is wrong or has expired. Check the email or request a new code.",
        status.HTTP_400_BAD_REQUEST,
    )


@router.post("/verify")
def verify_code(
    body: OtpVerify,
    repo: PasswordOtpRepository = Depends(get_password_otp_repository),
    identity: IdentityProvider = Depends(get_identity_provider),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, str]:
    if not _strong(body.new_password):
        raise ApiError(
            "WEAK_PASSWORD",
            "Password must have at least 8 characters, a letter and a number.",
            status.HTTP_400_BAD_REQUEST,
        )
    key = email_key(body.email.lower())
    entry = repo.get(key)
    if not entry or not entry.get("codeHash"):
        raise _bad_code()
    expires = _as_dt(entry.get("expiresAt"))
    attempts = int(entry.get("attempts") or 0)
    if expires is None or _now() >= expires or attempts >= MAX_TRIES:
        repo.put(key, {**entry, "codeHash": None})  # used up; keep the send history
        raise _bad_code()
    if not hmac.compare_digest(code_hash(body.code, str(entry.get("salt"))), entry["codeHash"]):
        attempts += 1
        repo.put(key, {**entry, "attempts": attempts})
        left = MAX_TRIES - attempts
        if left <= 0:
            repo.put(key, {**entry, "attempts": attempts, "codeHash": None})
            raise ApiError(
                "TOO_MANY_TRIES",
                "Too many wrong codes. Request a new code.",
                status.HTTP_400_BAD_REQUEST,
            )
        raise ApiError(
            "INVALID_CODE",
            f"That code is wrong. {left} tr{'y' if left == 1 else 'ies'} left.",
            status.HTTP_400_BAD_REQUEST,
        )
    uid = str(entry["uid"])
    identity.set_password(uid, body.new_password)
    identity.revoke_sessions(uid)  # other devices must sign in with the new password
    repo.put(key, {**entry, "codeHash": None, "usedAt": _now()})
    audit.log(
        user_id=uid, action="PASSWORD_RESET_BY_OTP", details="Password changed with an email code."
    )
    return {"status": "password_changed"}

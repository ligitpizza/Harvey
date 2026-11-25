"""D-130: a contact email for a patient who signs in with MyKad/passport (D-129).

Their Firebase login is an ID alias, so they have no email. They (or the counter, with the
patient present) can add one later; it is used for appointment-reminder emails and for
"Forgot password" codes. Sign-in stays MyKad/passport + password.

POST   /settings/contact-email/request          patient: email a 6-digit code to the address
POST   /settings/contact-email/verify           patient: the code -> users.contactEmail
DELETE /settings/contact-email                  patient: remove it
POST   /walk-in/patients/{uid}/contact-email/request   pharmacist / admin, same
POST   /walk-in/patients/{uid}/contact-email/verify    pharmacist / admin, same

The code proves the address belongs to the patient. It is stored hashed in
`password_otps` (key = hash of "contact:<uid>"), lasts 10 minutes, allows 5 wrong tries,
and at most 3 codes are sent per 15 minutes. An address that is already someone's login
or contact email is refused.
"""

from __future__ import annotations

import hashlib
import hmac
import html
import logging
import secrets
from datetime import UTC, datetime
from typing import Any

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.core.audit import AuditLogger, get_audit_logger
from app.core.auth import CurrentUser, require_roles
from app.core.enums import Collection, UserRole
from app.core.errors import ApiError
from app.integrations.email import EmailClient, EmailMessage, get_email_client
from app.routers.password_otp import (
    CODE_TTL,
    MAX_SENDS,
    MAX_TRIES,
    SEND_WINDOW,
    PasswordOtpRepository,
    code_hash,
    get_password_otp_repository,
    new_code,
)
from app.schemas.auth import _check_email
from app.services.identity import IdentityProvider, get_identity_provider
from app.services.users import UserRepository, get_user_repository

log = logging.getLogger("careflow.contact_email")
router = APIRouter(prefix="/settings/contact-email", tags=["settings"])
counter_router = APIRouter(prefix="/walk-in/patients", tags=["walk-in"])
patient_only = require_roles(UserRole.PATIENT)
counter = require_roles(UserRole.PHARMACIST, UserRole.ADMIN)


class ContactEmailRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    email: str = Field(max_length=254)

    _email = field_validator("email")(_check_email)


class ContactEmailVerify(ContactEmailRequest):
    code: str = Field(pattern=r"^\d{6}$")


def _key(uid: str) -> str:
    return hashlib.sha256(f"contact:{uid}".encode()).hexdigest()


def _as_dt(v: Any) -> datetime | None:
    if isinstance(v, datetime):
        return v if v.tzinfo else v.replace(tzinfo=UTC)
    return None


def _now() -> datetime:
    return datetime.now(UTC)


def _id_patient(users: UserRepository, uid: str) -> dict[str, Any]:
    u = users.get_user(uid)
    if not u or u.get("role") != UserRole.PATIENT.value:
        raise ApiError("NOT_FOUND", "Patient not found.", status.HTTP_404_NOT_FOUND)
    if u.get("email"):
        raise ApiError(
            "HAS_EMAIL",
            "This account already signs in with an email.",
            status.HTTP_409_CONFLICT,
        )
    return u


def _check_free(email: str, uid: str, users: UserRepository, identity: IdentityProvider) -> None:
    owner = users.contact_email_owner(email)
    if identity.find_by_email(email) is not None or (owner is not None and owner != uid):
        raise ApiError(
            "EMAIL_IN_USE",
            "This email is already used by another Harvey account. Use a different email.",
            status.HTTP_409_CONFLICT,
        )


def _code_email(name: str, email: str, code: str) -> EmailMessage:
    greeting = f"Hello {name}," if name else "Hello,"
    text = (
        f"{greeting}\n\nYour Harvey email check code is: {code}\n\n"
        "Enter it in Harvey within 10 minutes to add this email to your account. Harvey will "
        "use it for appointment reminders and password reset codes.\n"
        "If you did not ask for this, ignore this email.\n"
    )
    body = (
        f"<p>{html.escape(greeting)}</p>"
        "<p>Your <b>Harvey</b> email check code is:</p>"
        f'<p style="font-size:28px;font-weight:bold;letter-spacing:6px">{code}</p>'
        "<p>Enter it in Harvey within 10 minutes to add this email to your account. Harvey "
        "will use it for appointment reminders and password reset codes.</p>"
        "<p>If you did not ask for this, ignore this email.</p>"
    )
    return EmailMessage(
        to_email=email,
        to_name=name or email,
        subject=f"Your Harvey email check code: {code}",
        text=text,
        html=body,
    )


def _request(
    uid: str,
    email: str,
    actor: str,
    users: UserRepository,
    identity: IdentityProvider,
    codes: PasswordOtpRepository,
    email_client: EmailClient,
    audit: AuditLogger,
) -> dict[str, str]:
    u = _id_patient(users, uid)
    _check_free(email, uid, users, identity)
    now = _now()
    existing = codes.get(_key(uid)) or {}
    sends = [
        t for t in (_as_dt(x) for x in existing.get("sentAt", [])) if t and now - t < SEND_WINDOW
    ]
    if len(sends) >= MAX_SENDS:
        raise ApiError(
            "RATE_LIMITED",
            "Too many codes requested. Wait 15 minutes and try again.",
            status.HTTP_429_TOO_MANY_REQUESTS,
        )
    code = new_code()
    salt = secrets.token_hex(8)
    codes.put(
        _key(uid),
        {
            "uid": uid,
            "email": email,
            "salt": salt,
            "codeHash": code_hash(code, salt),
            "expiresAt": now + CODE_TTL,
            "attempts": 0,
            "sentAt": [*sends, now],
            "createdAt": now,
            "kind": "contact_email",
        },
    )
    try:
        email_client.send(_code_email(str(u.get("name") or ""), email, code))
    except Exception as exc:
        log.exception("Contact email code failed for uid=%s", uid)
        raise ApiError(
            "EMAIL_NOT_SENT",
            "The code could not be emailed. Check the address and try again.",
            status.HTTP_502_BAD_GATEWAY,
        ) from exc
    audit.log(
        user_id=actor,
        action="CONTACT_EMAIL_CODE_SENT",
        details=f"Contact email check code sent; emailDomain={email.rsplit('@', 1)[-1]}.",
        target_type=Collection.USERS.value,
        target_id=uid,
    )
    return {"status": "sent"}


def _bad_code(left: int | None = None) -> ApiError:
    if left is not None and left <= 0:
        return ApiError(
            "TOO_MANY_TRIES",
            "Too many wrong codes. Request a new code.",
            status.HTTP_400_BAD_REQUEST,
        )
    more = "" if left is None else f" {left} tr{'y' if left == 1 else 'ies'} left."
    return ApiError(
        "INVALID_CODE", f"That code is wrong or has expired.{more}", status.HTTP_400_BAD_REQUEST
    )


def _verify(
    uid: str,
    body: ContactEmailVerify,
    actor: str,
    users: UserRepository,
    identity: IdentityProvider,
    codes: PasswordOtpRepository,
    audit: AuditLogger,
) -> dict[str, str]:
    _id_patient(users, uid)
    entry = codes.get(_key(uid))
    if not entry or not entry.get("codeHash") or entry.get("email") != body.email:
        raise _bad_code()
    expires = _as_dt(entry.get("expiresAt"))
    attempts = int(entry.get("attempts") or 0)
    if expires is None or _now() >= expires or attempts >= MAX_TRIES:
        codes.put(_key(uid), {**entry, "codeHash": None})
        raise _bad_code()
    if not hmac.compare_digest(code_hash(body.code, str(entry.get("salt"))), entry["codeHash"]):
        attempts += 1
        left = MAX_TRIES - attempts
        codes.put(
            _key(uid), {**entry, "attempts": attempts, **({"codeHash": None} if left <= 0 else {})}
        )
        raise _bad_code(left)
    _check_free(body.email, uid, users, identity)  # taken meanwhile?
    users.update_user(uid, {"contactEmail": body.email})
    codes.put(_key(uid), {**entry, "codeHash": None, "usedAt": _now()})
    audit.log(
        user_id=actor,
        action="CONTACT_EMAIL_ADDED",
        details="Contact email verified and saved (used for reminders and password reset).",
        target_type=Collection.USERS.value,
        target_id=uid,
    )
    return {"status": "saved", "contactEmail": body.email}


@router.post("/request")
def request_code(
    body: ContactEmailRequest,
    user: CurrentUser = Depends(patient_only),
    users: UserRepository = Depends(get_user_repository),
    identity: IdentityProvider = Depends(get_identity_provider),
    codes: PasswordOtpRepository = Depends(get_password_otp_repository),
    email_client: EmailClient = Depends(get_email_client),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, str]:
    return _request(user.uid, body.email, user.uid, users, identity, codes, email_client, audit)


@router.post("/verify")
def verify_code(
    body: ContactEmailVerify,
    user: CurrentUser = Depends(patient_only),
    users: UserRepository = Depends(get_user_repository),
    identity: IdentityProvider = Depends(get_identity_provider),
    codes: PasswordOtpRepository = Depends(get_password_otp_repository),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, str]:
    return _verify(user.uid, body, user.uid, users, identity, codes, audit)


@router.delete("", status_code=status.HTTP_204_NO_CONTENT)
def remove(
    user: CurrentUser = Depends(patient_only),
    users: UserRepository = Depends(get_user_repository),
    audit: AuditLogger = Depends(get_audit_logger),
) -> None:
    _id_patient(users, user.uid)
    users.update_user(user.uid, {"contactEmail": None})
    audit.log(
        user_id=user.uid,
        action="CONTACT_EMAIL_REMOVED",
        details="Contact email removed.",
        target_type=Collection.USERS.value,
        target_id=user.uid,
    )


@counter_router.post("/{uid}/contact-email/request")
def counter_request_code(
    uid: str,
    body: ContactEmailRequest,
    user: CurrentUser = Depends(counter),
    users: UserRepository = Depends(get_user_repository),
    identity: IdentityProvider = Depends(get_identity_provider),
    codes: PasswordOtpRepository = Depends(get_password_otp_repository),
    email_client: EmailClient = Depends(get_email_client),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, str]:
    """The patient is at the counter; the code goes to their email and they read it out."""
    return _request(uid, body.email, user.uid, users, identity, codes, email_client, audit)


@counter_router.post("/{uid}/contact-email/verify")
def counter_verify_code(
    uid: str,
    body: ContactEmailVerify,
    user: CurrentUser = Depends(counter),
    users: UserRepository = Depends(get_user_repository),
    identity: IdentityProvider = Depends(get_identity_provider),
    codes: PasswordOtpRepository = Depends(get_password_otp_repository),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, str]:
    return _verify(uid, body, user.uid, users, identity, codes, audit)

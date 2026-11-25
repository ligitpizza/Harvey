"""Request/response models for Module 1 (FR-1.1 to FR-1.6).

Onboarding payload shape is decision D-25: three JSON objects stored in the
`health_profiles` String fields, plus dateOfBirth/gender stored on `users`.
"""

import re
import unicodedata
from datetime import date
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.core.enums import (
    AlcoholUse,
    ClientApp,
    FamilyHistoryCondition,
    Gender,
    LoginFailureReason,
    MedicalCondition,
    SaltIntake,
    SessionEvent,
    SmokingStatus,
    UserRole,
)

# D-82: Malaysian mobile numbers only: 01X followed by 7 or 8 digits (011 takes 8), typed
# with or without +60 / 60, spaces or dashes; saved as +60XXXXXXXXX.
_MY_MOBILE_RE = re.compile(r"^1(1\d{8}|[02-9]\d{7})$")
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
MAX_AGE_YEARS = 120
MIN_AGE_YEARS = 13  # D-28


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


def _check_email(value: str) -> str:
    value = value.strip().lower()
    if not _EMAIL_RE.match(value):
        raise ValueError("Enter a valid email address.")
    return value


def check_dob(v: date) -> date:
    """A plausible adult date of birth (UC1.4, UC12.1)."""
    today = date.today()
    if v >= today:
        raise ValueError("Date of birth must be in the past.")
    age = today.year - v.year - ((today.month, today.day) < (v.month, v.day))
    if age > MAX_AGE_YEARS:
        raise ValueError("Enter a valid date of birth.")
    if age < MIN_AGE_YEARS:
        raise ValueError(f"You must be at least {MIN_AGE_YEARS} years old to use Harvey.")
    return v


NAME_PUNCTUATION = set(" .'@/-")


def _check_name(value: str) -> str:
    """D-124: a person's name: letters (any language), spaces and . ' - @ /, at least two
    letters (same rule as the app's Validators.name)."""
    v = value.strip()
    ok = all(
        ch.isalpha() or ch in NAME_PUNCTUATION or unicodedata.category(ch).startswith("M")
        for ch in v
    )
    if not ok or sum(ch.isalpha() for ch in v) < 2:
        raise ValueError("Use letters only (spaces and . ' - @ / are fine).")
    return v


def _check_phone(value: str) -> str:
    """D-82: a Malaysian mobile number, normalised to +60XXXXXXXXX."""
    digits = re.sub(r"[\s-]", "", value or "")
    if digits.startswith("+60"):
        digits = digits[3:]
    elif digits.startswith("60"):
        digits = digits[2:]
    elif digits.startswith("0"):
        digits = digits[1:]
    else:
        raise ValueError("Enter a Malaysian mobile number, e.g. 012-345 6789.")
    if not digits.isdigit() or not _MY_MOBILE_RE.match(digits):
        raise ValueError("Enter a Malaysian mobile number, e.g. 012-345 6789.")
    return f"+60{digits}"


# ---------- registration (UC1.1) ----------


class RegisterProfileRequest(_Strict):
    name: str = Field(min_length=2, max_length=100)
    role: Literal[UserRole.PATIENT, UserRole.FAMILY_MEMBER]
    # D-51/D-103: MyKad or passport, required for patients (checked in the router).
    icNumber: str | None = Field(default=None, max_length=20)
    nationality: str | None = Field(default=None, max_length=60)  # D-103: passports

    _name = field_validator("name")(_check_name)


class RegisterProfileResponse(BaseModel):
    uid: str
    role: UserRole
    onboardingComplete: bool | None = None


# ---------- onboarding (UC1.4, D-25) ----------


class EmergencyContact(_Strict):
    name: str = Field(min_length=2, max_length=100)
    phone: str
    relationship: str = Field(min_length=2, max_length=50)

    _phone = field_validator("phone")(_check_phone)


class PersonalInfo(_Strict):
    heightCm: float = Field(ge=100, le=250)
    weightKg: float = Field(ge=25, le=300)
    phone: str
    emergencyContact: EmergencyContact | None = None
    # D-82: home address typed at sign-up; also saved as users.address (delivery starts
    # pre-filled). Optional here so older app versions can still finish onboarding.
    homeAddress: str | None = Field(default=None, min_length=10, max_length=300)

    _phone = field_validator("phone")(_check_phone)


class MedicalHistory(_Strict):
    hypertensionDiagnosedYear: int | None = Field(default=None, ge=1900)
    conditions: list[MedicalCondition]
    familyHistory: list[FamilyHistoryCondition]
    allergies: str = Field(default="", max_length=500)
    notes: str = Field(default="", max_length=1000)

    @field_validator("hypertensionDiagnosedYear")
    @classmethod
    def _not_future(cls, v: int | None) -> int | None:
        if v is not None and v > date.today().year:
            raise ValueError("Year cannot be in the future.")
        return v

    @field_validator("conditions", "familyHistory")
    @classmethod
    def _unique(cls, v: list[str]) -> list[str]:
        return list(dict.fromkeys(v))


class LifestyleFactors(_Strict):
    smokingStatus: SmokingStatus
    alcohol: AlcoholUse
    exerciseDaysPerWeek: int = Field(ge=0, le=7)
    saltIntake: SaltIntake


class OnboardingRequest(_Strict):
    dateOfBirth: date
    gender: Gender
    personalInfo: PersonalInfo
    medicalHistory: MedicalHistory
    lifestyleFactors: LifestyleFactors

    _dob = field_validator("dateOfBirth")(check_dob)


# ---------- sessions & failed logins (FR-1.5, D-27) ----------


class SessionEventRequest(_Strict):
    event: SessionEvent
    app: ClientApp


class LoginFailedRequest(_Strict):
    email: str = Field(max_length=254)
    reason: LoginFailureReason
    app: ClientApp

    def email_domain(self) -> str:
        """Only the domain is ever stored (D-27)."""
        _, _, domain = self.email.rpartition("@")
        domain = domain.strip().lower()
        return domain if re.fullmatch(r"[a-z0-9.-]{1,253}", domain) else "invalid"


# ---------- staff provisioning (UC1.5, FR-1.6) ----------


class CreateStaffRequest(_Strict):
    name: str = Field(min_length=2, max_length=100)
    email: str = Field(max_length=254)
    role: Literal[UserRole.DOCTOR, UserRole.PHARMACIST, UserRole.ADMIN]
    specialty: str | None = Field(default=None, max_length=100)

    _email = field_validator("email")(_check_email)

    @field_validator("specialty")
    @classmethod
    def _blank_to_none(cls, v: str | None) -> str | None:
        return v or None


class CreateStaffResponse(BaseModel):
    uid: str
    role: UserRole
    emailSent: bool
    # Returned only when the email could not be sent, so the admin can pass it on.
    setupLink: str | None = None


class UpdateUserRequest(_Strict):
    """UC11.1 / D-59: what the admin may change. Roles are never changed here."""

    name: str | None = Field(default=None, min_length=2, max_length=100)
    specialty: str | None = Field(default=None, max_length=100)
    maxPatients: int | None = Field(default=None, ge=1, le=500)
    isActive: bool | None = None
    reason: str | None = Field(default=None, max_length=300)


class CreatePatientRequest(_Strict):
    """D-60: the admin opens a patient account; the patient finishes onboarding later."""

    name: str = Field(min_length=2, max_length=100)
    email: str = Field(max_length=254)
    icNumber: str = Field(min_length=5, max_length=20)  # D-103: MyKad or passport
    nationality: str | None = Field(default=None, max_length=60)

    _email = field_validator("email")(_check_email)


class WalkInPatientRequest(_Strict):
    """D-129: a walk-in patient. Name and MyKad/passport are required; email and phone are
    optional (no email -> the patient signs in with MyKad/passport and a counter code)."""

    name: str = Field(min_length=2, max_length=100)
    email: str | None = Field(default=None, max_length=254)
    phone: str | None = Field(default=None, max_length=20)
    icNumber: str = Field(min_length=5, max_length=20)  # D-103: MyKad or passport
    nationality: str | None = Field(default=None, max_length=60)

    @field_validator("email")
    @classmethod
    def _opt_email(cls, v: str | None) -> str | None:
        return _check_email(v) if v and v.strip() else None

    @field_validator("phone")
    @classmethod
    def _opt_phone(cls, v: str | None) -> str | None:
        return _check_phone(v) if v and v.strip() else None


class PasswordResetRequest(_Strict):
    """D-65: forgot password."""

    email: str = Field(max_length=254)

    _email = field_validator("email")(_check_email)

"""D-80 request bodies: staff leave and walk-in bookings (camelCase like docs/04)."""

from __future__ import annotations

from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.core.enums import AppointmentType

MAX_LEAVE_DAYS = 30


class NewLeave(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    startDate: date
    endDate: date
    reason: str = Field(min_length=3, max_length=500)

    @model_validator(mode="after")
    def _range(self) -> NewLeave:
        if self.endDate < self.startDate:
            raise ValueError("The end date must be on or after the start date.")
        if (self.endDate - self.startDate).days + 1 > MAX_LEAVE_DAYS:
            raise ValueError(f"Apply for at most {MAX_LEAVE_DAYS} days at a time.")
        return self


class Decision(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    decision: Literal["approve", "reject"]
    note: str | None = Field(default=None, max_length=500)


class WalkInBooking(BaseModel):
    model_config = ConfigDict(extra="forbid")
    patientId: str = Field(min_length=1, max_length=128)
    doctorId: str = Field(min_length=1, max_length=128)
    dateTime: datetime
    type: AppointmentType = AppointmentType.CHECKUP

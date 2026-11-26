"""Saving the D-25 health profile from the patient's Settings (UC12.2) or, D-133, from the
assigned doctor's patient page.

`health_profiles.doctorEdits` maps a field key to who changed it last when that was the
doctor: {"smokingStatus": {"by": uid, "byName": "Dr Tan", "at": datetime}}. A doctor's save
tags every field it changes; the patient's save removes the tag of every field they change.
"""

import json
import logging
from datetime import datetime
from typing import Any

from app.ml.risk_model import RiskModel
from app.schemas.settings import HealthProfileUpdate
from app.services.risk import NotEnoughReadingsError, RiskDataRepository, generate_risk_score
from app.services.settings import parse_profile_field

log = logging.getLogger("careflow.health_profile")

# The editable answers (the onboarding health step without contact details).
FIELD_LABELS: dict[str, str] = {
    "heightCm": "Height",
    "weightKg": "Weight",
    "hypertensionDiagnosedYear": "Year diagnosed",
    "conditions": "Conditions",
    "familyHistory": "Family history",
    "allergies": "Allergies",
    "notes": "Notes",
    "smokingStatus": "Smoking",
    "alcohol": "Alcohol",
    "exerciseDaysPerWeek": "Exercise",
    "saltIntake": "Salt",
}
# The values the risk model reads (D-31).
RISK_FIELDS = (
    "heightCm",
    "weightKg",
    "conditions",
    "familyHistory",
    "hypertensionDiagnosedYear",
    "smokingStatus",
)
_PERSONAL = ("heightCm", "weightKg")
_LIFESTYLE = ("smokingStatus", "alcohol", "exerciseDaysPerWeek", "saltIntake")


def _flat(
    personal: dict[str, Any], history: dict[str, Any], life: dict[str, Any]
) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key in FIELD_LABELS:
        src = personal if key in _PERSONAL else life if key in _LIFESTYLE else history
        v = src.get(key)
        if key in ("conditions", "familyHistory"):
            v = sorted(v or [])
        elif key in ("heightCm", "weightKg") and v is not None:
            v = float(v)
        elif key in ("allergies", "notes"):
            v = v or ""
        out[key] = v
    return out


def save_health_profile(
    repo: Any,
    uid: str,
    body: HealthProfileUpdate,
    *,
    editor: dict[str, Any] | None = None,
    now: datetime | None = None,
) -> tuple[list[str], bool]:
    """Writes the new answers. Returns (changed field keys, risk inputs changed).

    `editor` is {"by", "byName"} when the assigned doctor saves (D-133), None for the patient.
    """
    stored = repo.health_profile(uid) or {}
    personal = parse_profile_field(stored.get("personalInfo"))
    before = _flat(
        personal,
        parse_profile_field(stored.get("medicalHistory")),
        parse_profile_field(stored.get("lifestyleFactors")),
    )
    personal.update({"heightCm": body.heightCm, "weightKg": body.weightKg})
    history = body.medicalHistory.model_dump(mode="json")
    life = body.lifestyleFactors.model_dump(mode="json")
    after = _flat(personal, history, life)
    changed = [k for k in FIELD_LABELS if before.get(k) != after.get(k)]

    edits = dict(stored.get("doctorEdits") or {})
    for key in changed:
        if editor is None:
            edits.pop(key, None)
        else:
            edits[key] = {**editor, "at": now}
    repo.update_health_profile(
        uid,
        {
            "personalInfo": json.dumps(personal),
            "medicalHistory": json.dumps(history),
            "lifestyleFactors": json.dumps(life),
            "doctorEdits": edits,
        },
    )
    return changed, any(k in RISK_FIELDS for k in changed)


def rescore(uid: str, risk_repo: RiskDataRepository, model: RiskModel | None) -> bool:
    """UC12.2 step 3: re-run UC9.1 after a relevant change. Never fails the save."""
    if model is None:
        return False
    try:
        generate_risk_score(uid, risk_repo, model)
    except NotEnoughReadingsError:
        return False
    except Exception:
        log.exception("Re-score after profile edit failed for %s", uid)
        return False
    return True

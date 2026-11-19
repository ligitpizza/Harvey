"""POST /triage: symptom checker submission (FR-14.3; UC14.1, UC14.3, UC14.4; D-36).
GET /triage/{id}: reopen a saved result (D-111).

The app sends the selected symptom ids and severity, the heart rate (camera or typed
pulse) and the id of the BP reading the patient just entered in the checker (D-38). The server
gathers the latest vitals and risk, applies the rule table, saves `triage_outcomes`
and notifies the assigned doctor for contact_doctor / seek_emergency_care.
"""

import logging
from datetime import UTC, datetime
from typing import Any

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel, ConfigDict, Field

from app.core.audit import AuditLogger, get_audit_logger
from app.core.auth import CurrentUser, require_roles
from app.core.enums import (
    BpCategory,
    ClinicalAlertType,
    Collection,
    RiskLevel,
    TriageOutcome,
    TriageSeverity,
    UserRole,
)
from app.core.errors import ApiError
from app.integrations.push import PushMessage
from app.schemas.family import Location
from app.services.agent_context import AgentDataRepository, get_agent_data_repository
from app.services.bp import HEART_RATE_MAX, HEART_RATE_MIN
from app.services.bp import classify as classify_bp
from app.services.cover import can_see_patient
from app.services.emergency_record import EmergencyEvent, try_store
from app.services.escalation import (
    AVOID_EXERTION_NOTE,
    CALM_NOTE,
    MILD_DEDUPE_WINDOW,
    DoctorAlert,
    EscalationPlan,
    Escalator,
    get_escalator,
)
from app.services.records import (
    FileStore,
    RecordRepository,
    get_file_store,
    get_record_repository,
)
from app.services.triage import (
    StaleReadingError,
    TriageRepository,
    classify,
    gather_inputs,
    get_triage_repository,
)
from app.services.users import UserRepository, get_user_repository

log = logging.getLogger("careflow.triage")

router = APIRouter(prefix="/triage", tags=["triage"])


class TriageRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    symptoms: list[str] = Field(min_length=1, max_length=14)
    severity: TriageSeverity
    # D-38: both compulsory. Heart rate from the camera or typed from the BP monitor; the
    # reading is the BP entered in the checker and saved just before (POST /vitals).
    heartRate: int = Field(ge=HEART_RATE_MIN, le=HEART_RATE_MAX)  # noqa: N815
    vitalReadingId: str = Field(min_length=1, max_length=128)  # noqa: N815
    # D-62: the phone's GPS position, used only for a family emergency alert.
    location: Location | None = None


_ALERT_SEVERITY = {
    TriageOutcome.CONTACT_DOCTOR: RiskLevel.HIGH,
    TriageOutcome.SEEK_EMERGENCY_CARE: RiskLevel.CRITICAL,
}


@router.post("", status_code=status.HTTP_201_CREATED)
def submit(
    body: TriageRequest,
    user: CurrentUser = Depends(require_roles(UserRole.PATIENT)),
    repo: TriageRepository = Depends(get_triage_repository),
    users: UserRepository = Depends(get_user_repository),
    escalator: Escalator = Depends(get_escalator),
    audit: AuditLogger = Depends(get_audit_logger),
    agent: AgentDataRepository = Depends(get_agent_data_repository),
    records: RecordRepository = Depends(get_record_repository),
    files: FileStore = Depends(get_file_store),
) -> dict[str, Any]:
    ids = list(dict.fromkeys(body.symptoms))
    catalog = repo.symptoms(ids)
    unknown = [i for i in ids if i not in catalog]
    if unknown:
        raise ApiError(
            "UNKNOWN_SYMPTOM",
            f"Unknown symptom: {', '.join(unknown)}.",
            status.HTTP_422_UNPROCESSABLE_CONTENT,
        )
    now = datetime.now(UTC)
    try:
        inputs = gather_inputs(repo, user.uid, body.vitalReadingId, body.heartRate, now)
    except LookupError as exc:
        raise ApiError("READING_NOT_FOUND", str(exc), status.HTTP_404_NOT_FOUND) from exc
    except StaleReadingError as exc:
        raise ApiError("READING_TOO_OLD", str(exc), status.HTTP_409_CONFLICT) from exc

    red_flags = [catalog[i].name for i in ids if catalog[i].is_red_flag]
    decision = classify(
        body.severity,
        red_flags,
        inputs.systolic,
        inputs.diastolic,
        inputs.heart_rate,
        inputs.risk_levels,
    )
    data: dict[str, Any] = {
        "patientId": user.uid,
        "symptoms": ids,  # references to symptom_catalog ids (docs/04 rule 3)
        "severity": body.severity.value,
        "outcome": decision.outcome.value,
        # D-111: kept so the result can be reopened later.
        "reason": decision.reason,
        "heartRate": inputs.heart_rate,
    }
    if inputs.reading_id:
        data["vitalReadingId"] = inputs.reading_id
    outcome_id = repo.save_outcome(data)
    audit.log(
        user_id=user.uid,
        action="TRIAGE",
        details=f"Symptom checker outcome {decision.outcome.value} ({body.severity.value}).",
        target_type=Collection.TRIAGE_OUTCOMES.value,
        target_id=outcome_id,
    )

    profile = users.get_user(user.uid) or {}
    name = str(profile.get("name") or "Patient")
    names = ", ".join(catalog[i].name for i in ids)
    bp = (
        f"BP {inputs.systolic}/{inputs.diastolic} mmHg"
        if inputs.systolic is not None
        else "no recent BP"
    )
    hr = f", HR {inputs.heart_rate} bpm (estimate)" if inputs.heart_rate else ""
    risk = (
        max(inputs.risk_levels, key=list(RiskLevel).index).value if inputs.risk_levels else "none"
    )
    plan = EscalationPlan()
    emergency = decision.outcome is TriageOutcome.SEEK_EMERGENCY_CARE
    # UC14.4: notify the assigned doctor for Moderate (contact) and Emergency outcomes.
    if decision.outcome in _ALERT_SEVERITY:
        label = "URGENT triage: seek emergency care" if emergency else "Triage: contact doctor"
        plan.doctor_alerts.append(
            DoctorAlert(
                ClinicalAlertType.TRIAGE,
                _ALERT_SEVERITY[decision.outcome],
                f"{label}. {name} reported {names} ({body.severity.value}); {bp}{hr}; "
                f"overall risk {risk}.",
            )
        )
        # D-37: family members are told about moderate and emergency symptom reports.
        plan.family_push = PushMessage(
            f"{name}: {'emergency' if emergency else 'symptom'} report",
            f"{name} reported {names} in the symptom checker"
            + (". Please contact them now; call 999 if they are unwell." if emergency else "."),
            {"type": "triage", "outcome": decision.outcome.value},
            urgent=emergency,
        )
        if emergency:
            plan.family_emergency = "triage"
            # D-86: the emergency goes into the patient's Health Records as a PDF summary.
            doctor_id = profile.get("assignedDoctorId")
            doctor = users.get_user(str(doctor_id)) if doctor_id else None
            try_store(
                records,
                files,
                EmergencyEvent(
                    patient_id=user.uid,
                    patient_name=name,
                    trigger="Symptom checker result: seek emergency care",
                    at=now,
                    systolic=inputs.systolic,
                    diastolic=inputs.diastolic,
                    heart_rate=inputs.heart_rate,
                    symptoms=[catalog[i].name for i in ids],
                    severity=body.severity.value,
                    risk_lines=[f"Overall risk: {risk}"],
                    notified=[
                        *(
                            [
                                f"Assigned doctor: {(doctor or {}).get('name') or 'doctor'} "
                                "(urgent triage alert)"
                            ]
                            if doctor_id
                            else []
                        ),
                        "Linked family members: emergency alert with location (if linked)",
                        "The patient: 999 advice in the app",
                    ],
                    actions=["AI Health Agent told the patient to stay calm while help comes"],
                ),
            )
        plan.agent_note = CALM_NOTE if emergency else AVOID_EXERTION_NOTE
    elif inputs.systolic is not None and inputs.diastolic is not None:
        # D-37 Mild band (130-139 / 80-89): doctor gets the daily BP report by email.
        if classify_bp(inputs.systolic, inputs.diastolic) is BpCategory.STAGE1:
            plan.doctor_alerts.append(
                DoctorAlert(
                    ClinicalAlertType.THRESHOLD,
                    RiskLevel.LOW,
                    f"{name} is in the mild (stage 1) range: {bp}{hr}; overall risk {risk}; "
                    f"symptom check: {names} ({body.severity.value}).",
                    dedupe=MILD_DEDUPE_WINDOW,
                    email_report=(
                        f"Symptom checker report for {name} (Harvey).\n\n"
                        f"Symptoms: {names} ({body.severity.value})\n{bp}{hr}\n"
                        f"Overall risk: {risk}\nOutcome: monitor at home (mild range).\n\n"
                        "Open the Harvey staff portal to review the patient's record."
                    ),
                )
            )
    if plan.doctor_alerts or plan.family_push:
        escalator.apply(
            plan,
            user.uid,
            profile.get("assignedDoctorId"),
            now,
            reading_id=inputs.reading_id,
            location=body.location.as_dict() if body.location else None,
        )
    if plan.agent_note:
        try:  # the outcome is saved; a chat note failure must not hide the result
            agent.add_message(user.uid, "agent", plan.agent_note)
        except Exception:
            log.exception("Agent note failed for triage %s", outcome_id)

    return {
        "id": outcome_id,
        "outcome": decision.outcome.value,
        "reason": decision.reason,
        "severity": body.severity.value,
        "symptoms": [
            {"id": i, "name": catalog[i].name, "isRedFlag": catalog[i].is_red_flag} for i in ids
        ],
        "systolic": inputs.systolic,
        "diastolic": inputs.diastolic,
        "heartRate": inputs.heart_rate,
        "missingInputs": inputs.missing,
        "doctorNotified": decision.outcome in _ALERT_SEVERITY,
    }


# D-111: reopen a saved result (from the reading it used, or the checker's history).
_REASON_FALLBACK = {
    TriageOutcome.SEEK_EMERGENCY_CARE.value: "Your symptoms and readings need emergency care.",
    TriageOutcome.CONTACT_DOCTOR.value: "Your symptoms should be checked by your doctor.",
    TriageOutcome.MONITOR_AT_HOME.value: "Your symptoms can be looked after at home for now.",
}


@router.get("/{outcome_id}")
def get_outcome(
    outcome_id: str,
    user: CurrentUser = Depends(require_roles(UserRole.PATIENT, UserRole.DOCTOR)),
    repo: TriageRepository = Depends(get_triage_repository),
    users: UserRepository = Depends(get_user_repository),
) -> dict[str, Any]:
    """The same shape as the submission's result. The patient's own, or their doctor's."""
    o = repo.outcome(outcome_id)
    owner = str((o or {}).get("patientId") or "")
    allowed = o is not None and (
        owner == user.uid
        or (
            user.role is UserRole.DOCTOR
            and can_see_patient(users.get_user(owner), user.uid, datetime.now(UTC))  # D-120
        )
    )
    if o is None or not allowed:
        raise ApiError(
            "TRIAGE_NOT_FOUND", "That symptom check was not found.", status.HTTP_404_NOT_FOUND
        )
    ids = [str(i) for i in o.get("symptoms") or []]
    catalog = repo.symptoms(ids)
    reading = repo.reading(str(o["vitalReadingId"])) if o.get("vitalReadingId") else None
    outcome = str(o.get("outcome"))
    generated = o.get("generatedAt")
    return {
        "id": outcome_id,
        "outcome": outcome,
        "reason": o.get("reason") or _REASON_FALLBACK.get(outcome, ""),
        "severity": o.get("severity"),
        "symptoms": [
            {
                "id": i,
                "name": catalog[i].name if i in catalog else i,
                "isRedFlag": catalog[i].is_red_flag if i in catalog else False,
            }
            for i in ids
        ],
        "systolic": (reading or {}).get("systolic"),
        "diastolic": (reading or {}).get("diastolic"),
        "heartRate": o.get("heartRate") or (reading or {}).get("heartRate"),
        "vitalReadingId": o.get("vitalReadingId"),
        "missingInputs": [],
        "doctorNotified": outcome
        in (TriageOutcome.CONTACT_DOCTOR.value, TriageOutcome.SEEK_EMERGENCY_CARE.value),
        "generatedAt": generated.isoformat() if isinstance(generated, datetime) else None,
    }

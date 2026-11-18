"""AI Health Agent endpoints (FR-14.1; UC2.6, UC2.7; docs/05 POST /agent/chat; D-34).

POST /agent/chat       patient question -> grounded reply (or safe emergency reply)
POST /agent/proactive  status update after the latest reading, with action buttons
POST /agent/weekly-summary  D-76: post this week's summary if none in the last 7 days
POST /agent/weekly-summary/create  D-105: make one now (once a day), saved to Records
POST /agent/messages/{id}/save-pdf  D-100: save an older weekly summary to Records
"""

from datetime import UTC, datetime
from functools import lru_cache
from typing import Any

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel, ConfigDict, Field

from app.core.audit import AuditLogger, get_audit_logger
from app.core.auth import CurrentUser, require_roles
from app.core.config import get_settings
from app.core.enums import Collection, UserRole
from app.core.errors import ApiError
from app.core.rate_limit import RateLimiter
from app.integrations.gemini import LlmClient, get_llm_client
from app.services.agent import HealthAgent, NoReadingError
from app.services.agent_context import AgentDataRepository, get_agent_data_repository
from app.services.escalation import Escalator, get_escalator
from app.services.records import (
    FileStore,
    RecordRepository,
    get_file_store,
    get_record_repository,
    record_view,
)
from app.services.settings import (
    SettingsRepository,
    get_settings_repository,
    parse_profile_field,
)
from app.services.weekly_summary import (
    KIND,
    ensure_summary,
    made_today,
    post_summary,
    save_summary_pdf,
    wants_summary,
)

router = APIRouter(prefix="/agent", tags=["agent"])


class ChatRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    message: str = Field(min_length=1, max_length=1000)


@lru_cache
def _agent_limiter() -> RateLimiter:
    return RateLimiter(get_settings().agent_rate_per_minute)


def get_agent_limiter() -> RateLimiter:
    return _agent_limiter()


def get_health_agent(
    repo: AgentDataRepository = Depends(get_agent_data_repository),
    llm: LlmClient = Depends(get_llm_client),
    escalator: Escalator = Depends(get_escalator),
) -> HealthAgent:
    return HealthAgent(repo, llm, escalator)


def _limit(user: CurrentUser, limiter: RateLimiter) -> None:
    if not limiter.allow(user.uid):
        raise ApiError(
            "TOO_MANY_REQUESTS",
            "You're sending messages quickly. Please wait a moment and try again.",
            status.HTTP_429_TOO_MANY_REQUESTS,
        )


@router.post("/chat")
def chat(
    body: ChatRequest,
    user: CurrentUser = Depends(require_roles(UserRole.PATIENT)),
    agent: HealthAgent = Depends(get_health_agent),
    limiter: RateLimiter = Depends(get_agent_limiter),
    repo: AgentDataRepository = Depends(get_agent_data_repository),
    records: RecordRepository = Depends(get_record_repository),
    files: FileStore = Depends(get_file_store),
) -> dict[str, Any]:
    _limit(user, limiter)
    if wants_summary(body.message):
        # D-105: "make my weekly summary" makes one (saved to Records) instead of a chat
        # reply saying it can't.
        repo.add_message(user.uid, "patient", body.message)
        now = datetime.now(UTC)
        if made_today(repo, user.uid, now):
            reply = "Your summary for today is already above, and saved in your Records."
        else:
            post_summary(repo, user.uid, now, records, files)
            reply = "Here is your weekly health summary. I've also saved it to your Records."
        repo.add_message(user.uid, "agent", reply)
        return {"reply": reply, "emergency": False, "fallback": False, "summary": True}
    result = agent.chat(user.uid, body.message)
    return {"reply": result.reply, "emergency": result.emergency, "fallback": result.fallback}


@router.post("/proactive")
def proactive(
    user: CurrentUser = Depends(require_roles(UserRole.PATIENT)),
    agent: HealthAgent = Depends(get_health_agent),
    limiter: RateLimiter = Depends(get_agent_limiter),
    profiles: SettingsRepository = Depends(get_settings_repository),
) -> dict[str, Any]:
    _limit(user, limiter)
    try:
        result = agent.proactive(user.uid)
    except NoReadingError as exc:
        raise ApiError("NO_READING", str(exc), status.HTTP_409_CONFLICT) from exc
    return {
        "text": result.text,
        "riskLevel": result.risk_level.value if result.risk_level else None,
        "actions": result.actions,
        "fallback": result.fallback,
        # D-72: the Critical "Call emergency contact" button dials this number.
        "emergencyContactPhone": _emergency_phone(profiles, user.uid),
    }


def _emergency_phone(profiles: SettingsRepository, uid: str) -> str | None:
    try:
        personal = parse_profile_field((profiles.health_profile(uid) or {}).get("personalInfo"))
    except Exception:
        return None
    contact = personal.get("emergencyContact")
    phone = contact.get("phone") if isinstance(contact, dict) else None
    return str(phone) if phone else None


@router.post("/weekly-summary")
def weekly_summary(
    user: CurrentUser = Depends(require_roles(UserRole.PATIENT)),
    repo: AgentDataRepository = Depends(get_agent_data_repository),
    records: RecordRepository = Depends(get_record_repository),
    files: FileStore = Depends(get_file_store),
) -> dict[str, Any]:
    """D-76: called when the patient's inbox opens, so the first summary needs no wait."""
    return {"created": ensure_summary(repo, user.uid, datetime.now(UTC), records, files)}


@router.post("/weekly-summary/create", status_code=status.HTTP_201_CREATED)
def create_weekly_summary(
    user: CurrentUser = Depends(require_roles(UserRole.PATIENT)),
    repo: AgentDataRepository = Depends(get_agent_data_repository),
    records: RecordRepository = Depends(get_record_repository),
    files: FileStore = Depends(get_file_store),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, Any]:
    """D-105: 'Create this week's summary': one a day, posted in the chat and kept in
    Records as a PDF."""
    now = datetime.now(UTC)
    if made_today(repo, user.uid, now):
        raise ApiError(
            "SUMMARY_ALREADY_TODAY",
            "You already have today's summary. It's in the chat and in your Records.",
            status.HTTP_409_CONFLICT,
        )
    message_id = post_summary(repo, user.uid, now, records, files)
    audit.log(
        user_id=user.uid,
        action="CREATE_WEEKLY_SUMMARY",
        details="Patient made a weekly summary on request; saved to Records.",
        target_type=Collection.AGENT_MESSAGES.value,
        target_id=message_id,
    )
    return {"messageId": message_id}


@router.post("/messages/{message_id}/save-pdf", status_code=status.HTTP_201_CREATED)
def save_summary_pdf_route(
    message_id: str,
    user: CurrentUser = Depends(require_roles(UserRole.PATIENT)),
    repo: AgentDataRepository = Depends(get_agent_data_repository),
    records: RecordRepository = Depends(get_record_repository),
    files: FileStore = Depends(get_file_store),
    audit: AuditLogger = Depends(get_audit_logger),
) -> dict[str, Any]:
    """D-100: the patient saves a weekly summary to their Records as a PDF. The text comes
    from the stored message (never from the request), with today's numbers attached."""
    m = repo.message(user.uid, message_id)
    if m is None or m.get("kind") != KIND:
        raise ApiError(
            "SUMMARY_NOT_FOUND", "That weekly summary was not found.", status.HTTP_404_NOT_FOUND
        )
    if m.get("savedRecordId") and records.get(str(m["savedRecordId"])) is not None:
        raise ApiError(
            "SUMMARY_ALREADY_SAVED",
            "This summary is already in your Records.",
            status.HTTP_409_CONFLICT,
        )
    now = datetime.now(UTC)
    sent_at = m.get("sentAt")
    sent = sent_at if isinstance(sent_at, datetime) else now
    record_id, record = save_summary_pdf(
        repo, records, files, user.uid, message_id, str(m.get("text") or ""), sent, now
    )
    audit.log(
        user_id=user.uid,
        action="SAVE_WEEKLY_SUMMARY",
        details="Weekly summary saved to Records as a PDF.",
        target_type=Collection.HEALTH_RECORDS.value,
        target_id=record_id,
    )
    return record_view(record_id, record)

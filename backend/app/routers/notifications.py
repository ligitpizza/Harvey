"""The notification bell (D-77), for every role.

GET  /notifications            latest 50 and the unread count
POST /notifications/{id}/read  mark one read
POST /notifications/read-all   mark all read
GET  /notifications/prefs      which categories reach the bell
PUT  /notifications/prefs
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel, ConfigDict, Field

from app.core.auth import CurrentUser, require_roles
from app.core.enums import UserRole
from app.core.errors import ApiError
from app.services.inbox import (
    CATEGORY_NAMES,
    LIST_LIMIT,
    InboxRepository,
    get_inbox_repository,
    view,
)

router = APIRouter(prefix="/notifications", tags=["notifications"])
anyone = require_roles(*UserRole)


class BellPrefs(BaseModel):
    model_config = ConfigDict(extra="forbid")
    messages: bool = True
    alerts: bool = True
    appointments: bool = True
    orders: bool = True
    medication: bool = True
    other: bool = True


@router.get("")
def my_notifications(
    user: CurrentUser = Depends(anyone),
    inbox: InboxRepository = Depends(get_inbox_repository),
) -> dict[str, Any]:
    items = [view(i, n) for i, n in inbox.for_user(user.uid, LIST_LIMIT)]
    return {"notifications": items, "unread": inbox.unread_count(user.uid)}


@router.post("/read-all")
def read_all(
    user: CurrentUser = Depends(anyone),
    inbox: InboxRepository = Depends(get_inbox_repository),
) -> dict[str, Any]:
    return {"updated": inbox.mark_all_read(user.uid)}


class ReadMatching(BaseModel):
    model_config = ConfigDict(extra="forbid")
    type: str = Field(min_length=1, max_length=40)
    # Optional push-data filter, e.g. {"from": doctorUid} or {"id": conversationId}.
    data: dict[str, str] = Field(default_factory=dict, max_length=4)


@router.post("/read-matching")
def read_matching(
    body: ReadMatching,
    user: CurrentUser = Depends(anyone),
    inbox: InboxRepository = Depends(get_inbox_repository),
) -> dict[str, Any]:
    """D-79: opening a chat clears the bell entries for it (they stayed unread before)."""
    n = 0
    for nid, item in inbox.unread_of_type(user.uid, body.type):
        data = item.get("data") or {}
        if all(str(data.get(k)) == v for k, v in body.data.items()):
            inbox.mark_read(nid)
            n += 1
    return {"updated": n}


@router.post("/{notification_id}/read", status_code=status.HTTP_204_NO_CONTENT)
def read_one(
    notification_id: str,
    user: CurrentUser = Depends(anyone),
    inbox: InboxRepository = Depends(get_inbox_repository),
) -> None:
    n = inbox.get(notification_id)
    if n is None or n.get("userId") != user.uid:
        raise ApiError("NOTIFICATION_NOT_FOUND", "Notification not found.", 404)
    inbox.mark_read(notification_id)


@router.get("/prefs")
def get_prefs(
    user: CurrentUser = Depends(anyone),
    inbox: InboxRepository = Depends(get_inbox_repository),
) -> dict[str, bool]:
    saved = inbox.bell_prefs(user.uid)
    return {c: saved.get(c) is not False for c in CATEGORY_NAMES}


@router.put("/prefs")
def put_prefs(
    body: BellPrefs,
    user: CurrentUser = Depends(anyone),
    inbox: InboxRepository = Depends(get_inbox_repository),
) -> dict[str, bool]:
    prefs = body.model_dump()
    inbox.set_bell_prefs(user.uid, prefs)
    return prefs

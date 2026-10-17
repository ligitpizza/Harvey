"""System health tools (D-79): a live test per service and its recent errors.

- Test now: runs one real check of that service and reports the result and latency. Nothing
  costs money: Stripe is test mode, the courier only quotes, Gemini answers one short prompt.
- Recent errors: an in-memory ring buffer of the backend's own ERROR log lines, grouped by
  service. It is per running instance and resets when Cloud Run restarts (documented
  limitation; Cloud Logging keeps the full history).
"""

from __future__ import annotations

import logging
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from app.core.config import Settings

ERRORS_KEPT = 20

# Logger name (careflow.*) -> System health service key.
LOGGER_SERVICE = {
    "careflow.notify": "push",
    "careflow.push": "push",
    "careflow.inbox": "push",
    "careflow.email": "email",
    "careflow.sms": "sms",
    "careflow.agent": "ai",
    "careflow.gemini": "ai",
    "careflow.ml": "ml",
    "careflow.payments": "stripe",
    "careflow.delivery": "grab",
    "careflow.orders": "grab",
}
SERVICES = ("api", "firestore", "ml", "push", "email", "ai", "sms", "stripe", "grab")


class ErrorBuffer(logging.Handler):
    """Keeps the last few ERROR records per service (no request bodies are ever logged)."""

    def __init__(self) -> None:
        super().__init__(level=logging.ERROR)
        self.items: dict[str, deque[dict[str, str]]] = {
            s: deque(maxlen=ERRORS_KEPT) for s in SERVICES
        }

    def emit(self, record: logging.LogRecord) -> None:
        service = LOGGER_SERVICE.get(record.name, "api")
        first = record.getMessage().splitlines()[0][:300]
        if record.exc_info and record.exc_info[1] is not None:
            exc = record.exc_info[1]
            first += f" ({type(exc).__name__}: {str(exc)[:150]})"
        self.items[service].append(
            {"at": datetime.fromtimestamp(record.created, UTC).isoformat(), "message": first}
        )

    def recent(self, service: str) -> list[dict[str, str]]:
        return list(reversed(self.items.get(service, deque())))


ERRORS = ErrorBuffer()


def install_error_buffer() -> None:
    logger = logging.getLogger("careflow")
    if ERRORS not in logger.handlers:
        logger.addHandler(ERRORS)


@dataclass
class TestResult:
    ok: bool
    message: str
    latency_ms: float


def timed(fn: Callable[[], str]) -> TestResult:
    start = time.perf_counter()
    try:
        message = fn()
        ok = True
    except Exception as e:  # report, never raise
        message = f"{type(e).__name__}: {str(e)[:200]}"
        ok = False
    return TestResult(ok, message, round((time.perf_counter() - start) * 1000, 1))


def stripe_ping(settings: Settings) -> str:
    import httpx

    key = settings.stripe_secret_key
    if not key:
        return "Simulated payments (no Stripe key); nothing to reach."
    if not key.startswith("sk_test_"):
        raise RuntimeError("Only Stripe test keys are allowed.")
    res = httpx.get("https://api.stripe.com/v1/balance", auth=(key, ""), timeout=10)
    res.raise_for_status()
    return "Stripe test mode answered (balance read)."


def test_service(key: str, deps: dict[str, Any]) -> dict[str, Any]:
    """deps: settings, probe, notifier, email, sms, llm, courier, admin (uid, name, email,
    phone). Returns {ok, message, latencyMs}."""
    from app.integrations.delivery import Destination
    from app.integrations.email import EmailMessage
    from app.integrations.push import PushMessage
    from app.services.system_health import SAMPLE_INPUTS

    settings: Settings = deps["settings"]
    admin: dict[str, Any] = deps["admin"]

    def api() -> str:
        return "The API answered this request."

    def firestore() -> str:
        deps["probe"].firestore()
        return "Firestore answered."

    def ml() -> str:
        model = deps["probe"].model
        if model is None:
            raise RuntimeError("Model files are not loaded.")
        model.predict(SAMPLE_INPUTS)
        return "Test prediction from all five models."

    def push() -> str:
        deps["notifier"].notify(
            admin["uid"],
            PushMessage("Harvey test notification", "System health test.", {"type": "test"}),
        )
        return "A test notification was sent to your bell" + (
            " and devices." if settings.fcm_enabled else " (pushes are only logged)."
        )

    def email() -> str:
        if not admin.get("email"):
            raise RuntimeError("Your account has no email address.")
        sent = deps["email"].send(
            EmailMessage(
                admin["email"],
                admin.get("name") or "Admin",
                "Harvey test email",
                "This is a System health test email from Harvey.",
                "<p>This is a System health test email from Harvey.</p>",
            )
        )
        if not sent:
            raise RuntimeError("The email service did not accept the message.")
        return f"Test email sent to {admin['email']}."

    def ai() -> str:
        reply = deps["llm"].generate("Reply with the single word OK.", [], "Health check")
        return f"Gemini answered: {reply.strip()[:60]}"

    def sms() -> str:
        phone = admin.get("phone")
        if not phone:
            raise RuntimeError("Add your phone number in Settings to receive a test SMS.")
        if not deps["sms"].send(str(phone), "Harvey test SMS (System health)."):
            raise RuntimeError("The SMS service did not accept the message.")
        return f"Test SMS sent to {phone}."

    def stripe() -> str:
        return stripe_ping(settings)

    def grab() -> str:
        courier = deps["courier"]
        if courier.simulated:
            return "Simulated courier; nothing to reach."
        lat, lng = settings.pharmacy_lat, settings.pharmacy_lng
        if lat is None or lng is None:
            raise RuntimeError("Pharmacy location is not set.")
        fee = courier.quote(
            Destination(
                "Test drop-off near the pharmacy",
                lat + 0.01,
                lng + 0.01,
                "Test",
                settings.pharmacy_phone,
            )
        )
        if fee is None:
            raise RuntimeError(f"{courier.brand} returned no quote.")
        return f"{courier.brand} sandbox quoted RM{fee:.2f} for a 1.5 km trip."

    tests: dict[str, Callable[[], str]] = {
        "api": api,
        "firestore": firestore,
        "ml": ml,
        "push": push,
        "email": email,
        "ai": ai,
        "sms": sms,
        "stripe": stripe,
        "grab": grab,
    }
    if key not in tests:
        raise KeyError(key)
    r = timed(tests[key])
    if not r.ok:
        logging.getLogger("careflow.admin").warning("Health test %s failed: %s", key, r.message)
    return {"ok": r.ok, "message": r.message, "latencyMs": r.latency_ms}

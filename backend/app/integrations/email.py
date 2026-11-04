"""Email adapter (D-22). Real providers: Gmail SMTP with an App Password (D-81, preferred
when SMTP_PASSWORD is set) or the Brevo transactional API. Fake: logs to console.

Selected by INTEGRATIONS_MODE (docs/05 "External integrations"); every provider
sits behind the same interface so the rest of the code never imports a provider.
"""

import logging
import smtplib
import ssl
from dataclasses import dataclass
from email.message import EmailMessage as MimeMessage
from email.utils import formataddr
from typing import Protocol

import httpx

from app.core.config import Settings, get_settings

log = logging.getLogger("careflow.email")

BREVO_SEND_URL = "https://api.brevo.com/v3/smtp/email"


@dataclass(frozen=True)
class EmailMessage:
    to_email: str
    to_name: str
    subject: str
    text: str
    html: str


def plain_link_html(url: str, label: str) -> str:
    """D-65: a link shown as plain text, not an <a> tag. Brevo rewrites every <a> link
    through its click-tracking redirect (which can't be turned off on the free plan and was
    failing); mail apps such as Gmail make plain addresses clickable themselves, so the
    click goes straight to the real page."""
    import html as _html

    return (
        f"<p>{_html.escape(label)}</p>"
        '<p style="font-family:monospace;font-size:13px;word-break:break-all;'
        'background:#f2f5f8;padding:10px;border-radius:8px">'
        f"{_html.escape(url)}</p>"
    )


class EmailError(Exception):
    pass


class EmailClient(Protocol):
    def send(self, message: EmailMessage) -> bool:
        """Send the message. Returns True only if it was handed to a real provider."""
        ...


class ConsoleEmailClient:
    """Fake used locally and in tests: records and logs instead of sending."""

    def __init__(self) -> None:
        self.sent: list[EmailMessage] = []

    def send(self, message: EmailMessage) -> bool:
        self.sent.append(message)
        # Body at DEBUG only: it can contain health data (e.g. BP reports, D-37).
        log.info("[fake email] to=%s subject=%s", message.to_email, message.subject)
        log.debug("[fake email] body:\n%s", message.text)
        return False  # nothing was actually delivered


class BrevoEmailClient:
    def __init__(self, api_key: str, sender_email: str, sender_name: str) -> None:
        if not api_key or not sender_email:
            raise EmailError("Brevo is not configured (EMAIL_API_KEY / EMAIL_FROM).")
        self._api_key = api_key
        self._sender = {"email": sender_email, "name": sender_name}

    def send(self, message: EmailMessage) -> bool:
        payload = {
            "sender": self._sender,
            "to": [{"email": message.to_email, "name": message.to_name}],
            "subject": message.subject,
            "textContent": message.text,
            "htmlContent": message.html,
        }
        try:
            res = httpx.post(
                BREVO_SEND_URL,
                json=payload,
                headers={"api-key": self._api_key, "accept": "application/json"},
                timeout=10.0,
            )
        except httpx.HTTPError as exc:
            raise EmailError(f"Brevo request failed: {exc}") from exc
        if res.status_code >= 300:
            raise EmailError(f"Brevo rejected the email (HTTP {res.status_code}).")
        return True


class SmtpEmailClient:
    """D-81: Gmail's SMTP server (smtp.gmail.com:465, SSL) signed in with an App Password.
    Brevo disabled sending on the project's free account (17 Oct 2026)."""

    def __init__(
        self,
        host: str,
        port: int,
        user: str,
        password: str,
        sender_email: str,
        sender_name: str,
        timeout: float = 15.0,
    ) -> None:
        if not user or not password:
            raise EmailError("SMTP is not configured (SMTP_USER / SMTP_PASSWORD).")
        self._host, self._port, self._user, self._password = host, port, user, password
        self._from = formataddr((sender_name, sender_email or user))
        self._timeout = timeout

    def build(self, message: EmailMessage) -> MimeMessage:
        mime = MimeMessage()
        mime["From"] = self._from
        mime["To"] = formataddr((message.to_name, message.to_email))
        mime["Subject"] = message.subject
        mime.set_content(message.text)
        mime.add_alternative(message.html, subtype="html")
        return mime

    def send(self, message: EmailMessage) -> bool:
        mime = self.build(message)
        try:
            with smtplib.SMTP_SSL(
                self._host, self._port, timeout=self._timeout, context=ssl.create_default_context()
            ) as server:
                server.login(self._user, self._password)
                server.send_message(mime)
        except (smtplib.SMTPException, OSError) as exc:
            raise EmailError(f"SMTP send failed: {type(exc).__name__}") from exc
        log.info("Email sent by SMTP: subject=%s", message.subject)
        return True


def build_email_client(settings: Settings) -> EmailClient:
    if settings.integrations_mode == "real" and settings.smtp_password:
        return SmtpEmailClient(
            settings.smtp_host,
            settings.smtp_port,
            settings.smtp_user or settings.email_from,
            settings.smtp_password,
            settings.email_from,
            settings.email_from_name,
        )
    if settings.integrations_mode == "real" and settings.email_api_key:
        return BrevoEmailClient(
            settings.email_api_key, settings.email_from, settings.email_from_name
        )
    return ConsoleEmailClient()


def get_email_client() -> EmailClient:
    """Dependency so tests can inject a fake."""
    return build_email_client(get_settings())

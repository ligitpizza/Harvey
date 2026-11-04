"""D-81 Gmail SMTP email adapter (no network: smtplib is replaced)."""

from typing import Any, ClassVar

import pytest

from app.core.config import Settings
from app.integrations import email as email_mod
from app.integrations.email import (
    BrevoEmailClient,
    ConsoleEmailClient,
    EmailError,
    EmailMessage,
    SmtpEmailClient,
    build_email_client,
)

MSG = EmailMessage(
    "p@x.my", "Siti", "Your Harvey reset code: 123456", "Code 123456", "<p>123456</p>"
)


class FakeSmtp:
    sent: ClassVar[list[Any]] = []
    logins: ClassVar[list[tuple[str, str]]] = []
    fail = False

    def __init__(self, host: str, port: int, timeout: float, context: Any) -> None:
        self.host, self.port = host, port

    def __enter__(self) -> "FakeSmtp":
        return self

    def __exit__(self, *a: Any) -> None:
        return None

    def login(self, user: str, password: str) -> None:
        if FakeSmtp.fail:
            raise email_mod.smtplib.SMTPAuthenticationError(535, b"bad")
        FakeSmtp.logins.append((user, password))

    def send_message(self, mime: Any) -> None:
        FakeSmtp.sent.append(mime)


@pytest.fixture(autouse=True)
def fake_smtp(monkeypatch: pytest.MonkeyPatch) -> None:
    FakeSmtp.sent, FakeSmtp.logins, FakeSmtp.fail = [], [], False
    monkeypatch.setattr(email_mod.smtplib, "SMTP_SSL", FakeSmtp)


def settings(**kw: Any) -> Settings:
    return Settings(_env_file=None, **{"integrations_mode": "real", **kw})


def test_smtp_is_preferred_when_its_password_is_set() -> None:
    both = settings(smtp_password="app-pass", email_api_key="brevo", email_from="h@gmail.com")
    assert isinstance(build_email_client(both), SmtpEmailClient)
    assert isinstance(
        build_email_client(settings(email_api_key="k", email_from="h@gmail.com")), BrevoEmailClient
    )
    assert isinstance(build_email_client(settings()), ConsoleEmailClient)
    fake_mode = Settings(_env_file=None, integrations_mode="fake", smtp_password="x")
    assert isinstance(build_email_client(fake_mode), ConsoleEmailClient)


def test_sends_text_and_html_signed_in_as_the_sender() -> None:
    client = build_email_client(
        settings(smtp_password="app-pass", email_from="harvey@gmail.com", email_from_name="Harvey")
    )
    assert client.send(MSG) is True
    assert FakeSmtp.logins == [("harvey@gmail.com", "app-pass")]
    mime = FakeSmtp.sent[0]
    assert mime["From"] == "Harvey <harvey@gmail.com>"
    assert mime["To"] == "Siti <p@x.my>"
    assert mime["Subject"] == "Your Harvey reset code: 123456"
    assert [p.get_content_type() for p in mime.iter_parts()] == ["text/plain", "text/html"]


def test_login_failure_is_an_email_error_without_the_password() -> None:
    FakeSmtp.fail = True
    client = SmtpEmailClient(
        "smtp.gmail.com", 465, "h@gmail.com", "secret-pass", "h@gmail.com", "H"
    )
    with pytest.raises(EmailError) as err:
        client.send(MSG)
    assert "secret-pass" not in str(err.value)

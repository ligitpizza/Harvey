"""D-129: sign-in for walk-in patients registered without an email.

Firebase email/password needs an email, so such a patient's Firebase login is an alias
made from their MyKad or passport number: digits/letters only, lower-case, at a reserved
`.invalid` domain that can never receive mail. The app builds the same alias when the
patient types their MyKad or passport on the sign-in page (app/lib/core/utils/login_alias.dart).
`users.email` stays null for them; Harvey never emails an alias.
"""

from __future__ import annotations

import re

ALIAS_DOMAIN = "id.harvey.invalid"


def login_alias(identity_number: str) -> str:
    """900101-14-5678 -> 900101145678@id.harvey.invalid; A1234567 -> a1234567@id.harvey.invalid."""
    compact = re.sub(r"[\s-]", "", identity_number).lower()
    return f"{compact}@{ALIAS_DOMAIN}"


def is_alias(email: str | None) -> bool:
    return bool(email) and str(email).strip().lower().endswith(f"@{ALIAS_DOMAIN}")

"""D-82 Malaysian mobile numbers (patient phone, emergency contact, staff phone)."""

import pytest

from app.schemas.auth import _check_phone


@pytest.mark.parametrize(
    ("given", "saved"),
    [
        ("012-345 6789", "+60123456789"),
        ("0123456789", "+60123456789"),
        ("+60 12-345 6789", "+60123456789"),
        ("60123456789", "+60123456789"),
        ("011-2345 6789", "+601123456789"),
        ("019 888 7777", "+60198887777"),
    ],
)
def test_malaysian_mobiles_are_saved_with_60(given: str, saved: str) -> None:
    assert _check_phone(given) == saved


@pytest.mark.parametrize(
    "bad",
    [
        "03-1234 5678",  # landline
        "+65 9123 4567",  # Singapore
        "012-345",  # too short
        "011-234 5678",  # 011 needs 8 digits after it
        "012-3456 78901",  # too long
        "12345678901",
        "01a-2345678",
    ],
)
def test_other_numbers_are_refused(bad: str) -> None:
    with pytest.raises(ValueError):
        _check_phone(bad)

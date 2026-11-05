"""D-82 dose = number + unit (patient medications, reported and doctor prescriptions)."""

import pytest

from app.schemas.dose import normalise_dose


@pytest.mark.parametrize(
    ("given", "saved"),
    [
        ("5mg", "5mg"),
        ("5 MG", "5mg"),
        ("2.5 ml", "2.5ml"),
        ("100 iu", "100IU"),
        ("1 tablet", "1 tablet"),
        ("2 Tablet", "2 tablets"),
        ("0.5 tablets", "0.5 tablets"),
        ("10.0 mcg", "10mcg"),
    ],
)
def test_valid_doses_are_tidied(given: str, saved: str) -> None:
    assert normalise_dose(given) == saved


@pytest.mark.parametrize(
    "bad", ["1", "five mg", "5mg!", "5 mg 1 tablet", "-5 mg", "0 mg", "5 spoons", "1.234 mg", ""]
)
def test_letters_symbols_and_unknown_units_are_refused(bad: str) -> None:
    with pytest.raises(ValueError):
        normalise_dose(bad)


def test_api_refuses_a_bad_dose(client, med_repo) -> None:  # type: ignore[no-untyped-def]
    from tests.conftest import bearer

    res = client.post(
        "/api/v1/medications",
        json={"name": "Amlodipine", "dosage": "5mg@@", "schedule": "08:00"},
        headers=bearer("patient-token"),
    )
    assert res.status_code == 422

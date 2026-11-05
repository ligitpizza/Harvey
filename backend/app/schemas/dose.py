"""D-82: a dose is a number plus a unit ("5 mg", "2.5 ml", "1 tablet", "2 tablets").

The app enters the amount (digits and one decimal point only) and picks the unit from a
list; the API checks the same rule, so a dose can't contain other characters. Stored as
one string (docs/04 `dosage`), written like the existing data: strengths without a space
("5mg", "2.5ml"), counts with one ("1 tablet", "2 tablets").
"""

import re

# Strength units, then count units (pluralised when the amount isn't 1).
STRENGTH_UNITS = ("mg", "mcg", "g", "ml", "IU")
COUNT_UNITS = ("tablet", "capsule", "drop", "puff", "sachet")
DOSE_UNITS = STRENGTH_UNITS + COUNT_UNITS

_UNIT_LOOKUP = {u.lower(): u for u in STRENGTH_UNITS} | {
    **{u: u for u in COUNT_UNITS},
    **{f"{u}s": u for u in COUNT_UNITS},
}
_DOSE_RE = re.compile(r"^\s*(\d{1,4}(?:\.\d{1,2})?)\s*([A-Za-z]+)\s*$")


def normalise_dose(value: str) -> str:
    """'5 MG' -> '5mg', '2 Tablet' -> '2 tablets'. ValueError when it isn't a dose."""
    m = _DOSE_RE.match(value or "")
    if not m:
        raise ValueError("Enter the dose as a number and a unit, e.g. 5 mg or 1 tablet.")
    amount_text, unit_text = m.group(1), m.group(2)
    unit = _UNIT_LOOKUP.get(unit_text.lower())
    if unit is None:
        raise ValueError(f"Choose a unit: {', '.join(DOSE_UNITS)}.")
    amount = float(amount_text)
    if amount <= 0:
        raise ValueError("The dose must be more than 0.")
    shown = f"{amount:g}"
    if unit in STRENGTH_UNITS:
        return f"{shown}{unit}"
    return f"{shown} {unit}{'' if amount == 1 else 's'}"

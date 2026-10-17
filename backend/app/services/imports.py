"""CSV / JSON imports (D-79) for the inventory and staff accounts.

The admin (or pharmacist, for inventory) uploads a file; the server parses it, validates
every row and returns a preview (`commit=false`). Saving (`commit=true`) applies only the
rows that are valid. Templates list the expected columns.
"""

from __future__ import annotations

import csv
import io
import json
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError

MAX_ROWS = 500
MAX_BYTES = 512 * 1024

INVENTORY_COLUMNS = [
    "name",
    "strength",
    "form",
    "drugClass",
    "unitPrice",
    "units",
    "lowStockAt",
    "expiryDate",
]
USER_COLUMNS = ["name", "email", "role", "specialty"]

INVENTORY_TEMPLATE = (
    "name,strength,form,drugClass,unitPrice,units,lowStockAt,expiryDate\n"
    "Amlodipine,5mg,tablet,Calcium channel blocker,0.30,600,100,2027-06-30\n"
)
USER_TEMPLATE = (
    "name,email,role,specialty\n"
    "Dr Aisha Rahman,aisha@example.com,doctor,Cardiology\n"
    "Lim Wei,lim.wei@example.com,pharmacist,\n"
)


class FileImportError(ValueError):
    """The file itself could not be read."""


def parse(content: str, fmt: str) -> list[dict[str, Any]]:
    if len(content.encode()) > MAX_BYTES:
        raise FileImportError("The file is larger than 512 KB.")
    if fmt == "json":
        try:
            data = json.loads(content)
        except ValueError as e:
            raise FileImportError(f"Not valid JSON: {e}") from e
        if isinstance(data, dict):
            data = data.get("rows") or data.get("items") or data.get("users") or []
        if not isinstance(data, list) or not all(isinstance(r, dict) for r in data):
            raise FileImportError('JSON must be a list of objects (or {"rows": [...]}).')
        rows = [dict(r) for r in data]
    elif fmt == "csv":
        reader = csv.DictReader(io.StringIO(content.lstrip("﻿")))
        rows = [{k.strip(): (v or "").strip() for k, v in r.items() if k} for r in reader]
    else:
        raise FileImportError("Format must be csv or json.")
    if not rows:
        raise FileImportError("The file has no rows.")
    if len(rows) > MAX_ROWS:
        raise FileImportError(f"At most {MAX_ROWS} rows per import.")
    return rows


def _blank_to_none(row: dict[str, Any]) -> dict[str, Any]:
    """Blank cells mean "not given", so the field's default applies."""
    return {k: v for k, v in row.items() if v not in ("", None)}


class InventoryRow(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)
    name: str = Field(min_length=2, max_length=80)
    strength: str = Field(min_length=1, max_length=30)
    form: str = "tablet"
    drugClass: str = Field(default="", max_length=60)  # noqa: N815
    unitPrice: float = Field(ge=0.01, le=1000)  # noqa: N815
    units: int | None = Field(default=None, ge=0, le=1_000_000)
    lowStockAt: int = Field(default=50, ge=0, le=1_000_000)  # noqa: N815
    expiryDate: str | None = None  # noqa: N815


class UserRow(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)
    name: str = Field(min_length=2, max_length=100)
    email: str = Field(min_length=5, max_length=200, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    role: str
    specialty: str | None = Field(default=None, max_length=80)


def validate_rows(
    rows: list[dict[str, Any]], model: type[BaseModel]
) -> list[tuple[int, BaseModel | None, str | None]]:
    """(row number, parsed row or None, error or None); row 1 is the first data row."""
    out: list[tuple[int, BaseModel | None, str | None]] = []
    for n, raw in enumerate(rows, start=1):
        try:
            out.append((n, model.model_validate(_blank_to_none(raw)), None))
        except ValidationError as e:
            first = e.errors()[0]
            field = ".".join(str(p) for p in first.get("loc", ())) or "row"
            out.append((n, None, f"{field}: {first.get('msg')}"))
    return out

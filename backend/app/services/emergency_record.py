"""D-86: an "Emergency event summary" PDF saved to the patient's Health Records whenever an
emergency happens (an Emergency-band reading, or an emergency symptom-check outcome), so the
event is part of the medical record the patient and doctor can open. Shared with the
assigned doctor automatically. Best effort: a failure here never blocks the alerts.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from app.core.enums import RecordCategory
from app.services.medications import MYT
from app.services.records import FileStore, RecordRepository, storage_path

log = logging.getLogger("careflow.emergency_record")


@dataclass
class EmergencyEvent:
    patient_id: str
    patient_name: str
    trigger: str  # e.g. "Blood pressure in the hypertensive crisis range"
    at: datetime
    systolic: int | None = None
    diastolic: int | None = None
    heart_rate: int | None = None
    symptoms: list[str] = field(default_factory=list)
    severity: str | None = None
    risk_lines: list[str] = field(default_factory=list)  # "Stroke: high (31%)"
    notified: list[str] = field(default_factory=list)  # "Assigned doctor: Dr John"
    appointment: str | None = None  # "Mon 16 Nov, 9:00 AM with Dr John"
    actions: list[str] = field(default_factory=list)


def _latin1(text: object) -> str:
    return str(text).encode("latin-1", "replace").decode("latin-1")


def emergency_pdf(e: EmergencyEvent) -> bytes:
    from fpdf import FPDF

    pdf = FPDF()
    pdf.add_page()
    width = pdf.epw

    def line(text: object, size: int = 11, style: str = "") -> None:
        pdf.set_font("Helvetica", style, size)
        pdf.multi_cell(width, 6 if size <= 11 else 9, _latin1(text), new_x="LMARGIN", new_y="NEXT")

    def heading(text: str) -> None:
        pdf.ln(3)
        line(text, 12, "B")

    line("Harvey - Emergency event summary", 16, "B")
    line(f"Patient: {e.patient_name}")
    line(f"Time: {e.at.astimezone(MYT):%a %d %b %Y, %H:%M} (Malaysia time)")
    line(f"Trigger: {e.trigger}")
    heading("Vital signs")
    if e.systolic is not None and e.diastolic is not None:
        line(f"Blood pressure: {e.systolic}/{e.diastolic} mmHg")
    else:
        line("Blood pressure: not recorded with this event")
    line(
        f"Heart rate: {e.heart_rate} bpm (camera estimate)"
        if e.heart_rate
        else "Heart rate: not recorded"
    )
    if e.symptoms:
        heading("Symptoms reported")
        line(", ".join(e.symptoms) + (f" (severity: {e.severity})" if e.severity else ""))
    heading("Risk scores at the time")
    for r in e.risk_lines or ["No risk score yet."]:
        line(f"- {r}")
    heading("Who was notified")
    for n in e.notified or ["The patient (in the app)."]:
        line(f"- {n}")
    heading("Actions taken")
    if e.appointment:
        line(f"- Emergency appointment booked: {e.appointment}")
    for a in e.actions:
        line(f"- {a}")
    pdf.ln(4)
    line(
        "If you feel unwell, call 999. This summary was generated automatically by Harvey "
        "and is not a diagnosis.",
        9,
    )
    return bytes(pdf.output())


def store_emergency_summary(records: RecordRepository, files: FileStore, e: EmergencyEvent) -> str:
    """Saves the PDF as a health record (category "emergency", shared with the doctor)."""
    record_id = f"emergency_{e.at.astimezone(UTC):%Y%m%dT%H%M%S}"
    data = emergency_pdf(e)
    path = storage_path(e.patient_id, record_id)
    files.write(path, data, "application/pdf")
    records.create(
        record_id,
        {
            "patientId": e.patient_id,
            "fileUrl": path,
            "fileName": f"Emergency event {e.at.astimezone(MYT):%d %b %Y %H%M}.pdf",
            "contentType": "application/pdf",
            "sizeBytes": len(data),
            "category": RecordCategory.EMERGENCY.value,
            "uploadedAt": e.at,
            "sharedWithDoctor": True,
        },
    )
    return record_id


def try_store(records: RecordRepository, files: FileStore, e: EmergencyEvent) -> str | None:
    try:
        return store_emergency_summary(records, files, e)
    except Exception:
        log.exception("Emergency summary not saved for %s", e.patient_id)
        return None


def risk_lines(scores: dict[Any, Any]) -> list[str]:
    """`{Complication: ComplicationRisk}` or `{name: level}` -> readable lines."""
    names = {
        "stroke": "Stroke",
        "cad": "Coronary artery disease",
        "heartFailure": "Heart failure",
        "ckd": "Chronic kidney disease",
        "t2d": "Type 2 diabetes",
    }
    out = []
    for k, v in scores.items():
        key = getattr(k, "value", k)
        label = names.get(str(key), str(key))
        level = getattr(getattr(v, "level", v), "value", getattr(v, "level", v))
        value = getattr(v, "value", None)
        pct = f" ({value * 100:.0f}%)" if isinstance(value, float) else ""
        out.append(f"{label}: {level}{pct}")
    return out

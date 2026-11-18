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


def emergency_pdf(e: EmergencyEvent) -> bytes:
    """D-108: Harvey logo header, an alert banner, then tables like the other reports."""
    from app.services.pdf_layout import HarveyDoc

    when = f"{e.at.astimezone(MYT):%a %d %b %Y, %H:%M} (Malaysia time)"
    doc = HarveyDoc("Emergency event summary", [e.patient_name, when])
    doc.banner(f"Trigger: {e.trigger}", alert=True)
    doc.facts([("Patient", e.patient_name), ("Time", when)])

    doc.heading("Vital signs")
    bp = (
        f"{e.systolic}/{e.diastolic} mmHg"
        if e.systolic is not None and e.diastolic is not None
        else "Not recorded with this event"
    )
    hr = f"{e.heart_rate} bpm (camera estimate)" if e.heart_rate else "Not recorded"
    doc.table(["Measure", "Value"], [["Blood pressure", bp], ["Heart rate", hr]], (40, 60))

    if e.symptoms:
        doc.heading("Symptoms reported")
        doc.table(
            ["Symptom", "Severity"],
            [[s, e.severity or "-"] for s in e.symptoms],
            (70, 30),
        )

    doc.heading("Risk scores at the time")
    if e.risk_lines:
        rows = [r.split(": ", 1) if ": " in r else [r, "-"] for r in e.risk_lines]
        doc.table(["Condition", "Level"], rows, (60, 40))
    else:
        doc.para("No risk score yet.")

    doc.heading("Who was notified")
    doc.table(
        ["Notified"],
        [[n] for n in (e.notified or ["The patient (in the app)."])],
        (100,),
    )

    doc.heading("Actions taken")
    actions = ([f"Emergency appointment booked: {e.appointment}"] if e.appointment else []) + list(
        e.actions
    )
    if actions:
        doc.table(["Action"], [[a] for a in actions], (100,))
    else:
        doc.para("No further action recorded.")

    doc.footnote(
        "If you feel unwell, call 999. This summary was generated automatically by Harvey "
        "and is not a diagnosis."
    )
    return doc.output()


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

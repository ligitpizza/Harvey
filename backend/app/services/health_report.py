"""D-100: Harvey health reports saved to the patient's Health Records as PDFs.

One builder, three uses:
- the patient's own "health summary" (Records > Create health summary);
- the Harvey Assistant's weekly summary, saved when the patient presses "Save as PDF";
- a doctor's written report on the patient (read-only for the patient, shared both ways).

Every report carries the same snapshot of the patient's latest numbers (last 30 days of
blood pressure, risk levels, medicines and adherence, upcoming appointments), taken from
the same data the assistant uses (`AgentDataRepository`), so the numbers always agree.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from app.core.enums import RecordCategory
from app.services.agent_context import MYT, AgentDataRepository
from app.services.bp import classify
from app.services.records import FileStore, RecordRepository, storage_path

LOGO = Path(__file__).resolve().parent.parent / "assets" / "harvey_logo.png"
NAVY = (31, 58, 95)
BLUE = (47, 128, 237)
LIGHT = (237, 243, 250)
WINDOW = timedelta(days=30)


def _latin1(text: object) -> str:
    return str(text).encode("latin-1", "replace").decode("latin-1")


@dataclass
class Snapshot:
    """The patient's latest numbers, as printed in every report."""

    patient_name: str
    doctor_name: str | None
    readings: int = 0
    average: str | None = None  # "132/84 mmHg (Hypertension stage 1)"
    highest: str | None = None
    lowest: str | None = None
    latest: str | None = None  # "128/82 mmHg on 14 Nov, 08:10"
    heart_rate: str | None = None
    risks: list[str] = field(default_factory=list)
    medicines: list[tuple[str, str, str]] = field(default_factory=list)  # name, when, adherence
    appointments: list[str] = field(default_factory=list)


def _when(v: Any) -> str:
    return f"{v.astimezone(MYT):%d %b %Y, %H:%M}" if isinstance(v, datetime) else "-"


def snapshot(repo: AgentDataRepository, uid: str, now: datetime) -> Snapshot:
    me = repo.user(uid) or {}
    doctor = repo.user(str(me["assignedDoctorId"])) if me.get("assignedDoctorId") else None
    s = Snapshot(
        patient_name=str(me.get("name") or "Patient"),
        doctor_name=str(doctor.get("name")) if doctor and doctor.get("name") else None,
    )
    rows = [r for r in repo.readings_since(uid, now - WINDOW) if r.get("systolic")]
    if rows:
        s.readings = len(rows)
        sys_avg = round(sum(int(r["systolic"]) for r in rows) / len(rows))
        dia_avg = round(sum(int(r["diastolic"]) for r in rows) / len(rows))
        s.average = f"{sys_avg}/{dia_avg} mmHg ({classify(sys_avg, dia_avg).value})"
        hi = max(rows, key=lambda r: (int(r["systolic"]), int(r["diastolic"])))
        lo = min(rows, key=lambda r: (int(r["systolic"]), int(r["diastolic"])))
        s.highest = f"{hi['systolic']}/{hi['diastolic']} mmHg on {_when(hi.get('timestamp'))}"
        s.lowest = f"{lo['systolic']}/{lo['diastolic']} mmHg on {_when(lo.get('timestamp'))}"
        stamped = [r for r in rows if isinstance(r.get("timestamp"), datetime)]
        last = max(stamped, key=lambda r: r["timestamp"]) if stamped else rows[0]
        s.latest = f"{last['systolic']}/{last['diastolic']} mmHg on {_when(last.get('timestamp'))}"
        rates = [int(r["heartRate"]) for r in rows if r.get("heartRate")]
        if rates:
            s.heart_rate = f"{round(sum(rates) / len(rates))} bpm average (camera estimate)"
    risk = repo.latest_risk(uid) or {}
    scores = risk.get("scores") or {}
    s.risks = _risk_text(scores)
    for m in repo.medications(uid):
        rate = m.get("adherenceRate")
        schedule = str(m.get("schedule") or "")
        when = "As needed" if schedule == "as_needed" else schedule.replace(",", ", ")
        s.medicines.append(
            (
                f"{m.get('name') or 'Medicine'} {m.get('dosage') or ''}".strip(),
                when,
                "-" if rate is None or schedule == "as_needed" else f"{float(rate):.0f}%",
            )
        )
    for a in repo.upcoming_appointments(uid, now):
        s.appointments.append(
            f"{_when(a.get('dateTime'))}" + (f" - {a['reason']}" if a.get("reason") else "")
        )
    return s


_RISK_NAMES = {
    "stroke": "Stroke",
    "cad": "Coronary artery disease",
    "heartFailure": "Heart failure",
    "ckd": "Chronic kidney disease",
    "t2d": "Type 2 diabetes",
}


def _risk_text(scores: dict[str, Any]) -> list[str]:
    out = []
    for key, v in scores.items():
        if not isinstance(v, dict):
            continue
        value = v.get("value")
        pct = f" ({float(value) * 100:.0f}%)" if isinstance(value, int | float) else ""
        out.append(f"{_RISK_NAMES.get(key, key)}: {v.get('level', '-')}{pct}")
    return out


def report_pdf(
    title: str,
    snap: Snapshot,
    now: datetime,
    *,
    text_heading: str | None = None,
    text: str | None = None,
    author: str | None = None,
    footer: str = (
        "Generated by Harvey from the patient's own records. It is not a diagnosis; "
        "in an emergency call 999."
    ),
) -> bytes:
    """The PDF: logo header, an optional written section (the doctor's report or the
    assistant's summary), then the snapshot tables."""
    from fpdf import FPDF
    from fpdf.fonts import FontFace

    pdf = FPDF()
    pdf.set_auto_page_break(auto=True, margin=18)
    pdf.add_page()
    width = pdf.epw

    top = pdf.get_y()
    if LOGO.exists():
        pdf.image(str(LOGO), x=pdf.l_margin, y=top, h=24)
    pdf.set_xy(pdf.l_margin, top + 2)
    pdf.set_font("Helvetica", "B", 18)
    pdf.set_text_color(*NAVY)
    pdf.cell(width, 10, _latin1(title.upper()), align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 10)
    pdf.set_text_color(90, 90, 90)
    pdf.cell(width, 6, _latin1(snap.patient_name), align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.cell(
        width,
        6,
        _latin1(f"{now.astimezone(MYT):%d %b %Y, %H:%M} (Malaysia time)"),
        align="R",
        new_x="LMARGIN",
        new_y="NEXT",
    )
    pdf.set_y(top + 28)
    pdf.set_draw_color(*BLUE)
    pdf.set_line_width(0.8)
    pdf.line(pdf.l_margin, pdf.get_y(), pdf.l_margin + width, pdf.get_y())
    pdf.ln(5)
    pdf.set_text_color(0, 0, 0)

    def heading(t: str) -> None:
        pdf.ln(2)
        pdf.set_font("Helvetica", "B", 12)
        pdf.set_text_color(*NAVY)
        pdf.cell(width, 8, _latin1(t), new_x="LMARGIN", new_y="NEXT")
        pdf.set_text_color(0, 0, 0)

    def para(t: str, size: int = 10) -> None:
        pdf.set_font("Helvetica", "", size)
        pdf.multi_cell(width, 5.5, _latin1(t), new_x="LMARGIN", new_y="NEXT")

    def facts(rows: list[tuple[str, str]]) -> None:
        for label, value in rows:
            pdf.set_font("Helvetica", "B", 10)
            pdf.cell(48, 6, _latin1(label))
            pdf.set_font("Helvetica", "", 10)
            pdf.multi_cell(width - 48, 6, _latin1(value), new_x="LMARGIN", new_y="NEXT")

    facts(
        [
            ("Patient", snap.patient_name),
            ("Assigned doctor", snap.doctor_name or "Not assigned yet"),
            *([("Written by", author)] if author else []),
        ]
    )

    if text:
        heading(text_heading or "Notes")
        pdf.set_fill_color(*LIGHT)
        pdf.set_font("Helvetica", "", 10.5)
        pdf.multi_cell(
            width, 6, _latin1(text.strip()), fill=True, padding=3, new_x="LMARGIN", new_y="NEXT"
        )

    heading("Blood pressure (last 30 days)")
    if snap.readings:
        facts(
            [
                ("Readings", str(snap.readings)),
                ("Average", snap.average or "-"),
                ("Latest", snap.latest or "-"),
                ("Highest", snap.highest or "-"),
                ("Lowest", snap.lowest or "-"),
                *([("Heart rate", snap.heart_rate)] if snap.heart_rate else []),
            ]
        )
    else:
        para("No readings in the last 30 days.")

    heading("Complication risk (latest assessment)")
    if snap.risks:
        for r in snap.risks:
            para(f"- {r}")
    else:
        para("Not assessed yet (it needs three readings).")

    heading("Medicines")
    pdf.set_draw_color(200, 208, 220)
    pdf.set_line_width(0.2)
    if snap.medicines:
        pdf.set_font("Helvetica", "", 10)
        with pdf.table(
            col_widths=(50, 30, 20),
            text_align=("LEFT", "LEFT", "RIGHT"),
            headings_style=FontFace(emphasis="BOLD", color=(255, 255, 255), fill_color=NAVY),
            cell_fill_color=LIGHT,
            cell_fill_mode="ROWS",
            line_height=7,
            width=width,
        ) as table:
            table.row(["Medicine", "Reminder times", "Adherence (30 days)"])
            for name, when, rate in snap.medicines:
                table.row([_latin1(name), _latin1(when), rate])
    else:
        para("No medicines recorded.")

    heading("Upcoming appointments")
    for a in snap.appointments or ["None booked."]:
        para(f"- {a}" if snap.appointments else a)

    pdf.ln(6)
    pdf.set_font("Helvetica", "", 8)
    pdf.set_text_color(110, 110, 110)
    pdf.multi_cell(width, 4.5, _latin1(footer), new_x="LMARGIN", new_y="NEXT")
    return bytes(pdf.output())


def save_report(
    records: RecordRepository,
    files: FileStore,
    patient_id: str,
    *,
    prefix: str,
    file_name: str,
    data: bytes,
    category: RecordCategory,
    shared: bool,
    now: datetime,
    extra: dict[str, Any] | None = None,
) -> tuple[str, dict[str, Any]]:
    """Stores the PDF and its health record; returns (record id, record data)."""
    record_id = f"{prefix}_{now.astimezone(UTC):%Y%m%dT%H%M%S}_{uuid.uuid4().hex[:6]}"
    path = storage_path(patient_id, record_id)
    files.write(path, data, "application/pdf")
    record = {
        "patientId": patient_id,
        "fileUrl": path,
        "fileName": file_name,
        "contentType": "application/pdf",
        "sizeBytes": len(data),
        "category": category.value,
        "uploadedAt": now,
        "sharedWithDoctor": shared,
        **({"sharedAt": now} if shared else {}),
        **(extra or {}),
    }
    records.create(record_id, record)
    return record_id, record

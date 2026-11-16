"""Payment receipt saved to the patient's health records (docs/06 §J step 4, D-66)."""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from app.services.medications import MYT
from app.services.orders import HOME_DELIVERY, line_total, order_ref
from app.services.records import FileStore, RecordRepository, storage_path
from app.services.settings import _latin1

LOGO = Path(__file__).resolve().parent.parent / "assets" / "harvey_logo.png"
NAVY = (31, 58, 95)
BLUE = (47, 128, 237)
LIGHT = (237, 243, 250)


def receipt_pdf(order_id: str, order: dict[str, Any], charge_id: str, paid_at: datetime) -> bytes:
    """D-95: a proper receipt: Harvey logo, order details, an itemised table and totals."""
    from fpdf import FPDF
    from fpdf.fonts import FontFace

    from app.services.catalog import FREQUENCIES, item_label

    pdf = FPDF()
    pdf.set_auto_page_break(auto=True, margin=18)
    pdf.add_page()
    width = pdf.epw

    # Header: logo left, title and reference right.
    top = pdf.get_y()
    if LOGO.exists():
        pdf.image(str(LOGO), x=pdf.l_margin, y=top, h=26)
    pdf.set_xy(pdf.l_margin, top + 2)
    pdf.set_font("Helvetica", "B", 20)
    pdf.set_text_color(*NAVY)
    pdf.cell(width, 10, "PAYMENT RECEIPT", align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 10)
    pdf.set_text_color(90, 90, 90)
    pdf.cell(
        width, 6, _latin1(f"Order {order_ref(order_id)}"), align="R", new_x="LMARGIN", new_y="NEXT"
    )
    pdf.cell(width, 6, "Harvey pharmacy", align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.set_y(top + 30)
    pdf.set_draw_color(*BLUE)
    pdf.set_line_width(0.8)
    pdf.line(pdf.l_margin, pdf.get_y(), pdf.l_margin + width, pdf.get_y())
    pdf.ln(5)

    # Details: two columns of label / value.
    delivery = order.get("method") == HOME_DELIVERY
    details = [
        ("Billed to", str(order.get("patientName") or "Patient")),
        ("Paid on", f"{paid_at.astimezone(MYT):%d %b %Y, %H:%M} (Malaysia time)"),
        ("Payment reference", charge_id or "-"),
        ("Fulfilment", "Home delivery" if delivery else "Self-collection at the pharmacy"),
    ]
    if delivery and order.get("deliveryAddress"):
        details.append(("Deliver to", str(order.get("deliveryAddress"))))
    pdf.set_text_color(0, 0, 0)
    for label, value in details:
        pdf.set_font("Helvetica", "B", 10)
        pdf.cell(42, 6, _latin1(label))
        pdf.set_font("Helvetica", "", 10)
        pdf.multi_cell(width - 42, 6, _latin1(value), new_x="LMARGIN", new_y="NEXT")
    pdf.ln(4)

    # Items table.
    items = list(order.get("items") or [])
    amount = float(order.get("amount") or 0)
    fee = float(order.get("deliveryFee") or 0)
    pdf.set_draw_color(200, 208, 220)
    pdf.set_line_width(0.2)
    pdf.set_font("Helvetica", "", 10)
    head = FontFace(emphasis="BOLD", color=(255, 255, 255), fill_color=NAVY)
    with pdf.table(
        col_widths=(44, 30, 12, 14),
        text_align=("LEFT", "LEFT", "RIGHT", "RIGHT"),
        headings_style=head,
        cell_fill_color=LIGHT,
        cell_fill_mode="ROWS",
        line_height=7,
        width=width,
    ) as table:
        table.row(["Medicine", "Dose and how often", "Qty", "Amount"])
        if items:
            for i in items:
                freq = FREQUENCIES.get(
                    str(i.get("frequency")), (str(i.get("frequency") or ""), "")
                )[0]
                qty = int(i.get("quantity") or 0)
                unit = float(i.get("unitPrice") or 0)
                table.row(
                    [
                        _latin1(f"{item_label(i)}\nRM{unit:.2f} each"),
                        _latin1(f"{i.get('dose') or ''}, {freq.lower()}".strip(", ")),
                        str(qty),
                        f"RM{line_total(i):.2f}",
                    ]
                )
        else:
            table.row(
                [
                    _latin1(str(order.get("medicationDetails") or "Monthly supply")),
                    "",
                    "1",
                    f"RM{amount:.2f}",
                ]
            )
    pdf.ln(3)

    # Totals, right-aligned.
    def total(label: str, value: float, bold: bool = False) -> None:
        pdf.set_font("Helvetica", "B" if bold else "", 12 if bold else 10)
        pdf.cell(width - 40, 7, label, align="R")
        pdf.cell(40, 7, f"RM{value:.2f}", align="R", new_x="LMARGIN", new_y="NEXT")

    total("Medicines", amount)
    total("Home delivery" if delivery else "Self-collection", fee if delivery else 0.0)
    pdf.set_draw_color(*NAVY)
    pdf.line(pdf.l_margin + width - 80, pdf.get_y(), pdf.l_margin + width, pdf.get_y())
    pdf.ln(1)
    total("Total paid", amount + (fee if delivery else 0.0), bold=True)

    pdf.ln(8)
    pdf.set_font("Helvetica", "", 8)
    pdf.set_text_color(110, 110, 110)
    pdf.multi_cell(
        width,
        4.5,
        "Processed securely by Stripe (test mode). Harvey never sees card details. "
        "Keep this receipt for your records; it is also saved in Harvey under Records.",
        new_x="LMARGIN",
        new_y="NEXT",
    )
    return bytes(pdf.output())


def store_receipt(
    records: RecordRepository,
    files: FileStore,
    order_id: str,
    order: dict[str, Any],
    charge_id: str,
) -> str:
    """Saves the receipt as a health record (category "other"); returns the record id."""
    record_id = f"receipt_{order_id}"
    patient_id = str(order["patientId"])
    now = datetime.now(UTC)
    data = receipt_pdf(order_id, order, charge_id, now)
    path = storage_path(patient_id, record_id)
    files.write(path, data, "application/pdf")
    records.create(
        record_id,
        {
            "patientId": patient_id,
            "fileUrl": path,
            "fileName": f"Harvey receipt {order_ref(order_id)}.pdf",
            "contentType": "application/pdf",
            "sizeBytes": len(data),
            "category": "other",
            "uploadedAt": now,
            "sharedWithDoctor": False,
        },
    )
    return record_id

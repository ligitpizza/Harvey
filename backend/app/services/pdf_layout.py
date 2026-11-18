"""D-108: one look for Harvey's PDF reports (D-95 receipt, D-100 health reports): the logo
header with the title on the right, navy section headings, label/value facts and striped
tables. Used by the emergency event summary and the admin hospital-wide report."""

from __future__ import annotations

from pathlib import Path
from typing import Any

LOGO = Path(__file__).resolve().parent.parent / "assets" / "harvey_logo.png"
NAVY = (31, 58, 95)
BLUE = (47, 128, 237)
LIGHT = (237, 243, 250)
ALERT = (198, 40, 40)
ALERT_LIGHT = (253, 236, 234)


def latin1(text: object) -> str:
    return str(text).encode("latin-1", "replace").decode("latin-1")


class HarveyDoc:
    """A Harvey-branded A4 document. `pdf` is the underlying FPDF for custom drawing."""

    def __init__(self, title: str, lines: list[str]) -> None:
        from fpdf import FPDF

        self.pdf = pdf = FPDF()
        pdf.set_auto_page_break(auto=True, margin=18)
        pdf.add_page()
        self.width = width = pdf.epw
        top = pdf.get_y()
        if LOGO.exists():
            pdf.image(str(LOGO), x=pdf.l_margin, y=top, h=24)
        pdf.set_xy(pdf.l_margin, top + 2)
        pdf.set_font("Helvetica", "B", 17)
        pdf.set_text_color(*NAVY)
        pdf.cell(width, 10, latin1(title.upper()), align="R", new_x="LMARGIN", new_y="NEXT")
        pdf.set_font("Helvetica", "", 10)
        pdf.set_text_color(90, 90, 90)
        for line in lines:
            pdf.cell(width, 5.5, latin1(line), align="R", new_x="LMARGIN", new_y="NEXT")
        pdf.set_y(max(pdf.get_y(), top + 26) + 2)
        pdf.set_draw_color(*BLUE)
        pdf.set_line_width(0.8)
        pdf.line(pdf.l_margin, pdf.get_y(), pdf.l_margin + width, pdf.get_y())
        pdf.ln(5)
        pdf.set_text_color(0, 0, 0)

    def heading(self, text: str) -> None:
        pdf = self.pdf
        if pdf.get_y() > pdf.h - pdf.b_margin - 30:
            pdf.add_page()
        pdf.ln(2)
        pdf.set_font("Helvetica", "B", 12)
        pdf.set_text_color(*NAVY)
        pdf.cell(self.width, 8, latin1(text), new_x="LMARGIN", new_y="NEXT")
        pdf.set_text_color(0, 0, 0)

    def para(self, text: str, size: float = 10) -> None:
        self.pdf.set_font("Helvetica", "", size)
        self.pdf.multi_cell(self.width, 5.5, latin1(text), new_x="LMARGIN", new_y="NEXT")

    def banner(self, text: str, alert: bool = False) -> None:
        """A shaded box for the one thing the reader must see first."""
        pdf = self.pdf
        pdf.set_fill_color(*(ALERT_LIGHT if alert else LIGHT))
        pdf.set_text_color(*(ALERT if alert else NAVY))
        pdf.set_font("Helvetica", "B", 11)
        pdf.multi_cell(
            self.width, 6.5, latin1(text), fill=True, padding=3, new_x="LMARGIN", new_y="NEXT"
        )
        pdf.set_text_color(0, 0, 0)
        pdf.ln(2)

    def facts(self, rows: list[tuple[str, str]], label_width: float = 52) -> None:
        pdf = self.pdf
        for label, value in rows:
            pdf.set_font("Helvetica", "B", 10)
            pdf.cell(label_width, 6, latin1(label))
            pdf.set_font("Helvetica", "", 10)
            pdf.multi_cell(
                self.width - label_width, 6, latin1(value), new_x="LMARGIN", new_y="NEXT"
            )

    def table(
        self,
        headings: list[str],
        rows: list[list[Any]],
        col_widths: tuple[float, ...],
        align: tuple[str, ...] | None = None,
    ) -> None:
        from fpdf.fonts import FontFace

        pdf = self.pdf
        pdf.set_draw_color(200, 208, 220)
        pdf.set_line_width(0.2)
        pdf.set_font("Helvetica", "", 10)
        # Striped rows alternate with the current fill colour, so reset it to white
        # (otherwise a bar chart's or banner's colour leaks into the table).
        pdf.set_fill_color(255, 255, 255)
        with pdf.table(
            col_widths=col_widths,
            text_align=align or tuple("LEFT" for _ in headings),
            headings_style=FontFace(emphasis="BOLD", color=(255, 255, 255), fill_color=NAVY),
            cell_fill_color=LIGHT,
            cell_fill_mode="ROWS",
            line_height=7,
            width=self.width,
        ) as t:
            t.row([latin1(h) for h in headings])
            for r in rows:
                t.row([latin1(c) for c in r])
        pdf.ln(2)

    def footnote(self, text: str) -> None:
        pdf = self.pdf
        pdf.ln(5)
        pdf.set_font("Helvetica", "", 8)
        pdf.set_text_color(110, 110, 110)
        pdf.multi_cell(self.width, 4.5, latin1(text), new_x="LMARGIN", new_y="NEXT")
        pdf.set_text_color(0, 0, 0)

    def output(self) -> bytes:
        return bytes(self.pdf.output())

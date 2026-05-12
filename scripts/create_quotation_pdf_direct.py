from datetime import date
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "documents" / "Light Winter Technologies - Quotation - Anephen Investments - FINAL.pdf"
LOGO = ROOT / "documents" / "frosty_lwt_logo_doc.jpg"


BLUE = colors.HexColor("#2A5F91")
DARK = colors.HexColor("#1D2733")
LIGHT_BLUE = colors.HexColor("#EAF2F8")
LINE = colors.HexColor("#C6D7E6")
WATERMARK = colors.HexColor("#D9E8F5")


def draw_text(c, x, y, text, size=10, color=DARK, bold=False):
    c.setFillColor(color)
    c.setFont("Helvetica-Bold" if bold else "Helvetica", size)
    c.drawString(x, y, text)


def main():
    OUT.parent.mkdir(exist_ok=True)
    c = canvas.Canvas(str(OUT), pagesize=A4)
    width, height = A4

    # True printable background watermark, drawn first.
    c.saveState()
    c.translate(width / 2, height / 2)
    c.rotate(33)
    c.setFillColor(WATERMARK)
    c.setFillAlpha(0.35)
    c.setFont("Helvetica-Bold", 42)
    c.drawCentredString(0, 0, "LIGHT WINTER TECHNOLOGIES")
    c.setFont("Helvetica-Bold", 24)
    c.drawCentredString(0, -34, "LWT RETAILOS")
    c.restoreState()
    c.setFillAlpha(1)

    left = 18 * mm
    right = width - 18 * mm
    top = height - 20 * mm

    if LOGO.exists():
        c.drawImage(str(LOGO), left, top - 36 * mm, width=28 * mm, height=28 * mm)

    draw_text(c, left + 4 * mm, top - 45 * mm, "LIGHT WINTER TECHNOLOGIES", 17, DARK, True)
    draw_text(c, left + 4 * mm, top - 53 * mm, "RetailOS Commercial Quotation", 10, BLUE)

    draw_text(c, width - 100 * mm, top - 22 * mm, "QUOTATION", 28, BLUE, True)
    draw_text(c, width - 100 * mm, top - 38 * mm, "Quote No: LWT-________", 10, DARK, True)
    draw_text(c, width - 100 * mm, top - 47 * mm, f"Date: {date.today().strftime('%d %B %Y')}", 10, DARK, True)
    draw_text(c, width - 100 * mm, top - 56 * mm, "Valid Until: __________________", 10, DARK, True)

    y = top - 92 * mm
    box_h = 32 * mm
    col_w = (right - left) / 2
    c.setFillColor(LIGHT_BLUE)
    c.rect(left, y, right - left, box_h, fill=1, stroke=0)
    c.setStrokeColor(LINE)
    c.rect(left, y, right - left, box_h, fill=0, stroke=1)
    c.line(left + col_w, y, left + col_w, y + box_h)

    draw_text(c, left + 3 * mm, y + 25 * mm, "Prepared For", 10)
    draw_text(c, left + 3 * mm, y + 17 * mm, "Anephen Investments", 10)
    draw_text(c, left + 3 * mm, y + 9 * mm, "Address: __________________________", 9)
    draw_text(c, left + 20 * mm, y + 2 * mm, "____________________________", 9)
    draw_text(c, left + 3 * mm, y - 5 * mm, "Contact: __________________________", 9)
    draw_text(c, left + 3 * mm, y - 12 * mm, "Phone/Email: ______________________", 9)

    draw_text(c, left + col_w + 3 * mm, y + 25 * mm, "Prepared By", 10)
    draw_text(c, left + col_w + 3 * mm, y + 17 * mm, "Light Winter Technologies", 10)
    draw_text(c, left + col_w + 3 * mm, y + 9 * mm, "Address: __________________________", 9)
    draw_text(c, left + col_w + 20 * mm, y + 2 * mm, "____________________________", 9)
    draw_text(c, left + col_w + 3 * mm, y - 5 * mm, "Contact: __________________________", 9)
    draw_text(c, left + col_w + 3 * mm, y - 12 * mm, "Phone/Email: ______________________", 9)

    y -= 22 * mm
    draw_text(c, left, y, "Items", 14, DARK, True)
    y -= 13 * mm

    table_w = right - left
    row_h = 12 * mm
    cols = [12 * mm, 82 * mm, 26 * mm, 35 * mm, table_w - (12 + 82 + 26 + 35) * mm]
    headers = ["#", "Description", "Qty", "Unit Price", "Total"]
    c.setFillColor(BLUE)
    c.rect(left, y, table_w, row_h, fill=1, stroke=0)
    x = left
    for i, header in enumerate(headers):
        c.setStrokeColor(LINE)
        c.rect(x, y, cols[i], row_h, fill=0, stroke=1)
        c.setFillColor(colors.white)
        c.setFont("Helvetica-Bold", 10)
        c.drawCentredString(x + cols[i] / 2, y + 4 * mm, header)
        x += cols[i]

    y -= row_h
    for idx in range(1, 6):
        x = left
        for col_i, col in enumerate(cols):
            c.setStrokeColor(LINE)
            c.rect(x, y, col, row_h, fill=0, stroke=1)
            if col_i == 0:
                draw_text(c, x + col / 2 - 2, y + 4 * mm, str(idx), 10)
            x += col
        y -= row_h

    label_w = table_w - 52 * mm
    val_w = 52 * mm
    for label in ["Subtotal", "Discount", "Tax / VAT", "Grand Total"]:
        if label == "Grand Total":
            c.setFillColor(LIGHT_BLUE)
            c.rect(left, y, table_w, row_h, fill=1, stroke=0)
        c.setStrokeColor(LINE)
        c.rect(left, y, label_w, row_h, fill=0, stroke=1)
        c.rect(left + label_w, y, val_w, row_h, fill=0, stroke=1)
        draw_text(c, left + label_w - 33 * mm, y + 4 * mm, label, 10, DARK, label == "Grand Total")
        y -= row_h

    y -= 13 * mm
    draw_text(c, left, y, "Notes", 13, DARK, True)
    y -= 18 * mm
    c.setStrokeColor(LINE)
    c.rect(left, y, table_w, 15 * mm, fill=0, stroke=1)
    c.setStrokeColor(colors.HexColor("#56606B"))
    c.line(left + 4 * mm, y + 10 * mm, right - 30 * mm, y + 10 * mm)
    c.line(left + 4 * mm, y + 5 * mm, right - 30 * mm, y + 5 * mm)

    y -= 18 * mm
    draw_text(c, left + 3 * mm, y, "Accepted By: __________________________", 10)
    draw_text(c, left + 3 * mm, y - 9 * mm, "Date: _________________________________", 10)
    draw_text(c, left + col_w + 3 * mm, y, "For Light Winter Technologies", 10)
    draw_text(c, left + col_w + 3 * mm, y - 9 * mm, "Signature: ____________________________", 10)

    c.setFillColor(colors.HexColor("#5B6776"))
    c.setFont("Helvetica", 8)
    c.drawCentredString(width / 2, 13 * mm, "Light Winter Technologies | Premium RetailOS Platform")
    c.save()
    print(OUT)


if __name__ == "__main__":
    main()

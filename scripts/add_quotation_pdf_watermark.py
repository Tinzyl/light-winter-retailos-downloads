from pathlib import Path
from tempfile import NamedTemporaryFile

from pypdf import PdfReader, PdfWriter
from reportlab.lib.colors import HexColor
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parents[1]
PDF = ROOT / "documents" / "Light Winter Technologies - Quotation - Anephen Investments - Address Fields.pdf"
OUT = ROOT / "documents" / "Light Winter Technologies - Quotation - Anephen Investments - Address Fields.pdf"


def main():
    reader = PdfReader(str(PDF))
    page = reader.pages[0]
    width = float(page.mediabox.width)
    height = float(page.mediabox.height)

    with NamedTemporaryFile(suffix=".pdf", delete=False) as temp:
        temp_path = Path(temp.name)

    c = canvas.Canvas(str(temp_path), pagesize=(width, height))
    c.saveState()
    c.translate(width / 2, height / 2)
    c.rotate(33)
    c.setFillColor(HexColor("#DDEAF5"))
    c.setFillAlpha(0.34)
    c.setFont("Helvetica-Bold", 44)
    c.drawCentredString(0, 0, "LIGHT WINTER TECHNOLOGIES")
    c.setFont("Helvetica-Bold", 26)
    c.drawCentredString(0, -38, "LWT RETAILOS")
    c.restoreState()
    c.save()

    watermark = PdfReader(str(temp_path)).pages[0]
    writer = PdfWriter()
    watermark.merge_page(page)
    writer.add_page(watermark)

    tmp_out = OUT.with_suffix(".tmp.pdf")
    with tmp_out.open("wb") as handle:
        writer.write(handle)
    tmp_out.replace(OUT)
    temp_path.unlink(missing_ok=True)
    print(OUT)


if __name__ == "__main__":
    main()

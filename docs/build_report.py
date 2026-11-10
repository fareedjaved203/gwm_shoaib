import copy
import re
import subprocess
from pathlib import Path

from docx import Document
from docx.enum.section import WD_ORIENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor
from PIL import Image

DOCS = Path(__file__).resolve().parent
ROOT = DOCS.parent
SQL = (ROOT / "sql" / "gwm_database.sql").read_text(encoding="utf-8")
REPORT = DOCS / "report.md"
OUT_DOCX = ROOT / "GWM_Database_Report.docx"

A4_W, A4_H = 8.27, 11.69
MARGIN_PORTRAIT = 1.0
MARGIN_LANDSCAPE = 0.8
PORTRAIT_WIDTH = A4_W - 2 * MARGIN_PORTRAIT
LANDSCAPE_WIDTH = A4_H - 2 * MARGIN_LANDSCAPE
LANDSCAPE_HEIGHT = A4_W - 2 * MARGIN_LANDSCAPE - 0.7

LANDSCAPE_BLOCKS = [
    ("Entity Relationship Diagram", "Normalisation Log"),
    ("SQL Queries and Output Views", "Security and Privacy Policy"),
]

COVER = [
    ("Global Waste Management", 28, True),
    ("Smart Waste Management System", 18, False),
    ("Database Design, Implementation and Business Intelligence (Oracle)", 13, False),
    ("", 12, False),
    ("Subject Name: [Subject Name]", 13, False),
    ("Subject Code: [Subject Code]", 13, False),
    ("Student Name: [Student Name]", 13, False),
    ("Student ID: [Student ID]", 13, False),
]


def section6_queries():
    body = SQL.split("SECTION 6 - DASHBOARD OUTPUT QUERIES")[1].split("SECTION 7 - INTEGRITY TESTS")[0]
    found = []
    for m in re.finditer(r"PROMPT === (\d+)\. (.*?) ===\n(.*?;)\n", body, re.S):
        view = re.search(r"FROM\s+(v_\w+)", m.group(3), re.I).group(1).lower()
        found.append((int(m.group(1)), m.group(2), view))
    return found


def view_sql(view):
    m = re.search(rf"CREATE OR REPLACE VIEW {view} AS\n(.*?;)\n", SQL, re.S | re.I)
    return f"CREATE OR REPLACE VIEW {view} AS\n{m.group(1)}"


def dashboards_md():
    out = []
    for n, title, view in section6_queries():
        out.append(f"## {n}. {title}\n")
        out.append(f"```sql\n{view_sql(view)}\n```\n")
        out.append(f"![Execution output: {title}](screenshots/dash_{n:02d}.png)\n")
    out.append("## Integrity test results\n")
    out.append("![Execution output: integrity tests, every invalid statement is rejected](screenshots/integrity_tests.png)\n")
    return "\n".join(out)


def replace_block(text, tag, content):
    pat = re.compile(rf"<!-- BEGIN {tag} -->.*?<!-- END {tag} -->", re.S)
    return pat.sub(lambda m: f"<!-- BEGIN {tag} -->\n{content}\n<!-- END {tag} -->", text)


def image_width(path, landscape):
    with Image.open(DOCS / path) as im:
        w, h = im.size
    if not landscape:
        return min(PORTRAIT_WIDTH, w / 130)
    limit_h = 5.6 if "erd_" in path else LANDSCAPE_HEIGHT
    return min(LANDSCAPE_WIDTH, w / 130 if "screenshots" in path else LANDSCAPE_WIDTH, limit_h * w / h)


FIGURE_WIDTHS = []


def resize_figures(doc):
    shapes = list(doc.inline_shapes)
    if len(shapes) != len(FIGURE_WIDTHS):
        raise RuntimeError(f"figure count mismatch: {len(shapes)} images, {len(FIGURE_WIDTHS)} widths")
    for shape, width in zip(shapes, FIGURE_WIDTHS):
        ratio = shape.height / shape.width
        shape.width = Inches(width)
        shape.height = int(Inches(width) * ratio)


def trim_whitespace(path, pad=30):
    with Image.open(path) as im:
        rgb = im.convert("RGB")
    grey = rgb.convert("L").point(lambda v: 255 if v < 245 else 0)
    box = grey.getbbox()
    if not box:
        return
    l, t, r, b = box
    box = (max(l - pad, 0), max(t - pad, 0), min(r + pad, rgb.width), min(b + pad, rgb.height))
    if box != (0, 0, rgb.width, rgb.height):
        rgb.crop(box).save(path)


def pandoc_input(text):
    lines = text.split("\n")
    landscape = False
    figure = 0
    out = []
    for line in lines:
        h1 = re.match(r"^#{1,2} (.*)$", line)
        if h1:
            title = h1.group(1).strip()
            for start, end in LANDSCAPE_BLOCKS:
                if title == start:
                    landscape = True
                elif title == end:
                    landscape = False
        m = re.match(r"^!\[(.*?)\]\((.*?)\)\s*$", line)
        if m:
            figure += 1
            caption = re.sub(r"^Figure \d+\.\s*", "", m.group(1))
            width = image_width(m.group(2), landscape)
            FIGURE_WIDTHS.append(width)
            line = f"![Figure {figure}. {caption}]({m.group(2)}){{width={width:.2f}in}}"
        if h1 and out and out[-1].strip():
            out.append("")
        out.append(line)
    return "\n".join(out)


def set_cell_shading(cell, colour):
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), colour)
    tc_pr.append(shd)


def style_tables(doc):
    for table in doc.tables:
        tbl_pr = table._tbl.tblPr
        borders = OxmlElement("w:tblBorders")
        for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
            el = OxmlElement(f"w:{edge}")
            el.set(qn("w:val"), "single")
            el.set(qn("w:sz"), "4")
            el.set(qn("w:space"), "0")
            el.set(qn("w:color"), "8C8C8C")
            borders.append(el)
        for old in tbl_pr.findall(qn("w:tblBorders")):
            tbl_pr.remove(old)
        tbl_pr.append(borders)
        for r, row in enumerate(table.rows):
            if r == 0:
                tr_pr = row._tr.get_or_add_trPr()
                hdr = OxmlElement("w:tblHeader")
                tr_pr.append(hdr)
            for cell in row.cells:
                if r == 0:
                    set_cell_shading(cell, "1F2A44")
                for p in cell.paragraphs:
                    p.paragraph_format.space_after = Pt(1)
                    p.paragraph_format.space_before = Pt(1)
                    for run in p.runs:
                        run.font.size = Pt(8.5)
                        if r == 0:
                            run.font.bold = True
                            run.font.color.rgb = RGBColor(0xFF, 0xFF, 0xFF)


def sect_pr(landscape, template):
    s = copy.deepcopy(template)
    for tag in ("w:headerReference", "w:footerReference", "w:titlePg"):
        for el in s.findall(qn(tag)):
            s.remove(el)
    pg_sz = s.find(qn("w:pgSz"))
    if pg_sz is None:
        pg_sz = OxmlElement("w:pgSz")
        s.append(pg_sz)
    pg_mar = s.find(qn("w:pgMar"))
    if pg_mar is None:
        pg_mar = OxmlElement("w:pgMar")
        s.append(pg_mar)
    w, h = (A4_H, A4_W) if landscape else (A4_W, A4_H)
    pg_sz.set(qn("w:w"), str(int(w * 1440)))
    pg_sz.set(qn("w:h"), str(int(h * 1440)))
    if landscape:
        pg_sz.set(qn("w:orient"), "landscape")
    elif pg_sz.get(qn("w:orient")):
        del pg_sz.attrib[qn("w:orient")]
    m = MARGIN_LANDSCAPE if landscape else MARGIN_PORTRAIT
    for side in ("w:top", "w:bottom", "w:left", "w:right"):
        pg_mar.set(qn(side), str(int(m * 1440)))
    for side, val in (("w:header", 708), ("w:footer", 708), ("w:gutter", 0)):
        pg_mar.set(qn(side), str(val))
    return s


def insert_section_break_before(paragraph, landscape_for_previous, template):
    p = OxmlElement("w:p")
    p_pr = OxmlElement("w:pPr")
    p_pr.append(sect_pr(landscape_for_previous, template))
    p.append(p_pr)
    paragraph._p.addprevious(p)


def add_page_number_footer(section):
    section.different_first_page_header_footer = True
    p = section.footer.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = p.add_run()
    for kind, text in (("begin", None), (None, "PAGE"), ("end", None)):
        if kind:
            fld = OxmlElement("w:fldChar")
            fld.set(qn("w:fldCharType"), kind)
            run._r.append(fld)
        else:
            instr = OxmlElement("w:instrText")
            instr.set(qn("xml:space"), "preserve")
            instr.text = text
            run._r.append(instr)


def build_cover(doc):
    body = doc.element.body
    first = body[0]
    paras = []
    spacer = OxmlElement("w:p")
    first.addprevious(spacer)
    for _ in range(6):
        sp = OxmlElement("w:p")
        first.addprevious(sp)
    for text, size, bold in COVER:
        p_el = OxmlElement("w:p")
        first.addprevious(p_el)
        paras.append(p_el)
    from docx.text.paragraph import Paragraph
    for p_el, (text, size, bold) in zip(paras, COVER):
        p = Paragraph(p_el, doc._body)
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_after = Pt(10)
        run = p.add_run(text)
        run.font.size = Pt(size)
        run.font.bold = bold
        if bold:
            run.font.color.rgb = RGBColor(0x1F, 0x2A, 0x44)
    brk = OxmlElement("w:p")
    first.addprevious(brk)
    Paragraph(brk, doc._body).add_run().add_break(WD_BREAK.PAGE)


def page_break_after_toc(doc):
    from docx.text.paragraph import Paragraph
    for el in doc.element.body:
        if el.tag == qn("w:sdt"):
            p = OxmlElement("w:p")
            el.addnext(p)
            Paragraph(p, doc._body).add_run().add_break(WD_BREAK.PAGE)
            return


def postprocess():
    doc = Document(OUT_DOCX)

    for name in ("Normal", "Body Text", "First Paragraph", "Compact"):
        if name in [s.name for s in doc.styles]:
            st = doc.styles[name]
            st.font.name = "Calibri"
            st.font.size = Pt(11)
    for name in ("Source Code",):
        if name in [s.name for s in doc.styles]:
            doc.styles[name].font.size = Pt(8.5)

    build_cover(doc)
    page_break_after_toc(doc)
    resize_figures(doc)
    style_tables(doc)

    template = doc.sections[-1]._sectPr
    headings = {p.text.strip(): p for p in doc.paragraphs if p.style.name.startswith("Heading")}
    break_titles = set()
    for start, end in LANDSCAPE_BLOCKS:
        insert_section_break_before(headings[start], False, template)
        insert_section_break_before(headings[end], True, template)
        break_titles.update((start, end))

    last = doc.sections[-1]
    last.orientation = WD_ORIENT.PORTRAIT
    last.page_width, last.page_height = Inches(A4_W), Inches(A4_H)
    for side in ("top_margin", "bottom_margin", "left_margin", "right_margin"):
        setattr(last, side, Inches(MARGIN_PORTRAIT))

    in_dashboards = False
    for p in doc.paragraphs:
        text = p.text.strip()
        if p.style.name == "Heading 1":
            in_dashboards = text == "SQL Queries and Output Views"
            if text not in break_titles and text != "Introduction":
                p.paragraph_format.page_break_before = True
        elif p.style.name == "Heading 2" and in_dashboards and text != "1. Executive KPIs":
            p.paragraph_format.page_break_before = True

    add_page_number_footer(doc.sections[0])

    doc.save(OUT_DOCX)


def finalise_in_word():
    ps = f"""
$ErrorActionPreference = 'Stop'
$w = New-Object -ComObject Word.Application
$w.Visible = $false
$w.DisplayAlerts = 0
try {{
    $d = $w.Documents.Open('{OUT_DOCX}')
    foreach ($t in $d.TablesOfContents) {{ $t.Update() }}
    $d.Fields.Update() | Out-Null
    foreach ($t in $d.TablesOfContents) {{ $t.Update() }}
    $d.Save()
    $d.ExportAsFixedFormat('{OUT_DOCX.with_suffix(".pdf")}', 17)
    Write-Output "word: fields updated, saved, pdf exported"
    try {{ $d.Close(0) }} catch {{ }}
}} finally {{
    try {{ $w.Quit() }} catch {{ }}
}}
"""
    res = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True)
    print(res.stdout.strip(), res.stderr.strip())


def word_count():
    doc = Document(OUT_DOCX)
    count = 0
    started = False
    for p in doc.paragraphs:
        text = p.text.strip()
        style = p.style.name
        if style == "Heading 1" and text == "Introduction":
            started = True
        if style == "Heading 1" and text == "References":
            break
        if not started or not text:
            continue
        if style in ("Source Code", "Image Caption", "Captioned Figure") or style.startswith("Heading"):
            continue
        count += len(text.split())
    return count


def main():
    subprocess.run(["python", str(DOCS / "build_docs.py")], check=True)
    text = REPORT.read_text(encoding="utf-8")
    text = replace_block(text, "DASHBOARDS", dashboards_md())
    REPORT.write_text(text, encoding="utf-8")

    for png in list(DOCS.glob("erd_*.png")) + list((DOCS / "screenshots").glob("*.png")):
        trim_whitespace(png)

    tmp = DOCS / "_pandoc_input.md"
    tmp.write_text(pandoc_input(text), encoding="utf-8")
    subprocess.run(["pandoc", str(tmp), "-f", "markdown", "-t", "docx", "-o", str(OUT_DOCX),
                    "--toc", "--toc-depth=2", "--resource-path", str(DOCS),
                    "--metadata", "toc-title=Table of Contents"], check=True)
    tmp.unlink()
    postprocess()
    finalise_in_word()
    doc = Document(OUT_DOCX)
    print("docx:", OUT_DOCX.name, "sections:", len(doc.sections), "tables:", len(doc.tables),
          "images:", len(doc.inline_shapes), "body words:", word_count())


if __name__ == "__main__":
    main()

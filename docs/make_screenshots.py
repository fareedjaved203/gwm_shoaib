import re
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SQL = (ROOT / "sql" / "gwm_database.sql").read_text(encoding="utf-8")
OUTPUT = (ROOT / "docs" / "sqlplus_output.txt").read_text(encoding="utf-8", errors="replace")
SHOTS = ROOT / "docs" / "screenshots"
SHOTS.mkdir(exist_ok=True)

FONT = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 20)
BOLD = ImageFont.truetype("C:/Windows/Fonts/consolab.ttf", 20)
CHAR_W = FONT.getlength("M")
LINE_H = 28
PAD = 22


def section6_queries():
    body = SQL.split("SECTION 6 - DASHBOARD OUTPUT QUERIES")[1].split("SECTION 7 - INTEGRITY TESTS")[0]
    queries = {}
    for m in re.finditer(r"PROMPT === (\d+)\. (.*?) ===\n(.*?;)\n", body, re.S):
        queries[int(m.group(1))] = (m.group(2), m.group(3))
    return queries


def output_blocks():
    blocks = {}
    parts = re.split(r"^=== (\d+)\. (.*?) ===\s*$", OUTPUT, flags=re.M)
    for i in range(1, len(parts), 3):
        text = re.split(r"^PASS ", parts[i + 2], flags=re.M)[0]
        blocks[int(parts[i])] = text
    return blocks


def clean(lines):
    out = []
    for line in lines:
        out.append(line.expandtabs(8).rstrip())
    while out and not out[0]:
        out.pop(0)
    while out and not out[-1]:
        out.pop()
    return out


def render(path, title, lines):
    width_chars = max(len(l) for l in lines)
    width = int(width_chars * CHAR_W) + PAD * 2
    bar = 44
    height = bar + len(lines) * LINE_H + PAD * 2
    img = Image.new("RGB", (max(width, 900), height), "white")
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, img.width, bar], fill="#1f2a44")
    d.text((PAD, 10), title, font=BOLD, fill="white")
    y = bar + PAD
    for l in lines:
        colour = "black"
        if l.startswith("SQL>"):
            colour = "#0b3d91"
        if l.startswith("PASS"):
            colour = "#0a6b2a"
        if l.startswith("FAIL"):
            colour = "#b00020"
        d.text((PAD, y), l, font=FONT, fill=colour)
        y += LINE_H
    img.save(path)


def main():
    queries = section6_queries()
    blocks = output_blocks()
    for n, (title, sql) in queries.items():
        sql_lines = sql.strip().splitlines()
        lines = []
        for i, l in enumerate(sql_lines):
            lines.append(("SQL> " if i == 0 else f"{i + 1:>3}  ") + l.strip())
        lines.append("")
        lines.extend(clean(blocks[n].splitlines()))
        render(SHOTS / f"dash_{n:02d}.png", f"GWM_OWNER  |  {n}. {title}", lines)

    tests = OUTPUT[OUTPUT.index("PASS "):]
    tl = clean(tests.splitlines())
    tl = [l for l in tl if l.startswith(("PASS", "FAIL", "Passed", "-----"))]
    render(SHOTS / "integrity_tests.png", "GWM_OWNER  |  Integrity tests (every statement must be rejected)", tl)
    print("screenshots:", len(list(SHOTS.glob("*.png"))))


if __name__ == "__main__":
    main()

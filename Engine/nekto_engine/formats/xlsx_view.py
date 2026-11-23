"""Вид книги Excel для редактора (layout.py) — из уже обезличенных листов.

Каждый лист — таблица с номерами строк Excel слева: «строка 37» в редакторе — та же строка 37 в файле.
Даты показываются датами, а не номером дня; скрытые листы показываются с пометкой — в Excel их не видно,
но они уходят вместе с файлом. Примечания к ячейкам — под листом, с адресом ячейки и автором.
"""
from __future__ import annotations

import posixpath
import re

from lxml import etree

from . import layout as L
from . import ooxml
from .docx_view import properties
from .layout import Block

S = "{%s}" % ooxml.NS["s"]
_R = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
_REL = "{http://schemas.openxmlformats.org/package/2006/relationships}"
MAX_COLUMNS = 100


def build(sheets: dict, shared_text: list[str], dates, comments: dict[str, etree._Element],
          persons: dict[str, etree._Element], core: etree._Element | None, raw: dict[str, bytes]) -> list[Block]:
    from .xlsx import _cells, _number_text

    states = _sheet_states(raw)
    people = {p.get("id"): p.get("displayName", "") for root in persons.values() for p in root if p.get("id")}
    blocks: list[Block] = []
    for name, sh in sheets.items():
        grid: dict[int, dict[int, str]] = {}
        for c, row, col in _cells(sh.root):
            text = _display(c, shared_text, dates, _number_text)
            if text:
                grid.setdefault(row, {})[col] = text
        inner: list[Block | None] = []
        if grid:
            numbers = sorted(grid)
            cols = sorted({c for r in grid.values() for c in r})
            first, last = cols[0], min(cols[-1], cols[0] + MAX_COLUMNS - 1)
            rows = [[grid[r].get(c, "") for c in range(first, last + 1)] for r in numbers]
            inner.append(L.table(rows, header=sh.header_row is not None and sh.header_row == numbers[0],
                                 row_labels=[str(r) for r in numbers]))
            if cols[-1] > last:
                inner.append(L.note(f"Показаны первые {MAX_COLUMNS} столбцов, остальные — в файле."))
        notes = _comment_rows(name, comments, people, raw)
        if notes:
            inner.append(L.section("aside", "Примечания к ячейкам", [L.fields(notes)], copy=False))
        if not any(inner):
            continue
        title = sh.name + (" · скрытый лист" if states.get(sh.name) in ("hidden", "veryHidden") else "")
        blocks.append(L.section("sheet", title, inner))
    blocks.append(properties(core))
    return L.compact(blocks)


def _display(c: etree._Element, shared_text: list[str], dates, number_text) -> str:
    t = c.get("t")
    if t == "s":
        v = c.find(S + "v")
        if v is not None and (v.text or "").isdigit() and int(v.text) < len(shared_text):
            return shared_text[int(v.text)]
        return ""
    if t == "inlineStr":
        is_ = c.find(S + "is")
        return "".join(x.text or "" for x in is_.iter(S + "t")) if is_ is not None else ""
    v = c.find(S + "v")
    if v is None or not v.text:
        return ""
    if t == "b":
        return "ИСТИНА" if v.text == "1" else "ЛОЖЬ"
    if t in ("e", "str"):
        return v.text
    return dates.text(c, v.text) or number_text(v.text)


def _sheet_states(raw: dict[str, bytes]) -> dict[str, str]:
    if "xl/workbook.xml" not in raw:
        return {}
    wb = ooxml.parse(raw["xl/workbook.xml"])
    return {s.get("name", ""): s.get("state", "visible") for s in wb.iter(S + "sheet")}


def _comment_rows(sheet_part: str, comments: dict[str, etree._Element], people: dict[str, str],
                  raw: dict[str, bytes]) -> list[tuple[str, str]]:
    """Примечания листа: новые цепочки (threadedComments), если есть, иначе старые примечания — Excel пишет оба вида
    для одних и тех же ячеек, показывать их дважды незачем."""
    folder, file = posixpath.split(sheet_part)
    rels = raw.get(f"{folder}/_rels/{file}.rels")
    targets = []
    if rels:
        for rel in ooxml.parse(rels).iter(_REL + "Relationship"):
            target = rel.get("Target", "")
            targets.append(target.lstrip("/") if target.startswith("/") else posixpath.normpath(posixpath.join(folder, target)))
    threaded = [comments[t] for t in targets if "threadedComments" in t and t in comments]
    rows: list[tuple[str, str]] = []
    if threaded:
        for root in threaded:
            for cm in root:
                if not isinstance(cm.tag, str) or not cm.tag.endswith("}threadedComment"):
                    continue
                text = "".join(t.text or "" for t in cm if isinstance(t.tag, str) and t.tag.endswith("}text"))
                if text.strip():
                    rows.append((_label(cm.get("ref", ""), people.get(cm.get("personId", ""), "")), text.strip()))
        return rows
    for t in targets:
        root = comments.get(t)
        if root is None or "threadedComments" in t:
            continue
        authors = [a.text or "" for a in root.iter(S + "author")]
        for cm in root.iter(S + "comment"):
            text = "".join(x.text or "" for x in cm.iter(S + "t")).strip()
            aid = cm.get("authorId", "")
            author = authors[int(aid)] if aid.isdigit() and int(aid) < len(authors) else ""
            if text:
                rows.append((_label(cm.get("ref", ""), author), re.sub(r"^\s*\[Threaded comment\].*?\n", "", text)))
    return rows


def _label(ref: str, author: str) -> str:
    return f"{ref} · {author}" if author.strip() else ref

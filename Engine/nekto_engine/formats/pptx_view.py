"""Вид презентации для редактора (layout.py) — из уже обезличенных частей архива.

Слайд — карточка в порядке показа (`presentation.xml`, а не номера файлов): заголовок слайда, текст фигур сверху
вниз и слева направо, маркированные пункты с уровнями, таблицы. Внутри слайда — его заметки докладчика
и комментарии: на экране показа их не видно, а уходят они вместе с файлом.
"""
from __future__ import annotations

import posixpath
import re

from lxml import etree

from . import layout as L
from . import ooxml
from .docx_view import properties
from .layout import Block

A = "{%s}" % ooxml.NS["a"]
P = "{%s}" % ooxml.NS["p"]
_R = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
_REL = "{http://schemas.openxmlformats.org/package/2006/relationships}"


def build(parts: dict[str, etree._Element], raw: dict[str, bytes]) -> list[Block]:
    """`parts` — обезличенные корни (слайды, заметки, комментарии, авторы, свойства), `raw` — связи и presentation.xml."""
    order = _slide_order(raw)
    if not order:
        order = sorted((n for n in parts if re.match(r"ppt/slides/slide\d+\.xml$", n)), key=_number)
    authors = _authors(parts)
    blocks: list[Block] = []
    for no, name in enumerate(order, 1):
        root = parts.get(name)
        if root is None:
            continue
        rels = _rels(raw, name)
        inner = _slide_blocks(root)
        notes = next((parts[t] for t in rels if "notesSlide" in t and t in parts), None)
        if notes is not None:
            inner.append(L.section("aside", "Заметки докладчика", _notes_blocks(notes)))
        comments = [c for t in rels if "/comments/" in t and t in parts for c in _comment_rows(parts[t], authors)]
        if comments:
            inner.append(L.section("aside", "Комментарии", [L.fields(comments)], copy=False))
        blocks.append(L.section("slide", f"Слайд {no}", inner or [L.paragraph("Без текста", "muted")]))
    blocks.append(properties(parts.get("docProps/core.xml")))
    return L.compact(blocks)


def _number(name: str) -> int:
    m = re.search(r"(\d+)\.xml$", name)
    return int(m.group(1)) if m else 0


def _slide_order(raw: dict[str, bytes]) -> list[str]:
    if "ppt/presentation.xml" not in raw:
        return []
    pres = ooxml.parse(raw["ppt/presentation.xml"])
    targets = _rels(raw, "ppt/presentation.xml", with_ids=True)
    return [targets[sid.get(_R + "id")] for sid in pres.iter(P + "sldId") if sid.get(_R + "id") in targets]


def _rels(raw: dict[str, bytes], part: str, with_ids: bool = False):
    """Связи части: полные пути целей (`ppt/notesSlides/notesSlide3.xml`)."""
    folder, file = posixpath.split(part)
    data = raw.get(f"{folder}/_rels/{file}.rels")
    if not data:
        return {} if with_ids else []
    out = {}
    for rel in ooxml.parse(data).iter(_REL + "Relationship"):
        if rel.get("TargetMode") == "External":
            continue
        target = rel.get("Target", "")
        path = target.lstrip("/") if target.startswith("/") else posixpath.normpath(posixpath.join(folder, target))
        out[rel.get("Id")] = path
    return out if with_ids else list(out.values())


def _slide_blocks(root: etree._Element) -> list[Block]:
    tree = root.find(f"{P}cSld/{P}spTree")
    return [b for shape in _shapes(tree) for b in _shape_blocks(shape)] if tree is not None else []


def _shapes(tree: etree._Element) -> list[etree._Element]:
    """Фигуры с текстом и таблицы в порядке чтения: сверху вниз, слева направо; группы раскрываются."""
    found: list[tuple[tuple[int, int, int], etree._Element]] = []

    def walk(node: etree._Element) -> None:
        for el in node:
            if el.tag == P + "grpSp":
                walk(el)
            elif el.tag in (P + "sp", P + "graphicFrame"):
                found.append((_position(el, len(found)), el))

    walk(tree)
    return [el for _pos, el in sorted(found, key=lambda x: x[0])]


def _position(el: etree._Element, index: int) -> tuple[int, int, int]:
    off = next(el.iter(A + "off"), None)
    if off is None:
        off = next(el.iter(P + "off"), None)
    if off is None:  # фигура без своих координат берёт их из макета: оставляем порядок документа, но заголовок — первым
        return (-1 if _placeholder(el) in ("title", "ctrTitle") else 1 << 40, 0, index)
    # близкие по высоте фигуры (разница < 1/4 дюйма) — одна строка, читаются слева направо
    return (int(off.get("y", "0")) // 228600, int(off.get("x", "0")), index)


def _placeholder(el: etree._Element) -> str | None:
    ph = next(el.iter(P + "ph"), None)
    if ph is None:
        return None
    return ph.get("type", "body")


def _shape_blocks(el: etree._Element) -> list[Block]:
    tbl = next(el.iter(A + "tbl"), None)
    if tbl is not None:
        t = _table(tbl)
        return [t] if t else []
    body = el.find(P + "txBody")
    if body is None:
        return []
    kind = _placeholder(el)
    if kind in ("sldNum", "dt", "ftr", "hdr"):
        texts = [_text(p) for p in body.iter(A + "p")]
        return [L.paragraph(" ".join(t for t in texts if t.strip()), "muted")] if any(t.strip() for t in texts) else []
    if kind in ("title", "ctrTitle"):
        text = " ".join(_text(p).strip() for p in body.iter(A + "p") if _text(p).strip())
        return [L.heading(text, 2)] if text else []
    bulleted_default = kind in ("body", "obj")
    out: list[Block] = []
    counters: dict[int, int] = {}
    for p in body.iter(A + "p"):
        text = _text(p)
        if not text.strip():
            continue
        ppr = p.find(A + "pPr")
        level = int(ppr.get("lvl", "0")) if ppr is not None and ppr.get("lvl", "0").isdigit() else 0
        if ppr is not None and ppr.find(A + "buNone") is not None:
            out.append(L.paragraph(text.strip()))
        elif ppr is not None and (auto := ppr.find(A + "buAutoNum")) is not None:
            counters[level] = counters.get(level, int(auto.get("startAt", "1")) - 1) + 1
            out.append(L.item(text.strip(), _auto_marker(counters[level], auto.get("type", "arabicPeriod")), level))
        elif ppr is not None and (ch := ppr.find(A + "buChar")) is not None:
            out.append(L.item(text.strip(), "•" if ch.get("char", "•") in "•▪◦-–·" else ch.get("char", "•"), level))
        elif bulleted_default and (len(list(body.iter(A + "p"))) > 1 or level > 0):
            out.append(L.item(text.strip(), "•", level))
        else:
            out.append(L.paragraph(text.strip()))
    return out


def _auto_marker(n: int, kind: str) -> str:
    if kind.startswith("alphaLc"):
        s = chr(96 + (n - 1) % 26 + 1)
    elif kind.startswith("alphaUc"):
        s = chr(64 + (n - 1) % 26 + 1)
    else:
        s = str(n)
    return s + (")" if kind.endswith("ParenR") or kind.endswith("ParenBoth") else ".")


def _text(p: etree._Element) -> str:
    out = []
    for el in p.iter(A + "t", A + "br"):
        out.append("\n" if el.tag == A + "br" else el.text or "")
    return "".join(out)


def _table(tbl: etree._Element) -> Block | None:
    rows = []
    for tr in tbl.iter(A + "tr"):
        row = []
        for tc in tr.iter(A + "tc"):
            if tc.get("hMerge") == "1" or tc.get("vMerge") == "1":
                row.append("")
                continue
            text = "\n".join(_text(p).strip() for p in tc.iter(A + "p") if _text(p).strip())
            span = int(tc.get("gridSpan", "1")) if tc.get("gridSpan", "1").isdigit() else 1
            row.append({"text": text, "span": span} if span > 1 else text)
        rows.append(row)
    if not rows:
        return None
    first_row_header = tbl.find(A + "tblPr") is not None and tbl.find(A + "tblPr").get("firstRow") == "1"
    return L.table(rows, header=first_row_header or L.looks_like_header(rows))


def _notes_blocks(root: etree._Element) -> list[Block]:
    out: list[Block] = []
    tree = root.find(f"{P}cSld/{P}spTree")
    for sp in (tree.iter(P + "sp") if tree is not None else []):
        if _placeholder(sp) != "body":
            continue
        for p in sp.iter(A + "p"):
            if _text(p).strip():
                out.append(L.paragraph(_text(p).strip()))
    return out


def _authors(parts: dict[str, etree._Element]) -> dict[str, str]:
    out: dict[str, str] = {}
    for name in ("ppt/commentAuthors.xml", "ppt/authors.xml"):
        root = parts.get(name)
        if root is None:
            continue
        for el in root.iter():
            if el.get("name") and el.get("id") is not None:
                out[el.get("id")] = el.get("name")
    return out


def _comment_rows(root: etree._Element, authors: dict[str, str]) -> list[tuple[str, str]]:
    rows = []
    for cm in root:
        if not isinstance(cm.tag, str) or not cm.tag.endswith("}cm"):
            continue
        text = " ".join(t.text for t in cm.iter() if isinstance(t.tag, str) and t.tag.endswith(("}text", "}t")) and t.text)
        if text.strip():
            rows.append((authors.get(cm.get("authorId", ""), "Комментарий"), text.strip()))
    return rows

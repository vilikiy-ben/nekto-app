"""Вид документа Word для редактора (layout.py) — из уже обезличенных частей архива.

Тело идёт в порядке документа: абзацы, заголовки (по стилю или уровню структуры), списки с настоящей нумерацией,
таблицы с объединёнными ячейками. Дальше — то, что Word не показывает на странице, но что уходит вместе с файлом
и тоже обезличено: колонтитулы, сноски, примечания с авторами, удалённый при рецензировании текст, свойства файла.
"""
from __future__ import annotations

import re
from typing import Iterator

from lxml import etree

from . import layout as L
from . import ooxml
from .layout import Block

W = "{%s}" % ooxml.NS["w"]
_MC_FALLBACK = "{http://schemas.openxmlformats.org/markup-compatibility/2006}Fallback"


def build(parts: dict[str, etree._Element], styles: bytes | None, numbering: bytes | None) -> list[Block]:
    """`parts` — обезличенные корни частей: word/document.xml, header*.xml, footer*.xml, footnotes, endnotes, comments,
    docProps/core.xml."""
    ctx = _Context(styles, numbering)
    blocks: list[Block] = []
    doc = parts.get("word/document.xml")
    if doc is not None:
        body = doc.find(W + "body")
        if body is not None:
            blocks += list(_flow(body, ctx))
    blocks.append(_aside("Колонтитулы", [p for n, root in sorted(parts.items()) if re.match(r"word/(header|footer)\d*\.xml$", n)
                                         for p in _flow(root, ctx)], dedupe=True, copy=False))
    blocks.append(_notes(parts, ctx))
    blocks.append(_comments(parts.get("word/comments.xml"), ctx))
    if doc is not None:
        deleted = [_squash("".join(t.text or "" for t in p.iter(W + "delText"))) for p in doc.iter(W + "p")]
        blocks.append(L.section("aside", "Удалённый текст (исправления)", [L.paragraph(t, "muted") for t in deleted if t],
                                copy=False))
    blocks.append(properties(parts.get("docProps/core.xml")))
    return L.compact(blocks)


def properties(core: etree._Element | None) -> Block | None:
    """Свойства файла: автор и «кем изменён» — частая утечка ФИО (ooxml.clean_core_properties)."""
    if core is None:
        return None
    names = [("dc:creator", "Автор"), ("cp:lastModifiedBy", "Изменил"), ("dc:title", "Название"), ("dc:subject", "Тема"),
             ("cp:keywords", "Ключевые слова"), ("dc:description", "Описание")]
    rows = []
    for tag, label in names:
        el = core.find(tag, ooxml.NS)
        if el is not None and el.text and el.text.strip():
            rows.append((label, el.text.strip()))
    return L.section("meta", "Свойства файла", [L.fields(rows)])


# MARK: Поток абзацев и таблиц

class _Context:
    def __init__(self, styles: bytes | None, numbering: bytes | None) -> None:
        self.headings: dict[str, int] = {}       # id стиля → уровень заголовка
        self.style_lists: dict[str, tuple[str, int]] = {}
        self.formats: dict[tuple[str, int], tuple[str, str, int]] = {}   # (numId, уровень) → (формат, шаблон, начало)
        self.counters: dict[str, list[int]] = {}
        if styles:
            self._read_styles(ooxml.parse(styles))
        if numbering:
            self._read_numbering(ooxml.parse(numbering))

    def _read_styles(self, root: etree._Element) -> None:
        for st in root.iter(W + "style"):
            sid = st.get(W + "styleId") or ""
            name_el = st.find(W + "name")
            name = (name_el.get(W + "val") if name_el is not None else "") or ""
            low = name.lower()
            level = None
            if m := re.match(r"(heading|заголовок)\s*(\d)", low):
                level = int(m.group(2))
            elif low in ("title", "название", "заголовок"):
                level = 1
            elif low in ("subtitle", "подзаголовок"):
                level = 2
            ppr = st.find(W + "pPr")
            if level is None and ppr is not None and (ol := ppr.find(W + "outlineLvl")) is not None:
                v = ol.get(W + "val", "9")
                level = int(v) + 1 if v.isdigit() and int(v) < 9 else None
            if level:
                self.headings[sid] = level
            if ppr is not None and (num := ppr.find(W + "numPr")) is not None:
                nid = num.find(W + "numId")
                if nid is not None:
                    ilvl = num.find(W + "ilvl")
                    self.style_lists[sid] = (nid.get(W + "val", ""), int(ilvl.get(W + "val", "0")) if ilvl is not None else 0)

    def _read_numbering(self, root: etree._Element) -> None:
        abstract: dict[str, dict[int, tuple[str, str, int]]] = {}
        for an in root.iter(W + "abstractNum"):
            levels = {}
            for lvl in an.iter(W + "lvl"):
                fmt = lvl.find(W + "numFmt")
                text = lvl.find(W + "lvlText")
                start = lvl.find(W + "start")
                levels[int(lvl.get(W + "ilvl", "0"))] = (
                    fmt.get(W + "val", "decimal") if fmt is not None else "decimal",
                    text.get(W + "val", "%1.") if text is not None else "%1.",
                    int(start.get(W + "val", "1")) if start is not None and start.get(W + "val", "1").isdigit() else 1)
            abstract[an.get(W + "abstractNumId", "")] = levels
        for num in root.iter(W + "num"):
            ref = num.find(W + "abstractNumId")
            levels = abstract.get(ref.get(W + "val", "") if ref is not None else "", {})
            for lvl, spec in levels.items():
                self.formats[(num.get(W + "numId", ""), lvl)] = spec

    def marker(self, num_id: str, level: int) -> str:
        fmt, template, start = self.formats.get((num_id, level), ("bullet", "•", 1))
        if fmt in ("bullet", "none"):
            return "•" if fmt == "bullet" or not template.strip() else template
        counters = self.counters.setdefault(num_id, [])
        while len(counters) <= level:
            counters.append(0)
        del counters[level + 1:]
        counters[level] += 1

        def value(lvl: int) -> str:
            f, _t, s = self.formats.get((num_id, lvl), ("decimal", "", 1))
            n = (counters[lvl] if lvl < len(counters) else 1) + s - 1
            return _format_number(n, f)

        return re.sub(r"%(\d)", lambda m: value(int(m.group(1)) - 1), template) or "•"


def _format_number(n: int, fmt: str) -> str:
    if fmt in ("lowerLetter", "upperLetter"):
        s = ""
        while n > 0:
            n, r = divmod(n - 1, 26)
            s = chr(97 + r) + s
        return s.upper() if fmt == "upperLetter" else s
    if fmt in ("lowerRoman", "upperRoman"):
        vals = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
                (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        s = ""
        for v, r in vals:
            while n >= v:
                s, n = s + r, n - v
        return s.upper() if fmt == "upperRoman" else s
    if fmt == "russianLower":
        return "абвгдежзиклмнопрстуфхцчшщэюя"[(n - 1) % 28]
    if fmt == "russianUpper":
        return "АБВГДЕЖЗИКЛМНОПРСТУФХЦЧШЩЭЮЯ"[(n - 1) % 28]
    return str(n)


def _flow(container: etree._Element, ctx: _Context) -> Iterator[Block]:
    for el in container:
        tag = etree.QName(el).localname if isinstance(el.tag, str) else ""
        if tag == "p":
            yield from _paragraph(el, ctx)
        elif tag == "tbl":
            t = _table(el, ctx)
            if t:
                yield t
        elif tag in ("sdt", "customXml", "smartTag", "ins"):
            inner = el.find(W + "sdtContent") if tag == "sdt" else el
            if inner is not None:
                yield from _flow(inner, ctx)
        elif tag in ("hdr", "ftr", "footnote", "endnote", "comment", "txbxContent"):
            yield from _flow(el, ctx)


def _paragraph(p: etree._Element, ctx: _Context) -> Iterator[Block]:
    text = _text(p)
    ppr = p.find(W + "pPr")
    style = ""
    if ppr is not None and (ps := ppr.find(W + "pStyle")) is not None:
        style = ps.get(W + "val", "")
    if text.strip():
        level = ctx.headings.get(style)
        if ppr is not None and (ol := ppr.find(W + "outlineLvl")) is not None and (v := ol.get(W + "val", "9")).isdigit():
            level = int(v) + 1 if int(v) < 9 else level
        num = ppr.find(W + "numPr") if ppr is not None else None
        list_ref = None
        if num is not None and (nid := num.find(W + "numId")) is not None and nid.get(W + "val", "0") != "0":
            ilvl = num.find(W + "ilvl")
            list_ref = (nid.get(W + "val", ""), int(ilvl.get(W + "val", "0")) if ilvl is not None else 0)
        elif style in ctx.style_lists:
            list_ref = ctx.style_lists[style]
        if level and not list_ref:
            yield L.heading(text.strip(), level)
        elif list_ref:
            yield L.item(text.strip(), ctx.marker(*list_ref), list_ref[1])
        else:
            yield L.paragraph(text.rstrip())
    # надписи (текстовые поля) внутри абзаца — после него, отдельными абзацами
    for box in p.iter(W + "txbxContent"):
        if _owner(box) is p and not _in_fallback(box):
            yield from _flow(box, ctx)


def _text(p: etree._Element) -> str:
    """Видимый текст абзаца: без удалённого при рецензировании, без вложенных надписей, табуляции и переносы — как есть."""
    out: list[str] = []
    for el in p.iter(W + "t", W + "tab", W + "br", W + "cr", W + "noBreakHyphen"):
        if _owner(el) is not p or _in_fallback(el):
            continue
        name = etree.QName(el).localname
        if name == "t":
            out.append(el.text or "")
        elif name == "tab":
            out.append("\t")
        elif name == "noBreakHyphen":
            out.append("‑")
        else:
            out.append("\n")
    return "".join(out)


def _owner(el: etree._Element) -> etree._Element | None:
    return next(el.iterancestors(W + "p"), None)


def _in_fallback(el: etree._Element) -> bool:
    return any(a.tag == _MC_FALLBACK for a in el.iterancestors())


def _table(tbl: etree._Element, ctx: _Context) -> Block | None:
    rows: list[list] = []
    explicit_header = False
    for i, tr in enumerate(r for r in tbl if r.tag == W + "tr"):
        trpr = tr.find(W + "trPr")
        if i == 0 and trpr is not None and trpr.find(W + "tblHeader") is not None:
            explicit_header = True
        row: list = []
        for tc in (c for c in tr if c.tag == W + "tc"):
            tcpr = tc.find(W + "tcPr")
            span = 1
            merged = False
            if tcpr is not None:
                gs = tcpr.find(W + "gridSpan")
                if gs is not None and gs.get(W + "val", "1").isdigit():
                    span = max(1, int(gs.get(W + "val", "1")))
                vm = tcpr.find(W + "vMerge")
                merged = vm is not None and vm.get(W + "val", "continue") == "continue"
            text = "" if merged else _cell_text(tc, ctx)
            row.append({"text": text, "span": span} if span > 1 else text)
        rows.append(row)
    if not rows:
        return None
    return L.table(rows, header=explicit_header or L.looks_like_header(rows))


def _cell_text(tc: etree._Element, ctx: _Context) -> str:
    """Текст ячейки: абзацы через перевод строки; вложенная таблица — строками через « · »."""
    parts: list[str] = []
    for el in tc:
        if el.tag == W + "p":
            parts.append(_text(el).strip())
        elif el.tag == W + "tbl":
            nested = _table(el, ctx)
            if nested:
                parts += [" · ".join(L.cell_text(c) for c in r if L.cell_text(c)) for r in nested["rows"]]
        elif el.tag == W + "sdt" and (inner := el.find(W + "sdtContent")) is not None:
            parts += [_text(p).strip() for p in inner.iter(W + "p")]
    return "\n".join(p for p in parts if p)


# MARK: Служебные части

def _aside(title: str, blocks: list[Block], dedupe: bool = False, copy: bool = True) -> Block | None:
    if dedupe:  # один колонтитул на всех страницах лежит в нескольких частях (первая, чётные, нечётные)
        seen, unique = set(), []
        for b in blocks:
            key = repr(b)
            if key not in seen:
                seen.add(key)
                unique.append(b)
        blocks = unique
    return L.section("aside", title, blocks, copy)


def _notes(parts: dict[str, etree._Element], ctx: _Context) -> Block | None:
    out: list[Block] = []
    for name, tag in (("word/footnotes.xml", "footnote"), ("word/endnotes.xml", "endnote")):
        root = parts.get(name)
        if root is None:
            continue
        for note in root.iter(W + tag):
            if note.get(W + "type") in ("separator", "continuationSeparator", "continuationNotice"):
                continue
            text = " ".join(_text(p).strip() for p in note.iter(W + "p") if _text(p).strip())
            if text:
                out.append(L.item(text, note.get(W + "id", "•")))
    return L.section("aside", "Сноски", out)


def _comments(root: etree._Element | None, ctx: _Context) -> Block | None:
    if root is None:
        return None
    rows = []
    for cm in root.iter(W + "comment"):
        text = "\n".join(_text(p).strip() for p in cm.iter(W + "p") if _text(p).strip())
        if text:
            rows.append((cm.get(W + "author") or "Без автора", text))
    return L.section("aside", "Примечания", [L.fields(rows)], copy=False)


def _squash(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip()

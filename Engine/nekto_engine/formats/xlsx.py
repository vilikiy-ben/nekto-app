"""Excel (.xlsx, .xlsm): ячейки всех листов, примечания и их авторы, метаданные.

Строки в xlsx обычно лежат в общем словаре sharedStrings, а ячейки ссылаются на них
по индексу — решаем судьбу каждой строки словаря по тому, в каком столбце она встречается.
Столбцы известного типа («Телефон», «ИНН», «Дата рождения») заменяются целиком, в том числе числа.
Остальные ячейки уходят в модель строкой листа, каждая со своим заголовком (rows.py) — и числа тоже:
телефон или паспорт, сохранённый Excel как число, иначе не увидел бы никто. Даты Excel хранит номером дня,
модели они показываются как дата. Формулы, стили, графики и картинки не трогаются.
"""
from __future__ import annotations

import re
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

from lxml import etree

from ..kinds import Kind
from ..kinds import PRIORITY
from ..spans import Span, merge
from .. import labels as columns
from . import ooxml
from . import rows as rows_mod
from .base import Context, Result, UnreadableFile, clip, output_path

EXTENSIONS = {".xlsx", ".xlsm", ".xltx"}
_S = "{%s}" % ooxml.NS["s"]
_SHEET = re.compile(r"^xl/worksheets/sheet\d+\.xml$")
_COMMENTS = re.compile(r"^xl/(comments\d*|comments/\w+|threadedComments/\w+)\.xml$")
_REF = re.compile(r"^([A-Z]+)(\d+)$")
_NUMERIC_KINDS = {Kind.PHONE, Kind.INN, Kind.SNILS, Kind.PASSPORT, Kind.CARD, Kind.ACCOUNT, Kind.ID, Kind.DATE, Kind.BIRTHDATE}


def _col(letters: str) -> int:
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n - 1


@dataclass
class _Sheet:
    name: str
    root: etree._Element
    header_row: int | None = None
    kinds: dict[int, Kind] = field(default_factory=dict)
    headers: dict[int, str] = field(default_factory=dict)


def _si_nodes(si: etree._Element) -> list[etree._Element]:
    """Текстовые узлы строки словаря без фонетических подсказок (rPh)."""
    return [t for t in si.iter(_S + "t") if not any(a.tag == _S + "rPh" for a in t.iterancestors())]


def process(src: Path, out_dir: Path, ctx: Context) -> Result:
    try:
        z = zipfile.ZipFile(src)
    except Exception as e:  # noqa: BLE001
        raise UnreadableFile(str(e)) from e
    with z:
        names = z.namelist()
        shared_root = ooxml.parse(z.read("xl/sharedStrings.xml")) if "xl/sharedStrings.xml" in names else None
        sheet_names = _sheet_titles(z)
        sheets = {n: _Sheet(sheet_names.get(n, n.rsplit("/", 1)[-1]), ooxml.parse(z.read(n)))
                  for n in sorted(names, key=lambda n: int(re.sub(r"\D", "", n) or 0)) if _SHEET.match(n)}
        comments = {n: ooxml.parse(z.read(n)) for n in names if _COMMENTS.match(n)}
        persons = {n: ooxml.parse(z.read(n)) for n in names if n.startswith("xl/persons/")}
        core = ooxml.parse(z.read("docProps/core.xml")) if "docProps/core.xml" in names else None
        dates = _DateStyles(z)
        raw = {n: z.read(n) for n in names if n == "xl/workbook.xml" or n.startswith("xl/worksheets/_rels/")}

    shared = list(shared_root.iter(_S + "si")) if shared_root is not None else []
    shared_text = ["".join(t.text or "" for t in _si_nodes(si)) for si in shared]

    # 1. Заголовки и типы столбцов
    for sh in sheets.values():
        _detect_header(sh, shared_text)

    # 2. Столбцы известного типа — целиком; остальное собираем в строки листа для модели
    whole_si: dict[int, Kind] = {}
    sheet_rows: list[list[tuple[tuple, rows_mod.Item]]] = []      # (ссылка на ячейку, текст с заголовком)
    for sh in sheets.values():
        by_row: dict[int, list[tuple[tuple, rows_mod.Item]]] = {}
        for c, row, col in _cells(sh.root):
            if sh.header_row is not None and row == sh.header_row:
                continue
            kind = sh.kinds.get(col)
            t = c.get("t")
            if c.find(_S + "f") is not None:
                continue  # формула: значение пересчитается из обезличенных ячеек
            header = sh.headers.get(col)
            if t == "s":
                v = c.find(_S + "v")
                if v is None or not (v.text or "").isdigit():
                    continue
                idx = int(v.text)
                if idx >= len(shared_text):
                    continue
                if kind and columns.accept(kind, shared_text[idx]):
                    whole_si.setdefault(idx, kind)
                elif rows_mod.worth_in_row(shared_text[idx]):
                    by_row.setdefault(row, []).append((("si", idx), rows_mod.Item(shared_text[idx], header)))
            elif t == "inlineStr":
                is_ = c.find(_S + "is")
                text = "".join(x.text or "" for x in is_.iter(_S + "t")) if is_ is not None else ""
                if kind and columns.accept(kind, text):
                    _set_inline(c, ctx.whole(kind, text.strip()))
                elif rows_mod.worth_in_row(text):
                    by_row.setdefault(row, []).append((("inline", c), rows_mod.Item(text, header)))
            elif t in (None, "n"):
                v = c.find(_S + "v")
                if v is None or not v.text:
                    continue
                shown = dates.text(c, v.text) or _number_text(v.text)
                if kind in _NUMERIC_KINDS:
                    if kind in (Kind.DATE, Kind.BIRTHDATE) or columns.accept(kind, v.text):
                        _set_inline(c, ctx.whole(kind, shown))
                elif dates.text(c, v.text) or len(re.sub(r"\D", "", shown)) >= 6:
                    # число-идентификатор (телефон, паспорт, ИНН) или дата: модель решит по заголовку и соседям
                    by_row.setdefault(row, []).append((("num", c, shown), rows_mod.Item(shown, header)))
        sheet_rows += [by_row[r] for r in sorted(by_row)]
    ctx.progress(0.1)

    # 3. Модель по строкам листов, замены
    for idx, kind in whole_si.items():
        nodes = _si_nodes(shared[idx])
        if nodes:
            nodes[0].text = ctx.whole(kind, shared_text[idx].strip())
            for n in nodes[1:]:
                n.text = ""
    found = rows_mod.find_rows(ctx, [[item for _ref, item in row] for row in sheet_rows], 0.1, 0.85)
    si_spans: dict[int, list[Span]] = {}
    for row, cells in zip(sheet_rows, found):
        for (ref, _item), spans in zip(row, cells):
            if not spans:
                continue
            if ref[0] == "si":
                if ref[1] not in whole_si:       # строка словаря встречается и в столбце известного типа
                    si_spans.setdefault(ref[1], []).extend(spans)
            elif ref[0] == "inline":
                ooxml.Paragraph(list(ref[1].find(_S + "is").iter(_S + "t"))).replace(merge(spans), ctx)
            else:
                _, c, shown = ref
                top = max(spans, key=lambda sp: PRIORITY[sp.kind])
                tagged = ctx.tag(top.kind, shown, top.ref if top.end - top.start == len(shown) else None)
                if tagged != shown:  # снятое пользователем значение остаётся числом
                    _set_inline(c, tagged)
    for idx, spans in si_spans.items():  # одна строка словаря в нескольких строках листа: скрываем всё найденное
        ooxml.Paragraph(_si_nodes(shared[idx])).replace(merge(spans), ctx)

    # 4. Примечания, их авторы, «люди» из цепочек комментариев
    for root in comments.values():
        for author in root.iter(_S + "author"):
            if author.text and author.text.strip():
                author.text = ctx.tag(Kind.PERSON, author.text.strip())
        texts = [ooxml.Paragraph(list(cm.iter(_S + "t"))) for cm in root.iter(_S + "comment")]
        texts += [ooxml.Paragraph([t]) for t in root.iter() if t.tag.endswith("}text") and t.text]
        ooxml.clean_paragraphs(texts, ctx, 0.85, 0.95)
    for root in persons.values():
        ooxml.anonymize_attributes(root, ["displayName"], ctx, blank=["userId"])
    if core is not None:
        ooxml.clean_core_properties(core, ctx)

    # 5. Запись
    replaced: dict[str, etree._Element] = {**{n: sh.root for n, sh in sheets.items()}, **comments, **persons}
    if shared_root is not None:
        replaced["xl/sharedStrings.xml"] = shared_root
    if core is not None:
        replaced["docProps/core.xml"] = core
    dst = output_path(src, out_dir)
    ooxml.rewrite_zip(src, dst, lambda name, data: ooxml.serialize(replaced[name]) if name in replaced else None)
    ctx.progress(1.0)
    shared_now = ["".join(t.text or "" for t in _si_nodes(si)) for si in shared]
    from . import layout, xlsx_view
    view = layout.safely(xlsx_view.build, sheets, shared_now, dates, comments, persons, core, raw)
    return Result(dst, clip(_preview(sheets, shared_now)), ctx.replaced, layout=view)


def _cells(root: etree._Element):
    for c in root.iter(_S + "c"):
        m = _REF.match(c.get("r", ""))
        if m:
            yield c, int(m.group(2)), _col(m.group(1))


def _cell_text(c: etree._Element, shared_text: list[str]) -> str | None:
    t = c.get("t")
    if t == "s":
        v = c.find(_S + "v")
        if v is not None and (v.text or "").isdigit() and int(v.text) < len(shared_text):
            return shared_text[int(v.text)]
        return None
    if t == "inlineStr":
        is_ = c.find(_S + "is")
        return "".join(x.text or "" for x in is_.iter(_S + "t")) if is_ is not None else None
    v = c.find(_S + "v")
    return v.text if v is not None else None


def _detect_header(sh: _Sheet, shared_text: list[str]) -> None:
    rows: dict[int, dict[int, str]] = {}
    for c, row, col in _cells(sh.root):
        text = _cell_text(c, shared_text)
        if text is not None and text.strip():
            rows.setdefault(row, {})[col] = text
        if len(rows) > 6:
            break
    for row in sorted(rows)[:5]:
        cells = rows[row]
        if sum(1 for v in cells.values() if not re.search(r"\d", v)) >= max(1, int(len(cells) * 0.7)):
            sh.header_row = row
            sh.kinds = {col: k for col, h in cells.items() if (k := columns.classify(h))}
            sh.headers = dict(cells)
            return


def _set_inline(c: etree._Element, text: str) -> None:
    for child in list(c):
        if child.tag in (_S + "v", _S + "is"):
            c.remove(child)
    c.set("t", "inlineStr")
    is_ = etree.SubElement(c, _S + "is")
    etree.SubElement(is_, _S + "t").text = text


def _number_text(v: str) -> str:
    return v[:-2] if v.endswith(".0") else v


# Встроенные форматы Excel с датой (ECMA-376, 18.8.30) и признак своей даты в коде формата
_BUILTIN_DATE_FORMATS = {14, 15, 16, 17, 22, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 45, 46, 47, 50, 51, 52, 53, 54, 55,
                         56, 57, 58}


class _DateStyles:
    """Какие стили ячеек — даты, и как показать число-дату («31122» → «17.03.1985»)."""

    def __init__(self, z: zipfile.ZipFile) -> None:
        self.date_xf: set[int] = set()
        self.base = (1899, 12, 30)
        names = z.namelist()
        try:
            if "xl/workbook.xml" in names and b'date1904="1"' in z.read("xl/workbook.xml").replace(b"true", b"1"):
                self.base = (1904, 1, 1)
            if "xl/styles.xml" not in names:
                return
            root = ooxml.parse(z.read("xl/styles.xml"))
        except Exception:  # noqa: BLE001 — без стилей просто не узнаём даты
            return
        custom = {}
        for nf in root.iter(_S + "numFmt"):
            code = re.sub(r'"[^"]*"|\[[^\]]*\]|\\.', "", nf.get("formatCode", "")).lower()
            custom[int(nf.get("numFmtId", "0"))] = bool(re.search(r"[dy]", code)) and "0" not in code
        xfs = root.find(_S + "cellXfs")
        for i, xf in enumerate(xfs if xfs is not None else []):
            fid = int(xf.get("numFmtId", "0"))
            if fid in _BUILTIN_DATE_FORMATS or custom.get(fid):
                self.date_xf.add(i)

    def text(self, c: etree._Element, value: str) -> str | None:
        if int(c.get("s", "0") or 0) not in self.date_xf:
            return None
        try:
            import datetime as dt
            day = dt.date(*self.base) + dt.timedelta(days=int(float(value)))
        except (ValueError, OverflowError):
            return None
        return day.strftime("%d.%m.%Y")


def _sheet_titles(z: zipfile.ZipFile) -> dict[str, str]:
    try:
        wb = ooxml.parse(z.read("xl/workbook.xml"))
        rels = ooxml.parse(z.read("xl/_rels/workbook.xml.rels"))
    except KeyError:
        return {}
    rid = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"
    target = {r.get("Id"): r.get("Target") for r in rels}
    out = {}
    for s in wb.iter(_S + "sheet"):
        t = target.get(s.get(rid), "")
        t = t.lstrip("/")
        out["xl/" + t if not t.startswith("xl/") else t] = s.get("name", "")
    return out


def _preview(sheets: dict[str, _Sheet], shared_text: list[str], limit_rows: int = 400) -> str:
    """Предпросмотр и «Скопировать текст» — Markdown-таблицы: нейросети читают их лучше всего."""
    parts = []
    for sh in sheets.values():
        rows: dict[int, dict[int, str]] = {}
        for c, row, col in _cells(sh.root):
            text = _cell_text(c, shared_text)
            if text is not None and text != "":
                rows.setdefault(row, {})[col] = text
        if not rows:
            continue
        cols = sorted({c for r in rows.values() for c in r})[:60]
        lines = []
        for i, row in enumerate(sorted(rows)[:limit_rows]):
            cells = [rows[row].get(c, "").replace("|", "\\|").replace("\n", " ") for c in cols]
            lines.append("| " + " | ".join(cells) + " |")
            if i == 0:
                lines.append("|" + "|".join(" --- " for _ in cols) + "|")
        parts.append(f"### {sh.name}\n\n" + "\n".join(lines))
    return "\n\n".join(parts)

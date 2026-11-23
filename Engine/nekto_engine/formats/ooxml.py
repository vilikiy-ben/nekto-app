"""Общее для DOCX / XLSX / PPTX: правка XML прямо внутри ZIP-контейнера.

Почему не python-docx / openpyxl: они теряют часть содержимого (openpyxl — графики и
картинки) и не видят колонтитулы, сноски, примечания, исправления. Здесь любой XML-узел
с текстом обрабатывается на месте, всё остальное копируется байт в байт.
"""
from __future__ import annotations

import re
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

from lxml import etree

from ..kinds import Kind
from ..spans import Span
from .base import Context

NS = {
    "w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
    "s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "p": "http://schemas.openxmlformats.org/presentationml/2006/main",
    "cp": "http://schemas.openxmlformats.org/package/2006/metadata/core-properties",
    "dc": "http://purl.org/dc/elements/1.1/",
    "xml": "http://www.w3.org/XML/1998/namespace",
}
_PARSER = etree.XMLParser(resolve_entities=False, no_network=True, huge_tree=True, remove_blank_text=False)


def parse(data: bytes) -> etree._Element:
    return etree.fromstring(data, _PARSER)


def serialize(root: etree._Element) -> bytes:
    return etree.tostring(root, xml_declaration=True, encoding="UTF-8", standalone=True)


class Paragraph:
    """Логическая строка текста, разбитая на несколько XML-узлов (runs)."""

    __slots__ = ("nodes", "element")

    def __init__(self, nodes: list[etree._Element], element: etree._Element | None = None) -> None:
        self.nodes = nodes
        self.element = element  # сам абзац (w:p / a:p), если известен — нужен, чтобы найти его ячейку таблицы

    @property
    def text(self) -> str:
        return "".join(n.text or "" for n in self.nodes)

    def replace(self, spans: list[Span], ctx: Context) -> None:
        texts = [n.text or "" for n in self.nodes]
        full = "".join(texts)
        starts, acc = [], 0
        for t in texts:
            starts.append(acc); acc += len(t)
        for sp in sorted(spans, key=lambda s: s.start, reverse=True):
            placeholder = ctx.tag(sp.kind, full[sp.start:sp.end], sp.ref)
            first = True
            for k, t in enumerate(texts):
                ns, ne = starts[k], starts[k] + len(self.nodes[k].text or "")
                a, b = max(sp.start, ns), min(sp.end, ne)
                if a >= b:
                    continue
                la, lb = a - ns, b - ns
                if first:
                    texts[k] = t[:la] + placeholder + t[lb:]
                    first = False
                else:
                    texts[k] = t[:la] + t[lb:]
        for node, t in zip(self.nodes, texts):
            if node.text != t:
                node.text = t
                if t[:1].isspace() or t[-1:].isspace():
                    node.set(f"{{{NS['xml']}}}space", "preserve")


def clean_paragraphs(paragraphs: list[Paragraph], ctx: Context, lo: float, hi: float) -> None:
    paragraphs = [p for p in paragraphs if p.nodes]
    found = ctx.find([p.text for p in paragraphs], lo, hi)
    for p, spans in zip(paragraphs, found):
        if spans:
            p.replace(spans, ctx)


# Не люди: программы, создавшие файл, и учётные записи по умолчанию. Их в «Автор» и «Изменил» скрывать незачем —
# в панели «Скрыто» они выглядели как ФИО («openpyxl»). Логин вроде «ivanov.ii» сюда не попадает и скрывается.
_NOT_PEOPLE = {
    "openpyxl", "python-docx", "python-pptx", "xlsxwriter", "apache poi", "libreoffice", "openoffice", "wps office",
    "microsoft office", "microsoft office user", "microsoft excel", "microsoft word", "microsoft powerpoint",
    "пользователь microsoft office", "пользователь windows", "пользователь", "user", "admin", "administrator",
    "администратор", "owner", "unknown", "author", "автор", "google", "google sheets", "google docs", "office",
}


def is_person_field(value: str) -> bool:
    v = value.strip().lower()
    return bool(re.search(r"[a-zа-яё]", v)) and v not in _NOT_PEOPLE


def clean_core_properties(root: etree._Element, ctx: Context) -> None:
    """Автор и «кем изменён» — частая утечка ФИО. Заголовок и описание обезличиваем моделью."""
    for tag in ("dc:creator", "cp:lastModifiedBy"):
        for el in root.iterfind(tag, NS):
            if el.text and is_person_field(el.text):
                el.text = ctx.tag(Kind.PERSON, el.text.strip())
    texts = [el for tag in ("dc:title", "dc:subject", "dc:description", "cp:keywords")
             for el in root.iterfind(tag, NS) if el.text and el.text.strip()]
    if texts:
        for el, cleaned in zip(texts, ctx.clean_segments([el.text for el in texts])):
            el.text = cleaned


def anonymize_attributes(root: etree._Element, names: Iterable[str], ctx: Context,
                         blank: Iterable[str] = ()) -> None:
    """Атрибуты-авторы правок и комментариев (w:author, name у авторов комментариев PowerPoint).
    Инициалы (blank) просто стираем: отдельная метка для «И.П.» только запутает."""
    for attr in blank:
        for el in root.iter():
            if el.get(attr):
                el.set(attr, "")
    for attr in names:
        for el in root.iter():
            v = el.get(attr)
            if v and is_person_field(v) and not re.fullmatch(r"\[[A-ZА-ЯЁ]+_\d+\]", v):
                el.set(attr, ctx.tag(Kind.PERSON, v.strip()))


def rewrite_zip(src: Path, dst: Path, handler: Callable[[str, bytes], bytes | None]) -> None:
    """Копирует архив, давая handler шанс заменить содержимое любого файла (None — без изменений)."""
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
        for info in zin.infolist():
            data = zin.read(info.filename)
            new = handler(info.filename, data)
            out_info = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            out_info.compress_type = info.compress_type
            out_info.external_attr = info.external_attr
            zout.writestr(out_info, new if new is not None else data)


def collect(root: etree._Element, para_tag: str, text_tag: str) -> list[Paragraph]:
    out = []
    for p in root.iter(para_tag):
        # вложенные абзацы (надписи внутри абзаца) обрабатываются отдельно — не дублируем их текст
        nodes = [t for t in p.iter(text_tag) if next(t.iterancestors(para_tag), None) is p]
        if nodes:
            out.append(Paragraph(nodes, p))
    return out


@dataclass(frozen=True)
class TableTags:
    tbl: str
    tr: str
    tc: str
    p: str
    span: str            # объединённые по горизонтали ячейки: w:gridSpan@w:val (Word) или @gridSpan (PowerPoint)


def clean_tables(root: etree._Element, paragraphs: list[Paragraph], tags: TableTags, ctx: Context,
                 lo: float, hi: float) -> set[int]:
    """Таблицы документа — строками с заголовками (rows.py), столбцы известного типа — целиком.
    Возвращает id() абзацев, которые уже обработаны (строки данных); остальное — обычным порядком."""
    from .. import labels as columns
    from . import rows as rows_mod
    from .tabular import looks_like_header

    by_element = {id(par.element): par for par in paragraphs if par.element is not None}
    done: set[int] = set()
    pending: list[list[tuple[Paragraph, rows_mod.Item]]] = []
    for tbl in root.iter(tags.tbl):
        grid: list[list[tuple[int, list[Paragraph]]]] = []
        for tr in (r for r in tbl if r.tag == tags.tr):
            cells, col = [], 0
            for tc in (c for c in tr if c.tag == tags.tc):
                own = [by_element[id(p)] for p in tc.iter(tags.p)
                       if next(p.iterancestors(tags.tc), None) is tc and id(p) in by_element]
                cells.append((col, own))
                col += _grid_span(tc, tags)
            grid.append(cells)
        if not grid:
            continue
        first = {col: " ".join(par.text for par in pars).strip() for col, pars in grid[0]}
        has_header = len(grid) > 1 and looks_like_header(list(first.values()))
        headers = first if has_header else {}
        kinds = {col: k for col, h in headers.items() if (k := columns.classify(h))}
        for cells in grid[1:] if has_header else grid:
            items = []
            for col, pars in cells:
                kind = kinds.get(col)
                cell_text = " ".join(par.text for par in pars)
                for par in pars:
                    done.add(id(par))
                    if kind and columns.accept(kind, cell_text):
                        sp = rows_mod.whole(par.text, kind)
                        if sp:
                            par.replace([sp], ctx)
                    elif rows_mod.worth_in_row(par.text):
                        items.append((par, rows_mod.Item(par.text, headers.get(col))))
            if items:
                pending.append(items)
    found = rows_mod.find_rows(ctx, [[it for _p, it in row] for row in pending], lo, hi)
    for row, cells in zip(pending, found):
        for (par, _it), spans in zip(row, cells):
            if spans:
                par.replace(spans, ctx)
    return done


def _grid_span(tc: etree._Element, tags: TableTags) -> int:
    raw = tc.get(tags.span)
    if raw is None:
        for el in tc.iter(tags.span):
            raw = el.get(f"{{{NS['w']}}}val")
            break
    try:
        return max(1, int(raw)) if raw else 1
    except ValueError:
        return 1

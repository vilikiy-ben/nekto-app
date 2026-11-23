"""Таблицы: ячейки идут в поиск со своими заголовками, строка — своя область.

Модель контекстная: голое «ул. Мира, 35» для неё может быть офисом, а «Адрес: ул. Мира, 35» — уже ПДн. Поэтому:

- короткие ячейки строки уходят одним сегментом, каждая со своим заголовком —
      «Кто: Иванов И. И.; Родился: 12.03.85; Связь: 89161234567; Где живёт: Ленина 5-12»
  — запись о человеке читается целиком, и найденное раскладывается обратно по ячейкам;
- длинная ячейка (комментарий, описание) — отдельный сегмент «Заголовок: текст»: ей хватает собственного контекста,
  одинаковые значения считаются один раз, и одна и та же ячейка размечается одинаково, в какой бы строке ни стояла.

Соседние строки таблицы модели не показываются (`context=False`): это чужие записи. По той же причине строка —
область склейки людей (`names.registry`): «Ксении» в одной строке и «Ксения Зуева» в другой — не обязательно
один человек.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Sequence

from ..kinds import Kind
from ..spans import Span, merge, trim
from .base import Context

_SEP = "; "
_LONG = 80        # с этой длины ячейка — самостоятельный текст
_SMALL_NUMBER = re.compile(r"^[\s\d.,%+\-−–:/()€$₽]*$")
# Число в строке про человека: «Кто: Иванов И. И. | Документ: 4510123456». Модель не знает, что это паспорт,
# но номер из семи и более цифр рядом с человеком — его номер, а не сумма.
_BARE_NUMBER = re.compile(r"^\s*[№#]?\s*\d[\d \-–]{5,}\d\s*$")
_THOUSANDS = re.compile(r"^\s*\d{1,3}(?:[ \u00a0]\d{3})+\s*$")
_AMOUNT_HEADER = re.compile(r"сумм|цен[аы]|стоим|оплат|итог|кол-?во|количеств|оклад|зарплат|salary|amount|price|qty|total|"
                            r"баланс|остат|руб|usd|eur|%|процент|объ[её]м|вес\b|площад|штук|\bшт\b|бюджет|выручк|доход|расход",
                            re.IGNORECASE)


@dataclass
class Item:
    """Текст одной ячейки (или одного абзаца ячейки) и заголовок её столбца."""
    text: str
    header: str | None = None


def worth_in_row(value: str) -> bool:
    """Что брать в строку: всё непустое, кроме коротких чисел (номер строки, количество, сумма до 4 цифр).
    Внутри строки серия паспорта «45 10» и «1.03.85» видны с заголовком, поэтому порог ниже, чем у отдельных ячеек."""
    v = value.strip()
    if not v:
        return False
    if _SMALL_NUMBER.match(v) and len(re.sub(r"\D", "", v)) < 4:
        return False
    return True


def find_rows(ctx: Context, rows: Sequence[Sequence[Item]], lo: float = 0.0, hi: float = 1.0) -> list[list[list[Span]]]:
    """Спаны для каждой ячейки каждой строки — в координатах текста ячейки."""
    segments: list[str] = []
    scopes: list[int] = []
    layout: list[list[tuple[int, int, int]]] = []          # ячейка → (сегмент, начало текста ячейки в нём, длина)
    for r, row in enumerate(rows):
        places: list[tuple[int, int, int]] = [(0, 0, 0)] * len(row)
        short: list[str] = []
        pos = 0
        joined = -1
        for k, item in enumerate(row):
            header = _clean_header(item.header)
            prefix = f"{header}: " if header else ""
            if len(item.text) > _LONG or "\n" in item.text:
                places[k] = (len(segments), len(prefix), len(item.text))
                segments.append(prefix + item.text)
                scopes.append(r)
                continue
            if joined < 0:
                joined = len(segments)
                segments.append("")
                scopes.append(r)
            if short:
                pos += len(_SEP)
            places[k] = (joined, pos + len(prefix), len(item.text))
            short.append(prefix + item.text)
            pos += len(prefix) + len(item.text)
        if joined >= 0:
            segments[joined] = _SEP.join(short)
        layout.append(places)
    found = ctx.find(segments, lo, hi, scopes, context=False)
    out: list[list[list[Span]]] = []
    for row, places in zip(rows, layout):
        cells: list[list[Span]] = []
        for item, (index, start, length) in zip(row, places):
            mine = []
            for sp in found[index]:
                a, b = max(sp.start, start), min(sp.end, start + length)
                if a < b:
                    t = trim(item.text, sp.moved(a - start, b - start))
                    if t:
                        mine.append(t)
            cells.append(merge(mine))
        if any(sp.kind is Kind.PERSON for spans in cells for sp in spans):
            for k, item in enumerate(row):
                if not cells[k] and _person_number(item):
                    span = whole(item.text, Kind.ID)
                    if span:
                        cells[k] = [Span(span.start, span.end, Kind.ID, 0.6, "row")]
        out.append(cells)
    return out


def _person_number(item: Item) -> bool:
    text = item.text
    if not _BARE_NUMBER.match(text) or _THOUSANDS.match(text) or sum(ch.isdigit() for ch in text) < 7:
        return False
    return not (item.header and _AMOUNT_HEADER.search(item.header))


def whole(text: str, kind) -> Span | None:
    """Спан на всё значение ячейки без пробелов по краям (столбец известного типа)."""
    s = len(text) - len(text.lstrip())
    e = len(text.rstrip())
    return Span(s, e, kind, 1.0, "column") if e > s else None


def _clean_header(header: str | None) -> str:
    return re.sub(r"\s+", " ", str(header or "")).strip(" :;|")[:60]

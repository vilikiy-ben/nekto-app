"""Спаны найденных ПДн и их слияние."""
from __future__ import annotations

from dataclasses import dataclass

from .kinds import PRIORITY, Kind

_TRIM = " \t\r\n,;:()[]{}«»\"'"


@dataclass(frozen=True, slots=True)
class Span:
    start: int
    end: int
    kind: Kind
    score: float = 1.0
    source: str = "model"  # model | names | rule | known | org | user | column
    ref: str | None = None  # метка, уже назначенная значению (`Session.bind`): кто этот человек, решено по документу

    def shifted(self, offset: int) -> "Span":
        return Span(self.start + offset, self.end + offset, self.kind, self.score, self.source, self.ref)

    def moved(self, start: int, end: int) -> "Span":
        return Span(start, end, self.kind, self.score, self.source, self.ref)


def trim(text: str, span: Span) -> Span | None:
    """Обрезает пробелы и пунктуацию по краям: «, ИНН 1661…» не должно съедать запятую."""
    s, e = span.start, span.end
    while s < e and text[s] in _TRIM:
        s += 1
    while e > s and text[e - 1] in _TRIM:
        # закрывающую скобку/кавычку оставляем, если внутри спана есть открывающая
        ch = text[e - 1]
        if ch in ")]»\"" and _has_opener(text[s:e - 1], ch):
            break
        e -= 1
    if e - s < 1:
        return None
    return span.moved(s, e)


def _has_opener(chunk: str, closer: str) -> bool:
    return {")": "(", "]": "[", "»": "«", "\"": "\""}[closer] in chunk


# Значения-контейнеры: то, что лежит внутри ссылки или адреса почты, — их часть, а не отдельное ПДн.
# Иначе ссылка на встречу распадается на «телефон» (номер конференции) и «пароль» (pwd=…).
_CONTAINERS = (Kind.URL, Kind.EMAIL)


def merge(spans: list[Span]) -> list[Span]:
    """Сливает пересекающиеся спаны. Протяжённость — объединение, тип — с наибольшим приоритетом.
    Спан внутри ссылки или e-mail поглощается ими без смены типа."""
    if not spans:
        return []
    holders = [s for s in spans if s.kind in _CONTAINERS]
    if holders:
        spans = [s for s in spans if s.kind in _CONTAINERS
                 or not any(h.start <= s.start and s.end <= h.end for h in holders)]
    ordered = sorted(spans, key=lambda s: (s.start, -s.end))
    out: list[Span] = [ordered[0]]
    for sp in ordered[1:]:
        cur = out[-1]
        if sp.start < cur.end:  # пересекаются
            win = cur if PRIORITY[cur.kind] >= PRIORITY[sp.kind] else sp
            out[-1] = Span(cur.start, max(cur.end, sp.end), win.kind, max(cur.score, sp.score), win.source, win.ref)
        else:
            out.append(sp)
    return out

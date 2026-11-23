"""Поиск ПДн: модель, словарь имён и правила — три независимых источника, решение по их совокупности.

    сегменты ─► ворота ─► модель (слова с метками) ─┬─► names.finder   — ФИО: модель + словарь + регистр + документ
                 │                                   ├─► entities       — контакты, номера, адреса: сборка и проверка формы
                 │                                   ├─► fields         — поля анкеты: «Метка: значение»
                 └────────── без модели ────────────┴─► rules           — номера с контрольной суммой, ссылки, даты
                                                                     ─► spans.merge

ФИО ищутся в каждом сегменте отдельно. Остальное в сплошном тексте — по всему тексту сразу: адрес или номер паспорта
бывает разорван переводом строки, а метка поля и «ООО … ИНН …» над адресом стоят на соседних строках.

Модель — один из голосов, а не судья: она уверенно (0,99) ошибается на жаргоне и опечатках, поэтому решение принимается
по всем свидетельствам вместе.

Что уходит в модель:
- сплошной текст (строки файла, абзацы документа) — окнами из соседних строк: короткой строке анкеты или скана
  («Белая» под «Фамилия BELAYA ANNA») модели нужен контекст, по одной такие строки она не узнаёт;
- ячейки таблиц — каждая сама по себе (`context=False`): соседние ячейки — чужие записи, и одна и та же ячейка
  должна размечаться одинаково, в какой бы строке ни стояла.

Три вещи про скорость и память:
- ворота: текст, в котором нет ни заглавной буквы в середине предложения, ни имени из словаря, ни цифр номера,
  в модель не идёт — ей там нечего найти, а всё, что нашла бы, отклонил бы словарь;
- одинаковое считается один раз, ответы модели помнятся по тексту окна: тысяча строк таблицы с одним и тем же
  названием отдела — один вызов, пересчёт после правки пользователя — ни одного;
- пакет для модели собирается из окон близкой длины и держится в бюджете токенов (`model.tagger`).
"""
from __future__ import annotations

import hashlib
import re
import threading
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

from . import entities, fields
from .kinds import Kind
from .model import Tag, Tagger
from .names import finder
from .rules import birth, rule_spans
from .rules import may_match as rules_may_match
from .spans import Span, merge, trim

Progress = Callable[[float], None]


class Cancelled(Exception):
    pass


@dataclass
class DetectorConfig:
    model_dir: Path
    threads: int = 4
    window: int = 1000           # окно для модели, символов: длинный сегмент режется, короткие соседи собираются
    overlap: int = 150
    prelude: int = 200           # сколько предыдущего текста окно получает как контекст (в нём ничего не ищется)
    cache_chars: int = 30_000_000   # сколько текста сегментов помнить вместе с ответами модели


# Цифры, ради которых стоит звать модель: номер (от шести цифр, в том числе через пробелы, дефисы и скобки —
# «45 11 123456», «8 (900) 555-01-48») или адрес с номером дома. «10 из 10», «скидка 15%», «сумма 4 800» — не повод:
# короткие номера (табельный, добавочный) находят правила по слову рядом.
_DIGITS_RUN = re.compile(r"\d(?:[\s\-–()]{0,3}\d){5,}")
_ADDRESS_WORD = re.compile(r"(?<!\w)(?:ул|улиц\w*|пр-т|просп\w*|пер|переул\w*|шоссе|бульвар\w*|б-р|наб\w*|мкр\w*|микрорайон\w*|"
                           r"дом|д|кв|квартир\w*|корп\w*|пос[её]л\w*|деревн\w*|село)\.?\s*[\w«\"-]*\s*\d", re.IGNORECASE)


def needs_model(segment: str) -> bool:
    """Ворота: может ли модель найти в сегменте что-то, чего не найдут правила."""
    if _DIGITS_RUN.search(segment) or _ADDRESS_WORD.search(segment):
        return True
    return finder.needs_model(segment)


class Detector:
    def __init__(self, config: DetectorConfig) -> None:
        self.config = config
        self.tagger = Tagger(config.model_dir, threads=config.threads)
        # Ответ модели зависит только от текста сегмента. Правка пользователя («не скрывать», «скрыть», режим)
        # меняет решение, а не ответ, поэтому пересчёт документа после правки берёт ответы отсюда — без модели.
        self._cache: OrderedDict[bytes, tuple[int, tuple[Tag, ...]]] = OrderedDict()
        self._cache_chars = 0
        self._cache_lock = threading.Lock()

    # ---------- жизненный цикл ----------

    @property
    def loaded(self) -> bool:
        return self.tagger.loaded

    def load(self) -> None:
        if self.tagger.loaded:
            return
        self.tagger.load()
        from .names import lexicon
        lexicon.morph()                                       # словарь — тоже при загрузке, а не на первом документе
        self.tagger.tag(["Прогрев: Иван Петров, +7 900 000-00-00"])

    # ---------- публичное ----------

    def detect(self, text: str, cancel: threading.Event | None = None, progress: Progress | None = None) -> list[Span]:
        return self.detect_segments([text], cancel, progress)[0]

    def detect_segments(self, segments: Sequence[str], cancel: threading.Event | None = None,
                        progress: Progress | None = None, vocabulary: finder.Vocabulary | None = None,
                        context: bool = True) -> list[list[Span]]:
        """Спаны для каждого сегмента в его собственных координатах.

        `context` — сегменты идут подряд в одном тексте, и соседи дают модели контекст (строки, абзацы);
        `False` — сегменты независимы (ячейки таблицы). `vocabulary` — строчные слова всего документа, если
        сегменты — только его часть."""
        if vocabulary is None:
            vocabulary = finder.Vocabulary(segments)
        tags = self._tags(segments, cancel, progress, context)
        found: list[list[Span]] = [
            [Span(a, b, Kind.PERSON, score, "names") for a, b, score in finder.find(seg, seg_tags, vocabulary)]
            if seg.strip() else [] for seg, seg_tags in zip(segments, tags)]
        if context:
            for index, span in _assemble_together(segments, tags):
                found[index].append(span)
        else:
            for index, (seg, seg_tags) in enumerate(zip(segments, tags)):
                if seg.strip() and (seg_tags or rules_may_match(seg)):
                    found[index] += _assemble(seg, seg_tags)
        out: list[list[Span]] = []
        for seg, spans in zip(segments, found):
            spans = [t for t in (trim(seg, s) for s in spans) if t]
            spans = merge([birth(seg, s) for s in spans])
            out.append(_person_numbers(seg, spans))
        return out

    # ---------- модель ----------

    def _tags(self, segments: Sequence[str], cancel: threading.Event | None, progress: Progress | None,
              context: bool) -> list[tuple[Tag, ...]]:
        """Слова с метками модели для каждого сегмента: из памяти, а чего там нет — одним проходом модели."""
        wanted = [bool(seg.strip()) and needs_model(seg) for seg in segments]
        result: list[list[Tag]] = [[] for _ in segments]
        windows = [w for w in self._windows(segments, context) if any(wanted[i] for i, _o, _s, _n in w.parts)]
        answers: dict[str, tuple[Tag, ...]] = {}
        todo: list[str] = []
        for w in windows:
            if w.text not in answers:
                cached = self._cached(w.text)
                if cached is None:
                    todo.append(w.text)
                    answers[w.text] = ()
                else:
                    answers[w.text] = cached
        if todo:
            try:
                found = self.tagger.tag(todo, progress, (lambda: cancel.is_set()) if cancel is not None else None)
            except InterruptedError:
                raise Cancelled() from None
            for text, tags in zip(todo, found):
                answers[text] = tuple(tags)
                self._remember(text, answers[text])
        for w in windows:
            for tag in answers[w.text]:
                for index, offset, seg_start, length in w.parts:
                    if offset <= tag.start and tag.end <= offset + length:
                        # и для сегмента, который сам модель бы не позвал: раз окно посчитано, её голос учитывается
                        result[index].append(Tag(tag.start - offset + seg_start, tag.end - offset + seg_start,
                                                 tag.label, tag.score))
                        break
        if progress:
            progress(1.0)
        out = []
        for tags in result:                                      # перекрытие окон длинного сегмента: слово — один раз
            best: dict[tuple[int, int], Tag] = {}
            for t in tags:
                if (t.start, t.end) not in best or t.score > best[(t.start, t.end)].score:
                    best[(t.start, t.end)] = t
            out.append(tuple(sorted(best.values(), key=lambda t: t.start)))
        return out

    def _windows(self, segments: Sequence[str], context: bool):
        """Окна для модели. С контекстом: соседние короткие сегменты собираются в окно через перевод строки, и окно
        получает хвост предыдущего как контекст. Без контекста: сегмент — окно. Длинный сегмент режется в обоих случаях."""
        cfg = self.config
        pack: _Window | None = None
        tail = ""
        for index, seg in enumerate(segments):
            if not seg.strip():
                continue
            if len(seg) > cfg.window:
                if pack:
                    yield pack
                    pack = None
                for start, end in _cut(seg, cfg.window, cfg.overlap):
                    yield _Window.single(index, seg, start, end)
                tail = seg[-cfg.prelude:]
                continue
            if not context:
                yield _Window.single(index, seg, 0, len(seg))
                continue
            if pack is not None and len(pack.text) + 1 + len(seg) > cfg.window + len(pack.prelude):
                yield pack
                tail = pack.text[-cfg.prelude:]
                pack = None
            if pack is None:
                cut = tail.find("\n")                             # контекст — с начала строки
                pack = _Window(tail[cut + 1:] if 0 <= cut < len(tail) - 1 else tail)
            pack.add(index, seg)
        if pack:
            yield pack

    def _cached(self, segment: str) -> tuple[Tag, ...] | None:
        key = _key(segment)
        with self._cache_lock:
            hit = self._cache.get(key)
            if hit is None:
                return None
            self._cache.move_to_end(key)
            return hit[1]

    def _remember(self, segment: str, tags: tuple[Tag, ...]) -> None:
        key = _key(segment)
        with self._cache_lock:
            if key not in self._cache:
                self._cache_chars += len(segment)
            self._cache[key] = (len(segment), tags)
            while self._cache_chars > self.config.cache_chars and len(self._cache) > 1:
                _k, (size, _tags) = self._cache.popitem(last=False)
                self._cache_chars -= size


def _assemble(text: str, tags: Sequence[Tag]) -> list[Span]:
    """Всё, кроме ФИО: значения по меткам модели, поля анкеты, правила."""
    spans = entities.from_tags(text, tags) + rule_spans(text)
    for span in fields.find(text):
        if span.kind is not Kind.ADDRESS or entities.private_address(text, span.start, span.end):
            spans.append(span)
    return [s for s in spans if s.kind is not Kind.ADDRESS or s.source != "rule" or "кв" in text[s.start:s.end].lower()
            or entities.private_address(text, s.start, s.end)]


def _assemble_together(segments: Sequence[str], tags: Sequence[Sequence[Tag]]):
    """То же по всему тексту сразу: сегменты склеены переводом строки, найденное возвращается в свои сегменты
    (значение, разорванное переводом строки, — по куску в каждый)."""
    starts, pos = [], 0
    for seg in segments:
        starts.append(pos)
        pos += len(seg) + 1
    text = "\n".join(segments)
    shifted = [Tag(t.start + off, t.end + off, t.label, t.score) for off, seg_tags in zip(starts, tags) for t in seg_tags]
    index = 0
    for span in sorted(_assemble(text, shifted), key=lambda s: s.start):
        while index + 1 < len(starts) and starts[index + 1] <= span.start:
            index += 1
        k, start = index, span.start
        while start < span.end and k < len(segments):
            seg_end = starts[k] + len(segments[k])
            piece_end = min(span.end, seg_end)
            if piece_end > start:
                yield k, span.moved(start - starts[k], piece_end - starts[k])
            k += 1
            start = starts[k] if k < len(starts) else span.end


# Строка-запись о человеке с разделителями столбцов: «10474 | Седых Наталья В. | 6782601827 | …».
_CELL = re.compile(r"[^|\t]+")
_BARE_NUMBER = re.compile(r"\s*[№#]?\s*(\d[\d \-–]{5,}\d)\s*")
_THOUSANDS = re.compile(r"\d{1,3}(?:[ \u00a0]\d{3})+")
# Год рождения сразу за человеком: «жена — Цыренжапова Сэсэг Владимировна, 1982; сын — …, 2009».
_YEAR_AFTER = re.compile(r",\s*((?:19[2-9]|20[0-2])\d)(?=\s*(?:г\.?\s?р|года\s+рожд|[;,.)]|$))")


def _person_numbers(seg: str, spans: list[Span]) -> list[Span]:
    """Числа, которые относятся к человеку, потому что стоят рядом с ним: номер в соседнем столбце той же строки
    и год рождения сразу за именем."""
    people = [s for s in spans if s.kind is Kind.PERSON]
    if not people:
        return spans
    extra: list[Span] = []
    if "|" in seg or "\t" in seg:
        for cell in _CELL.finditer(seg):
            m = _BARE_NUMBER.fullmatch(cell.group())
            if not m or sum(ch.isdigit() for ch in m.group(1)) < 7 or _THOUSANDS.fullmatch(m.group(1)):
                continue
            start, end = cell.start() + m.start(1), cell.start() + m.end(1)
            if not any(s.start < end and start < s.end for s in spans):
                extra.append(Span(start, end, Kind.ID, 0.6, "row"))
    for person in people:
        m = _YEAR_AFTER.match(seg, person.end)
        if m and not any(s.start < m.end(1) and m.start(1) < s.end for s in spans):
            extra.append(Span(m.start(1), m.end(1), Kind.BIRTHDATE, 0.6, "row"))
    return merge(spans + extra) if extra else spans


class _Window:
    """Текст для модели: один или несколько сегментов (после необязательного контекста) и где каждый из них лежит."""

    __slots__ = ("text", "parts", "prelude")

    def __init__(self, prelude: str = "") -> None:
        self.prelude = prelude
        self.text = prelude
        self.parts: list[tuple[int, int, int, int]] = []     # (сегмент, смещение в окне, начало в сегменте, длина)

    @classmethod
    def single(cls, index: int, seg: str, start: int, end: int) -> "_Window":
        w = cls()
        w.text = seg[start:end]
        w.parts.append((index, 0, start, end - start))
        return w

    def add(self, index: int, seg: str) -> None:
        if self.text:
            self.text += "\n"
        self.parts.append((index, len(self.text), 0, len(seg)))
        self.text += seg


def _key(segment: str) -> bytes:
    return hashlib.blake2b(segment.encode("utf-8", "surrogatepass"), digest_size=16).digest()


def _cut(text: str, size: int, overlap: int) -> list[tuple[int, int]]:
    """Окна по границам строк/предложений, с перекрытием, чтобы не резать сущности."""
    out, start, n = [], 0, len(text)
    while start < n:
        end = min(n, start + size)
        if end < n:
            lo = start + size // 2
            cut = max(text.rfind("\n", lo, end), text.rfind(". ", lo, end), text.rfind("; ", lo, end))
            if cut <= lo:
                cut = text.rfind(" ", lo, end)
            if cut > lo:
                end = cut + 1
        out.append((start, end))
        if end >= n:
            break
        start = max(end - overlap, start + 1)
        # начинаем окно с границы слова
        sp = text.find(" ", start, end)
        if 0 <= sp - start < 40:
            start = sp + 1
    return out

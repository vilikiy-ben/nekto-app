"""Вторая сеть: найденное однажды скрывается везде.

Модель решает по контексту и в одном абзаце узнаёт «Тен Романа Владимировича», а через абзац пропускает «Тену».
Метка же должна закрывать человека во всём документе и во всех документах обработки. Поэтому после поиска
каждый сегмент ещё раз просматривается на уже известное:
- значения с формой (телефон, почта, номер, ссылка, организация) — точным совпадением целого слова;
- люди — по фамилии в любом падеже («Козлова» → «Козлову», «Козлов») и по полному упоминанию;
- учётные записи — по имени почтового ящика («kravets.n» из «kravets.n@…») и по фамилии известного человека
  латиницей («shevchuk_la», «b.koval» рядом с Шевчук и Ковалём).

Распространяется только проверенное: фамилия берётся из упоминания, которое прошло `names.finder`, и ищется
среди слов с заглавной буквы. Раньше разносилось всё, что назвала модель, — и одно «продажников» с её оценкой 0,99
закрывало слово во всём документе.
"""
from __future__ import annotations

import re
import weakref
from functools import lru_cache
from typing import Iterable, Sequence

from . import orgs
from .kinds import Kind
from .labels import _SHARED_ACCOUNTS
from .names import finder, mention
from .names.lexicon import lookup
from .names.lexicon import morph as names_morph
from .session import Session
from .spans import Span, merge

_MIN_LEN = 3
_CAP_WORD = re.compile(r"(?<![\w-])[A-ZА-ЯЁ][a-zа-яё]+(?:-[A-ZА-ЯЁ][a-zа-яё]+)?(?![\w-])")
# Типы, где значение — свободный текст и повторная встреча того же текста — то же ПДн.
_EXACT_KINDS = {Kind.ORG, Kind.ADDRESS, Kind.EMAIL, Kind.URL, Kind.HANDLE, Kind.PASSPORT, Kind.SNILS, Kind.INN,
                Kind.ACCOUNT, Kind.CARD, Kind.PHONE, Kind.ID, Kind.OTHER, Kind.BIRTHDATE, Kind.SECRET}


class Known:
    """Известные значения: точные формы (индекс по первым трём буквам — тысячи значений обработки без регулярки
    на тысячи вариантов), фамилии людей и основы названий организаций."""

    def __init__(self) -> None:
        self.exact: dict[str, Kind] = {}                 # нижний регистр → тип
        self.by_prefix: dict[str, list[str]] = {}        # первые 3 символа → значения, длинные первыми
        self.surnames: set[str] = set()                  # ключи фамилий (`mention.surname_key`)
        self.org_stems: set[str] = set()                 # основы однословных названий организаций
        self.logins: set[str] = set()                    # фамилии латиницей (`mention.latin_key`) — для учётных записей
        self.rare: set[str] = set()                      # имена известных людей, которых нет в словаре: «фаррух»
        self._seen: set[tuple[Kind, str]] = set()
        self.entries = 0                                 # сколько записей таблицы меток уже учтено

    def add(self, kind: Kind, value: str) -> None:
        if (kind, value) in self._seen:
            return
        self._seen.add((kind, value))
        v = re.sub(r"\s+", " ", value.strip())
        if kind is Kind.PERSON:
            self._add_person(v)
            return
        if kind not in _EXACT_KINDS or len(re.sub(r"\W", "", v)) < _MIN_LEN:
            return
        if not re.search(r"[^\W\d]", v) and len(re.sub(r"\D", "", v)) < 5:
            return  # короткое число («214», «2025») встречается где угодно — не разносим
        self._add_exact(kind, v)
        if kind is Kind.EMAIL:                           # «kravets.n@…» → учётная запись «kravets.n»
            local = v.split("@")[0].lower()
            if len(local) >= 5 and local not in _SHARED_ACCOUNTS and not _SHARED_BOX.match(local):
                self._add_exact(Kind.HANDLE, local)
        if kind is Kind.ORG and (name := orgs.inner_name(v)):
            self.add(Kind.ORG, name)
            if (st := orgs.stem(name)):
                self.org_stems.add(st)

    def _add_exact(self, kind: Kind, v: str) -> None:
        low = v.lower()
        if low not in self.exact:
            self.exact[low] = kind
            bucket = self.by_prefix.setdefault(low[:3], [])
            bucket.append(low)
            bucket.sort(key=len, reverse=True)

    def _add_person(self, v: str) -> None:
        parsed = mention.parse(v)
        words = [p for p in parsed.parts if p.role != "initial"]
        if len(words) > 1:                                # полное упоминание — и точным текстом
            self._add_exact(Kind.PERSON, v)
        for part in parsed.parts:
            # фамилия — только та, что на фамилию похожа или стояла рядом с именем; одиночное слово-имя не разносим
            if part.role == "surname" and len(part.lemma) >= _MIN_LEN and (len(words) > 1 or _surname_shaped(part.text)):
                self.surnames.add(mention.surname_key(part.lemma))
                if len(key := mention.latin_key(part.lemma)) >= 4:
                    self.logins.add(key)
            elif part.role == "first" and len(words) > 1 and len(part.lemma) >= 5 and not part.text.isascii() \
                    and not lookup(part.lemma).known and not lookup(part.lemma).first:
                self.rare.add(part.lemma)                 # слово вне словаря, которое документ сам назвал именем

    def __bool__(self) -> bool:
        return bool(self.exact or self.surnames or self.org_stems or self.logins or self.rare)

    def matches(self, seg: str):
        """(начало, конец, тип) каждой встречи известного значения целым словом."""
        if not self.exact:
            return
        low = re.sub(r"\s", " ", seg.lower())
        n = len(low)
        for i in range(n):
            if low[i] == " " or (i and _word(low[i - 1]) and _word(low[i])):
                continue
            for value in self.by_prefix.get(low[i:i + 3], ()):
                end = i + len(value)
                if low.startswith(value, i) and (end == n or not (_word(low[end]) or low[end] in "@-")):
                    yield i, end, self.exact[value]
                    break


def _word(ch: str) -> bool:
    return ch.isalnum() or ch == "_"


# Общие ящики: по ним человека не найти, и как учётная запись они ничего не выдают.
_SHARED_BOX = re.compile(r"(?:info|sales|office|support|help|hello|contact|mail|admin|noreply|no-reply|hr|job|career|press|pr|"
                         r"zakaz|order|buh|bank|billing|finance|legal|security|team|dev|it|service|robot|bot|notify|"
                         r"news|reception|priem|kadry|secretar\w*|marketing|partner\w*|client\w*|feedback)\d*$")
_LOGIN = re.compile(r"(?<![\w.@/-])[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*(?![\w@-]|\.[a-z])")
_MANY_LOGINS = 300        # при тысячах людей обработки сверяем только точное совпадение


def _logins(seg: str, exact: set[str], longer: list[str]):
    """Учётные записи, собранные из фамилии известного человека: «shevchuk_la», «b.koval», «vkravets»."""
    for m in _LOGIN.finditer(seg):
        token = m.group()
        if len(token) < 5:
            continue
        parts = [p for p in re.split(r"[._\-\d]+", token) if p]
        separated = len(parts) > 1 or any(ch.isdigit() for ch in token)
        for part in parts:
            key = mention.latin_key(part)
            if (key in exact and (len(key) >= 5 or separated)) or \
                    any(k in key and len(key) - len(k) <= 2 for k in longer):
                yield m.start(), m.end()
                break


def _surname_shaped(word: str) -> bool:
    lex = lookup(word.rstrip(".").lower())
    return bool(lex.shape or lex.surname) and lex.common < 0.3


_SESSION_KNOWN: "weakref.WeakKeyDictionary[Session, Known]" = weakref.WeakKeyDictionary()


def known_values(session: Session, found: Iterable[tuple[str, list[Span]]]) -> list[Known]:
    """Значения обработки (копятся на сессию, каждая форма разбирается один раз) и найденное в этом прогоне."""
    entries = session.entries()
    stored = _SESSION_KNOWN.get(session)
    if stored is None or len(entries) < stored.entries:   # reset: таблица меток очищена — забываем и мы
        stored = _SESSION_KNOWN[session] = Known()
    stored.entries = len(entries)
    for entry in entries:
        for form in entry.forms:
            stored.add(entry.kind, form)
    batch = Known()
    for seg, spans in found:
        for sp in spans:
            batch.add(sp.kind, seg[sp.start:sp.end])
    return [stored, batch]


def extend(segments: Sequence[str], found: list[list[Span]], knowns: list[Known],
           vocabulary: finder.Vocabulary | None = None) -> list[list[Span]]:
    """Добавляет к находкам каждого сегмента встречи известных значений, которые поиск там пропустил."""
    knowns = [k for k in knowns if k]
    if not knowns:
        return found
    surnames = set().union(*(k.surnames for k in knowns))
    org_stems = set().union(*(k.org_stems for k in knowns))
    logins = set().union(*(k.logins for k in knowns))
    longer = [k for k in logins if len(k) >= 6] if len(logins) <= _MANY_LOGINS else []
    rare = set().union(*(k.rare for k in knowns))
    vocabulary = vocabulary or finder.Vocabulary()
    out = []
    for seg, spans in zip(segments, found):
        extra: list[Span] = []
        for known in knowns:
            for start, end, kind in known.matches(seg):
                text = seg[start:end]
                if kind in (Kind.PERSON, Kind.ORG) and not text[:1].isupper():
                    continue
                if not _covered(spans, start, end) and not _covered(extra, start, end):
                    extra.append(Span(start, end, kind, 1.0, "known"))
        if org_stems:
            for m in _CAP_WORD.finditer(seg):
                if _covered(spans, m.start(), m.end()) or _covered(extra, m.start(), m.end()):
                    continue
                low = m.group().lower()
                if any(low.startswith(st) and len(low) - len(st) <= 3 for st in org_stems):
                    extra.append(Span(m.start(), m.end(), Kind.ORG, 1.0, "known"))  # «Сибмеди»
        if surnames:
            for t in finder.tokens(seg):
                if t.cap == 0 or t.initial or t.abbreviation or t.mixed or len(t.text) < _MIN_LEN:
                    continue
                if _covered(spans, t.start, t.end) or _covered(extra, t.start, t.end):
                    continue
                if not _surname_keys(t.low) & surnames:
                    continue
                if t.cap == 1 and (t.low in vocabulary or _describes_next(seg, t)):
                    continue                              # слово, которое документ пишет строчными; «Толстая стена»
                extra.append(Span(t.start, t.end, Kind.PERSON, 1.0, "known"))
        if rare or (logins and re.search(r"[A-Z][a-z]{4}", seg)):
            for t in finder.tokens(seg):
                if t.initial or len(t.text) < 5 or _covered(spans, t.start, t.end) or _covered(extra, t.start, t.end):
                    continue
                if t.latin:                                   # «Give Bondar a raise» рядом с Бондарем
                    if t.cap >= 1 and not t.upper and logins and mention.latin_key(t.low) in logins:
                        extra.append(Span(t.start, t.end, Kind.PERSON, 1.0, "known"))
                elif any(t.low.startswith(name) and len(t.low) - len(name) <= 2 for name in rare):
                    extra.append(Span(t.start, t.end, Kind.PERSON, 1.0, "known"))   # «а фаррух где жить будет?»
        if logins and re.search(r"[a-z]{4}", seg):
            for start, end in _logins(seg, logins, longer):
                if not _covered(spans, start, end) and not _covered(extra, start, end) \
                        and not any(s.start < end and start < s.end for s in spans):
                    extra.append(Span(start, end, Kind.HANDLE, 1.0, "known"))
        out.append(merge(spans + extra) if extra else spans)
    return out


# Заголовок реплики в выгрузке мессенджера: «Daniyar Seitkali  10:07», «Белый Стас 10:31» — имя и время на всю строку.
_HEADER = re.compile(r"^\s*([A-ZА-ЯЁ][\w'’-]+(?: [A-ZА-ЯЁ][\w'’-]+){0,2})\s{1,3}\[?\d{1,2}:\d{2}(?::\d{2})?\]?\s*$")
_SPEAKER = re.compile(r"^\s*(?:\[[\d:., ]+\]\s*|\d{1,2}:\d{2}\s+)?([A-ZА-ЯЁa-zа-яё][a-zа-яё]+(?: [A-ZА-ЯЁ][a-zа-яё]+)?):\s")


def speakers(segments: Sequence[str], found: list[list[Span]]) -> list[list[Span]]:
    """Автор реплики в переписке: «[10:42] Злата: привет». Имя в начале строки для поиска — слабое свидетельство
    («Злата» — ещё и слово), а повтор метки-автора — сильное: человек, если строк с ней хотя бы две и это имя или
    фамилия (не «Тема:», «Фамилия:», «Итог:»)."""
    counts: dict[str, int] = {}
    for seg in segments:
        m = _SPEAKER.match(seg)
        if m:
            counts[m.group(1)] = counts.get(m.group(1), 0) + 1
    names_ok = {w for w, n in counts.items() if n >= 2 and all(_name_like(x) for x in w.split())}
    headers = [_HEADER.match(seg) for seg in segments]
    if sum(1 for h in headers if h) < 2:                  # одна такая строка — ещё не выгрузка переписки
        headers = [None] * len(segments)
    if not names_ok and not any(headers):
        return found
    out = []
    for seg, spans, header in zip(segments, found, headers):
        m = _SPEAKER.match(seg)
        if m and m.group(1) in names_ok and not _covered(spans, m.start(1), m.end(1)):
            spans = merge(spans + [Span(m.start(1), m.end(1), Kind.PERSON, 1.0, "known")])
        if header and _header_name(header.group(1)) and not _covered(spans, header.start(1), header.end(1)):
            spans = merge([s for s in spans if not (header.start(1) <= s.start and s.end <= header.end(1))]
                          + [Span(header.start(1), header.end(1), Kind.PERSON, 1.0, "known")])
        out.append(spans)
    return out


def _header_name(name: str) -> bool:
    words = name.split()
    if any(w.lower() in finder._NOT_NAMES for w in words):
        return False
    if all(w.isascii() for w in words):                   # латиницей: словарь имён тут почти не помогает
        return len(words) == 2 or bool(lookup(words[0].lower()).first)
    return any(_name_like(w) for w in words)


def _describes_next(seg: str, t) -> bool:
    """Прилагательное в начале фразы согласовано со следующим существительным — это определение, а не фамилия:
    «Толстая стена старой подстанции» рядом с сотрудницей Толстой."""
    m = re.match(r" ([а-яё]{3,})", seg[t.end:t.end + 24])
    if not m:
        return False
    morph = names_morph()
    for a in morph.parse(t.low):
        if not a.is_known or a.tag.POS != "ADJF":
            continue
        for n in morph.parse(m.group(1)):
            if n.is_known and n.tag.POS == "NOUN" and n.tag.case == a.tag.case and n.tag.number == a.tag.number \
                    and (a.tag.number == "plur" or n.tag.gender == a.tag.gender):
                return True
    return False


@lru_cache(maxsize=20_000)
def _name_like(word: str) -> bool:
    low = word.lower()
    if low in finder._NOT_NAMES:
        return False
    lex = lookup(low)
    if word[:1].islower():                 # «марина: привет» — строчными автор-имя, но не «итог:» и не «продажник:»
        return lex.first and not lex.ambiguous_first
    # имя или фамилия по словарю; слово вне словаря («Продакт:», «Зульфат:») оставляем поиску с моделью
    return lex.first or ((lex.surname or bool(lex.shape)) and lex.common < 0.3)


def _covered(spans: list[Span], start: int, end: int) -> bool:
    return any(s.start <= start and end <= s.end for s in spans)


@lru_cache(maxsize=50_000)
def _surname_keys(low: str) -> frozenset[str]:
    return frozenset(mention.surname_key(r.lemma) for r in mention.surname_readings(low))

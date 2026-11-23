"""Сессия обезличивания (в приложении — одна «обработка»): согласованные метки [ТИП_n] и таблица соответствий.

Одно и то же значение в любом файле обработки получает одну и ту же метку:
телефон «8 900 555-01-48» и «+79005550148» → [ТЕЛЕФОН_1]; «Ахмерова Г. И.» и
«Гульнара Ахмерова» → [ФИО_1]. Таблица соответствий нужна приложению, чтобы вернуть
исходные данные в ответ нейросети. Сам движок на диск её не пишет: приложение получает
состояние через `to_state()` и хранит его в рабочей папке пользователя, а при следующем
запуске возвращает через `from_state()`.
"""
from __future__ import annotations

import re
import threading
import unicodedata
from dataclasses import dataclass, field

from . import names, orgs
from .names import registry
from .kinds import OPT_IN, Kind
from .rules import only_digits
from .spans import Span, merge

PLACEHOLDER_RE = re.compile(r"\[(?P<kind>[A-ZА-ЯЁ]+)_(?P<n>\d+)\]")


@dataclass
class Entry:
    placeholder: str
    kind: Kind
    original: str                     # каноническая (самая полная) форма
    variants: list[str] = field(default_factory=list)
    person: names.Person | None = None

    @property
    def forms(self) -> list[str]:
        return self.variants + [self.original]

    def to_json(self, allowed: bool = False) -> dict:
        return {"placeholder": self.placeholder, "kind": self.kind.value, "original": self.original,
                "variants": self.variants[:20], "allowed": allowed}


def normalize(kind: Kind, value: str) -> str:
    v = unicodedata.normalize("NFC", value).strip()
    if kind in (Kind.PHONE,):
        d = only_digits(v)
        if len(d) == 11 and d[0] in "78":
            d = "7" + d[1:]
        return d
    if kind in (Kind.CARD, Kind.ACCOUNT, Kind.INN, Kind.SNILS, Kind.PASSPORT):
        return only_digits(v) or v.lower()
    if kind in (Kind.EMAIL, Kind.URL, Kind.HANDLE, Kind.IP, Kind.MAC):
        return v.lower()
    if kind is Kind.ORG:
        return orgs.key(v)
    return re.sub(r"[\W_]+", " ", v.lower().replace("ё", "е")).strip()


class Session:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._entries: list[Entry] = []
        self._by_key: dict[tuple[Kind, str], Entry] = {}
        self._by_placeholder: dict[str, Entry] = {}
        self._counters: dict[Kind, int] = {}
        # Ручные правки пользователя действуют на всю сессию и переживают повторную обработку:
        self._forced: dict[str, tuple[str, Kind]] = {}  # «скрыть», что модель пропустила
        self._allowed: set[str] = set()                  # «не скрывать» ложное срабатывание
        # Типы, которые пользователь решил не скрывать во всей обработке (например, даты).
        self.keep: set[Kind] = set()
        # Типы, которые по умолчанию видны, а пользователь решил скрывать (организации, kinds.OPT_IN).
        self.hide: set[Kind] = set()

    # ---------- публичное ----------

    def reset(self) -> None:
        with self._lock:
            self._entries.clear(); self._by_key.clear(); self._by_placeholder.clear(); self._counters.clear()
            self._forced.clear(); self._allowed.clear(); self.keep.clear(); self.hide.clear()

    def set_keep(self, kinds: set[Kind]) -> None:
        with self._lock:
            self.keep = set(kinds)

    def set_hide(self, kinds: set[Kind]) -> None:
        with self._lock:
            self.hide = set(kinds) & OPT_IN

    # ---------- сохранение ----------

    def to_state(self) -> dict:
        """Полное состояние: всё, что нужно, чтобы продолжить обработку после перезапуска."""
        with self._lock:
            return {
                "version": 1,
                "entries": [{"placeholder": e.placeholder, "kind": e.kind.value, "original": e.original,
                             "variants": list(e.variants)} for e in self._entries],
                "forced": [{"text": t, "kind": k.value} for t, k in self._forced.values()],
                "allowed": sorted(self._allowed),
                "keep": sorted(k.value for k in self.keep),
                "hide": sorted(k.value for k in self.hide),
            }

    @classmethod
    def from_state(cls, state: dict) -> "Session":
        s = cls()
        by_value = {k.value: k for k in Kind}
        for raw in state.get("entries", []):
            kind = by_value.get(raw.get("kind"), Kind.OTHER)
            entry = Entry(placeholder=raw["placeholder"], kind=kind, original=raw["original"],
                          variants=list(raw.get("variants") or []))
            forms = entry.variants + [entry.original]
            if kind is Kind.PERSON:
                entry.person = names.Person()
                for v in forms:
                    entry.person.absorb(names.parse(v).person)
            for v in forms:
                if kind is not Kind.PERSON or _cacheable(names.parse(v).person):
                    s._by_key.setdefault((kind, normalize(kind, v)), entry)
            s._entries.append(entry)
            s._by_placeholder[entry.placeholder] = entry
            m = PLACEHOLDER_RE.fullmatch(entry.placeholder)
            if m:
                s._counters[kind] = max(s._counters.get(kind, 0), int(m.group("n")))
        for f in state.get("forced", []):
            key = _override_key(f.get("text", ""))
            if key:
                s._forced[key] = (f["text"], by_value.get(f.get("kind"), Kind.OTHER))
        s._allowed = set(state.get("allowed", []))
        s.keep = {by_value[k] for k in state.get("keep", []) if k in by_value}
        s.hide = {by_value[k] for k in state.get("hide", []) if k in by_value} & OPT_IN
        return s

    # ---------- ручные правки ----------

    def force(self, text: str, kind: Kind = Kind.OTHER) -> None:
        key = _override_key(text)
        if key:
            with self._lock:
                self._forced[key] = (unicodedata.normalize("NFC", text).strip(), kind)
                self._allowed.discard(key)
                # «Скрыть» одну форму снятого значения — значит снова скрывать его целиком.
                for e in self._entries:
                    if any(_override_key(v) == key for v in e.forms):
                        for v in e.forms:
                            self._allowed.discard(_override_key(v))

    def unforce(self, text: str) -> None:
        with self._lock:
            self._forced.pop(_override_key(text), None)

    def allow(self, placeholder: str) -> None:
        """Не скрывать значение (и все его формы) — модель ошиблась.

        Ручное «скрыть» при этом остаётся в сессии: «не скрывать» сильнее его (`adjust`), а снова поставленная
        галочка (`unallow`) возвращает значение под метку, даже если модель его не находит."""
        with self._lock:
            for e in self._entries:
                if e.placeholder == placeholder:
                    for v in e.forms:
                        self._allowed.add(_override_key(v))

    def unallow(self, placeholder: str) -> None:
        with self._lock:
            for e in self._entries:
                if e.placeholder == placeholder:
                    for v in e.forms:
                        self._allowed.discard(_override_key(v))

    def is_allowed(self, value: str) -> bool:
        return _override_key(value) in self._allowed

    def adjust(self, segment: str, spans: list[Span]) -> list[Span]:
        """Применяет правки пользователя и режимы обработки к найденному в сегменте."""
        if self.keep or OPT_IN - self.hide:
            spans = [sp for sp in spans if sp.kind not in self.keep and (sp.kind not in OPT_IN or sp.kind in self.hide)]
        if not self._forced and not self._allowed:
            return spans
        kept = [sp for sp in spans if not self.is_allowed(segment[sp.start:sp.end])]
        low = unicodedata.normalize("NFC", segment).lower()
        for key, (_, kind) in list(self._forced.items()):
            if key in self._allowed:
                continue
            # целым словом: «Скрыть» для «Ким» не должно резать «Акимов» и «Кимберли»
            for m in re.finditer(r"(?<!\w)" + re.escape(key) + r"(?!\w)", low):
                kept.append(Span(m.start(), m.end(), kind, 1.0, "user"))
        return merge(kept)

    def entries(self) -> list[Entry]:
        with self._lock:
            return list(self._entries)

    def bind(self, segments: list[str] | tuple[str, ...], found: list[list[Span]],
             scopes: list | None = None) -> list[list[Span]]:
        """Решает, кто есть кто среди найденных ФИО, и записывает метку в спан (`Span.ref`).

        Делается по всему набору сегментов сразу: сначала полные упоминания («Абдуллина Елена»), потом короткие
        («Лене») — иначе результат зависел бы от порядка строк. `scopes[i]` — область сегмента (`names.registry`):
        одно имя без фамилии привязывается к человеку только внутри своей области. Нет `scopes` — область одна."""
        with self._lock:
            items = []
            for i, (seg, spans) in enumerate(zip(segments, found)):
                for j, sp in enumerate(spans):
                    if sp.kind is Kind.PERSON and sp.ref is None:
                        value = seg[sp.start:sp.end]
                        if not PLACEHOLDER_RE.fullmatch(value):
                            items.append((i, j, value, names.parse(value), scopes[i] if scopes else None))
            if not items:
                return found
            refs: dict[tuple[int, int], str] = {}
            nearby: dict[object, list[Entry]] = {}
            for k in sorted(range(len(items)), key=lambda k: (-registry.rank(items[k][3].person), k)):
                i, j, value, mention, scope = items[k]
                people = nearby.setdefault(scope, [])
                entry = self._person(value, mention, people)
                if entry not in people:
                    people.append(entry)
                refs[(i, j)] = entry.placeholder
            return [[Span(sp.start, sp.end, sp.kind, sp.score, sp.source, refs.get((i, j), sp.ref))
                     for j, sp in enumerate(spans)] for i, spans in enumerate(found)]

    def placeholder(self, kind: Kind, value: str, ref: str | None = None) -> str:
        """Метка для значения. Если значение — новая форма снятого (не скрываемого) значения, форма тоже
        не скрывается и возвращается как есть: строка в панели снята — в тексте не должно появиться метки."""
        with self._lock:
            entry = self._by_placeholder.get(ref) if ref else None
            if entry is None or entry.kind is not kind:
                entry = self._resolve(kind, value)
            if value not in entry.variants:
                entry.variants.append(value)
                if entry.kind is not Kind.PERSON and len(value) > len(entry.original):
                    entry.original = value
            if self._is_entry_allowed(entry):
                self._allowed.add(_override_key(value))
                return value
            return entry.placeholder

    def apply(self, text: str, spans: list[Span]) -> str:
        """Заменяет спаны метками. Спаны не должны пересекаться (см. spans.merge)."""
        out, pos = [], 0
        for sp in sorted(spans, key=lambda s: s.start):
            if sp.start < pos:
                continue
            value = text[sp.start:sp.end]
            if PLACEHOLDER_RE.fullmatch(value):  # уже обезличено (повторная обработка)
                continue
            out.append(text[pos:sp.start])
            out.append(self.placeholder(sp.kind, value, sp.ref))
            pos = sp.end
        out.append(text[pos:])
        return "".join(out)

    def mapping(self) -> list[dict]:
        with self._lock:
            # Снятым значение считается целиком: каноническая форма может смениться, когда найдётся более полная.
            return [e.to_json(allowed=self._is_entry_allowed(e)) for e in self._entries]

    # ---------- внутреннее ----------

    def _is_entry_allowed(self, entry: Entry) -> bool:
        return any(self.is_allowed(v) for v in entry.forms)

    def _resolve(self, kind: Kind, value: str) -> Entry:
        if kind is Kind.PERSON:
            return self._person(value, names.parse(value), [])
        key = (kind, normalize(kind, value))
        entry = self._by_key.get(key)
        if entry is None:
            entry = self._new(kind, value)
            self._by_key[key] = entry
        return entry

    def _person(self, value: str, mention: names.Mention, nearby: list[Entry]) -> Entry:
        """Запись человека для упоминания: уже известная (`registry.choose`) или новая."""
        exact = (Kind.PERSON, normalize(Kind.PERSON, value))
        cacheable = _cacheable(mention.person)       # одно имя зависит от области — по тексту его не запоминаем
        if cacheable and exact in self._by_key:
            return self._by_key[exact]
        people = [e for e in self._entries if e.kind is Kind.PERSON]
        entry = registry.choose(mention, people, nearby)
        if entry is None:
            entry = self._new(Kind.PERSON, mention.nominative)
            entry.person = names.Person()
        if mention.person.words > entry.person.words:     # более полное упоминание — новая начальная форма
            entry.original = mention.nominative
        entry.person.absorb(mention.person)
        if cacheable:
            self._by_key[exact] = entry
        return entry

    def _new(self, kind: Kind, value: str) -> Entry:
        n = self._counters.get(kind, 0) + 1
        self._counters[kind] = n
        entry = Entry(placeholder=f"[{kind.tag}_{n}]", kind=kind, original=value)
        self._entries.append(entry)
        self._by_placeholder[entry.placeholder] = entry
        return entry


def _cacheable(person: names.Person) -> bool:
    return bool(person.surnames or person.latin and not person.firsts)


def _override_key(text: str) -> str:
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", text).strip().lower())

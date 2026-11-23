"""Упоминание человека: кто есть кто в «Сафонову Веронику» и как это звучит в именительном падеже.

Каждое слово упоминания получает роль (имя, отчество, фамилия, инициал) и набор прочтений «начальная форма + род +
падеж». Из них выбирается сочетание, где все слова согласованы между собой — как в живой фразе: «Жене Ольшанской» —
это дательный женского («Женя Ольшанская»), а не «Жене Ольшанский». Если согласовать нельзя («Ярославу Сковороду» —
опечатка), слово остаётся как написано: придуманная форма хуже исходной, потому что именно начальная форма
возвращается в ответ нейросети.

По разобранному упоминанию строится `Person` — то, по чему упоминания склеиваются в одного человека (`registry`).
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from functools import lru_cache
from itertools import product

from .lexicon import Reading, full_names, lookup, morph, patr_key

_HONORIFICS = {"г-н", "г-жа", "господин", "госпожа", "гражданин", "гражданка", "тов", "товарищ", "mr", "mrs", "ms",
               "miss", "dr", "prof", "herr", "frau", "sir", "madam", "мистер", "миссис", "доктор"}
_TOKEN = re.compile(r"[^\W\d_]+(?:[-'’][^\W\d_]+)*\.?")
_CYRILLIC = re.compile(r"[а-яё]", re.IGNORECASE)

_TRANSLIT = str.maketrans({
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "i",
    "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f",
    "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
})


def latin_key(word: str) -> str:
    """Грубый ключ для сравнения кириллицы и латиницы: NURIEVA ~ нуриева."""
    w = word.lower().translate(_TRANSLIT)
    for a, b in (("kh", "h"), ("yu", "u"), ("ya", "a"), ("iu", "u"), ("ia", "a"), ("y", "i"), ("j", "i"),
                 ("ts", "c"), ("tz", "c"), ("w", "v"), ("ph", "f"), ("sch", "sh")):
        w = w.replace(a, b)
    return re.sub(r"[^a-z]", "", w)


# ---------- фамилия: прочтения по форме ----------

_POSSESSIVE = re.compile(r"^(.{2,}(?:ов|ев|ёв|ин|ын))(а|у|ым|е|ой|ых|ыми|ы)?$")
_ADJECTIVAL = re.compile(r"^(.{2,}(?:ск|цк))(ий|ой|ая|ого|ому|им|ом|ую|ие|их|ими)$")
_INDECLINABLE = re.compile(r"(?:енко|ейко|ко|ых|их|швили|дзе|[оэ])$")
_ALL = (None,)


@lru_cache(maxsize=50_000)
def surname_readings(low: str) -> tuple[Reading, ...]:
    """Возможные «начальная форма + род + падеж» для слова в роли фамилии."""
    if "-" in low.strip("-"):                           # двойная фамилия: части согласованы между собой
        halves = [surname_readings(h) for h in low.split("-") if h]
        joined = [Reading("-".join(r.lemma for r in combo), next((r.gender for r in combo if r.gender), None),
                          next((r.case for r in combo if r.case), None), min(r.weight for r in combo))
                  for combo in product(*halves)
                  if len({r.gender for r in combo if r.gender}) <= 1 and len({r.case for r in combo if r.case}) <= 1]
        return tuple(joined[:24]) or (Reading(low, None, None),)
    out: list[Reading] = []

    def add(lemma: str, gender: str | None, cases, weight: float = 1.0) -> None:
        for case in cases:
            out.append(Reading(lemma, gender, case, weight))

    m = _POSSESSIVE.match(low)
    if m:
        stem, end = m.group(1), m.group(2) or ""
        if end == "":
            add(stem, "masc", ("nomn",))
        elif end == "а":
            add(stem, "masc", ("gent", "accs"))
            add(stem + "а", "femn", ("nomn",))
        elif end == "у":
            add(stem, "masc", ("datv",))
            add(stem + "а", "femn", ("accs",))
        elif end == "ым":
            add(stem, "masc", ("ablt",))
        elif end == "е":
            add(stem, "masc", ("loct",))
        elif end == "ой":
            add(stem + "а", "femn", ("gent", "datv", "ablt", "loct"))
        else:                                           # «Фоминых Наталья» — фамилия на -ых; «Ивановых» — семья
            if end == "ых":
                add(low, None, _ALL, 0.8)
            add(stem, None, _ALL, 0.3)
    m = _ADJECTIVAL.match(low)
    if m:
        stem, end = m.group(1), m.group(2)
        masc = stem + "ий"
        if end in ("ий",):
            add(masc, "masc", ("nomn",))
        elif end == "ой":
            add(stem + "ая", "femn", ("gent", "datv", "ablt", "loct"))
            add(stem + "ой", "masc", ("nomn",), 0.4)     # Трубецкой
        elif end == "ая":
            add(stem + "ая", "femn", ("nomn",))
        elif end == "ого":
            add(masc, "masc", ("gent", "accs"))
        elif end == "ому":
            add(masc, "masc", ("datv",))
        elif end == "им":
            add(masc, "masc", ("ablt",))
        elif end == "ом":
            add(masc, "masc", ("loct",))
        elif end == "ую":
            add(stem + "ая", "femn", ("accs",))
        else:
            add(masc, None, _ALL, 0.5)
    if out:
        return tuple(out)
    # Фамилии-прилагательные вне -ский: Белый, Толстой, Задорожный, Гладкая
    for p in morph().parse(low):
        if p.is_known and p.tag.POS == "ADJF" and p.tag.number == "sing" and p.tag.gender in ("masc", "femn"):
            form = p.inflect({"nomn", "sing", p.tag.gender})
            case = p.tag.case if p.tag.case in ("nomn", "gent", "datv", "accs", "ablt", "loct") else None
            if form and case:
                add(form.word, p.tag.gender, (case,), 0.8)
    if out:
        return tuple(out)
    if _INDECLINABLE.search(low):                       # Шевченко, Долгих, Нино, Гёте
        add(low, None, _ALL)
        return tuple(out)
    # В живом тексте несловарную фамилию часто не склоняют вовсе: «Константина Иволга», «Тен Романа», «Саркисян Армену».
    # Слово, которое словарь знает в именительном падеже, скорее всего так и стоит.
    dictionary_nominative = any(p.is_known and p.tag.case == "nomn" and p.tag.number == "sing" for p in morph().parse(low))
    add(low, None, _ALL, 0.9 if dictionary_nominative else 0.45)
    # Фамилии-существительные на -а/-я (Иволга, Кочерга, Кобза): склоняются у мужчин и женщин одинаково
    if low[-1] in "ая":
        add(low, None, ("nomn",))
    stem = low[:-1]
    if len(stem) >= 3:
        soft = "я" if (low[-1] in "иею" and stem[-1] not in "гкхжшчщц") else "а"
        if low[-1] in "ыи":
            add(stem + soft, None, ("gent",), 0.5)
        elif low[-1] == "е":
            add(stem + "а", None, ("datv", "loct"), 0.5)
        elif low[-1] in "ую":
            add(stem + ("я" if low[-1] == "ю" else "а"), None, ("accs",), 0.5)
    if low.endswith(("ой", "ей")) and len(low) >= 5:
        add(low[:-2] + ("а" if low.endswith("ой") else "я"), None, ("ablt",), 0.4)
    # Фамилии на согласный (Юшкевич, Саркисян, Ким, Лисий): у мужчин склоняются, у женщин — нет
    if low[-1] not in "аеёиоуыэюя":
        add(low, "masc", ("nomn",))
        add(low, "femn", _ALL, 0.9)
    # «Саркисяну» → «Саркисян». Но «Сковороду» — форма словарного слова «сковорода», а не фамилии «Сковород».
    lemmas = {p.normal_form for p in morph().parse(low) if p.is_known}
    for ending, cases in (("а", ("gent", "accs")), ("у", ("datv",)), ("ом", ("ablt",)), ("ем", ("ablt",)), ("е", ("loct",))):
        if low.endswith(ending) and len(low) - len(ending) >= 3 and low[-len(ending) - 1] not in "аеёиоуыэюя" \
                and (not lemmas or low[:-len(ending)] in lemmas):
            add(low[:-len(ending)], "masc", cases, 0.6)
    for ending, cases in (("я", ("gent", "accs")), ("ю", ("datv",)), ("ем", ("ablt",)), ("е", ("loct",))):
        if low.endswith(ending) and len(low) - len(ending) >= 2 and low[-len(ending) - 1] in "аеёиоуыэюя":
            add(low[:-len(ending)] + "й", "masc", cases, 0.4)   # Бабия → Лисий, Тену → Тен
    return tuple(out)


def surname_key(lemma: str) -> str:
    """Один ключ на мужскую и женскую форму: «иванов» и «иванова», «ольшанский» и «ольшанская»."""
    low = lemma.lower().replace("ё", "е")
    m = re.match(r"^(.{2,}(?:ов|ев|ин|ын))а?$", low)
    if m:
        return m.group(1)
    m = re.match(r"^(.{2,}(?:ск|цк))(?:ий|ая|ой)$", low)
    if m:
        return m.group(1)
    m = re.match(r"^(.{3,})(?:ый|ий|ой|ая|яя)$", low)
    if m and any(p.is_known and p.tag.POS == "ADJF" for p in morph().parse(low)):
        return m.group(1)
    return low


# ---------- разбор упоминания ----------

@dataclass(frozen=True, slots=True)
class Part:
    text: str                       # как в тексте
    role: str                       # first | patr | surname | initial | other
    lemma: str                      # начальная форма в нижнем регистре (для initial — буква)


@dataclass
class Person:
    """Что известно о человеке из упоминаний — по этому упоминания склеиваются."""
    surnames: set[str] = field(default_factory=set)        # ключи фамилий
    surname_alts: set[str] = field(default_factory=set)    # те же фамилии во всех прочтениях: «Тену» → «цою», «цой»
    firsts: set[str] = field(default_factory=set)          # имена, включая полные формы уменьшительных
    first_lemmas: set[str] = field(default_factory=set)    # имена как названы («наташа», «наталья»)
    patrs: set[str] = field(default_factory=set)
    initials: tuple[str, ...] = ()                         # инициалы без имени: («г», «и»)
    gender: str | None = None
    latin: set[str] = field(default_factory=set)           # латинские ключи слов (для «NURIEVA GUZEL»)
    words: int = 0                                         # сколько слов-ролей было в самом полном упоминании

    @property
    def bare_first(self) -> bool:
        """Только имя (возможно, с отчеством) — без фамилии."""
        return bool(self.firsts) and not self.surnames

    def absorb(self, other: "Person") -> None:
        self.surnames |= other.surnames
        self.surname_alts |= other.surname_alts
        self.firsts |= other.firsts
        self.first_lemmas |= other.first_lemmas
        self.patrs |= other.patrs
        self.initials = self.initials or other.initials
        self.gender = self.gender or other.gender
        self.latin |= other.latin
        self.words = max(self.words, other.words)


@dataclass(frozen=True)
class Mention:
    text: str
    parts: tuple[Part, ...]
    nominative: str                 # упоминание в именительном падеже, порядок слов — как в тексте
    person: Person


def _split(text: str) -> list[str]:
    out = []
    for m in _TOKEN.finditer(unicodedata.normalize("NFC", text)):
        token = m.group()
        if token.lower().strip(".") in _HONORIFICS:
            continue
        if re.fullmatch(r"(?:[^\W\d_]\.){2,3}", token):          # «Г.И.» одним куском
            out.extend(ch + "." for ch in token if ch != ".")
        else:
            out.append(token)
    return out


def _is_initial(token: str) -> bool:
    core = token.rstrip(".")
    return len(core) == 1 and core.isalpha() and (core.isupper() or token.endswith("."))


@lru_cache(maxsize=50_000)
def parse(text: str) -> Mention:
    """Разбирает упоминание, уже признанное человеком (`finder`), на роли и начальные формы."""
    tokens = _split(text)
    if tokens and not any(_CYRILLIC.search(t) for t in tokens):
        return _parse_latin(text, tokens)
    roles = _roles(tokens)
    options: list[tuple[Reading, ...]] = []
    for token, role in zip(tokens, roles):
        low = token.rstrip(".").lower()
        lex = lookup(low)
        if role == "first":
            options.append(lex.firsts)
        elif role == "patr":
            options.append(lex.patrs)
        elif role == "surname":
            options.append(surname_readings(low))
        else:
            options.append((Reading(low, None, None),))
    chosen = _agree(options, roles)
    parts, shown = [], []
    for token, role, reading in zip(tokens, roles, chosen):
        core = token.rstrip(".")
        if role == "initial":
            parts.append(Part(token, role, core.lower()))
            shown.append(core.upper() + ".")
            continue
        lemma = reading.lemma if reading else core.lower()
        parts.append(Part(token, role, lemma))
        shown.append(_like(core, lemma) if reading else core)
    person = Person(words=sum(r != "initial" for r in roles))
    for part in parts:
        if part.role == "first":
            person.first_lemmas.add(part.lemma.replace("ё", "е"))
            person.firsts |= full_names(part.lemma)
        elif part.role == "patr":
            person.patrs.add(patr_key(part.lemma))
        elif part.role == "surname":
            person.surnames.add(surname_key(part.lemma))
            person.surname_alts |= {surname_key(r.lemma) for r in surname_readings(part.text.rstrip(".").lower())}
    person.surname_alts |= person.surnames
    person.initials = tuple(p.lemma for p in parts if p.role == "initial")
    # род — по имени и отчеству; по одной фамилии — только если иначе её не прочесть («Ивановой», но не «Шубина»)
    genders = {r.gender for r, role in zip(chosen, roles) if r and r.gender and role in ("first", "patr")}
    if not genders and "first" not in roles and "patr" not in roles:
        for token, role in zip(tokens, roles):
            if role == "surname":
                genders |= {r.gender for r in surname_readings(token.rstrip(".").lower())}
        genders = genders if None not in genders else set()
    person.gender = genders.pop() if len(genders) == 1 else None
    person.latin = {latin_key(p.lemma) for p in parts if p.role in ("first", "surname")} - {""}
    return Mention(text, tuple(parts), " ".join(shown), person)


def _roles(tokens: list[str]) -> list[str]:
    """Роли слов: одно имя, одно отчество, остальное — фамилия. Если именем может быть несколько слов
    («Борис Абрамович», «Мартин Роман»), имя — то, что на имя похоже больше, а фамилия — по форме."""
    roles = ["other"] * len(tokens)
    scores = []
    for i, token in enumerate(tokens):
        low = token.rstrip(".").lower()
        if _is_initial(token):
            roles[i] = "initial"
            scores.append(-1.0)
            continue
        lex = lookup(low)
        roles[i] = "surname"
        score = sum(r.weight for r in lex.firsts) if lex.firsts else -1.0
        if lex.shape in ("ov", "sky", "enko", "ih", "uk", "yan"):
            score -= 0.6                                  # «Сафонову Веронику»: Сафонову — фамилия по форме
        scores.append(score)
    named = [i for i, r in enumerate(roles) if r == "surname"]
    # отчество — последнее слово с таким прочтением; перед именем оно стоять не может («Абрамович Роман» — фамилия)
    patr = next((i for i in reversed(named) if lookup(tokens[i].rstrip(".").lower()).patrs), None)
    if patr is not None and (len(named) == 1 or any(lookup(tokens[i].rstrip(".").lower()).firsts for i in named if i < patr)):
        roles[patr] = "patr"
        named.remove(patr)
    else:
        patr = None
    firsts = [i for i in named if scores[i] > -1.0 + 1e-9 and lookup(tokens[i].rstrip(".").lower()).firsts]
    if firsts:
        best = max(firsts, key=lambda i: (scores[i], -i))
        if len(named) == 1 or scores[best] > 0 or len(firsts) == len(named):
            roles[best] = "first"
    return roles


def _agree(options: list[tuple[Reading, ...]], roles: list[str]) -> list[Reading | None]:
    """Выбирает прочтения, согласованные по роду и падежу. Нет согласия — слово остаётся как написано (None)."""
    slots = [i for i, opts in enumerate(options) if roles[i] != "initial" and opts]
    if not slots:
        return [None] * len(options)
    limited = [sorted(options[i], key=lambda r: -r.weight)[:10] for i in slots]
    out: list[Reading | None] = [None] * len(options)
    # сначала полное согласие (род и падеж); если слова стоят в разных падежах («Федотовой Ульяна») — только род
    for strict in (True, False):
        best, best_score = None, -1e9
        for combo in product(*limited):
            cases = {r.case for r in combo if r.case}
            genders = {r.gender for r in combo if r.gender}
            if len(genders) > 1 or (strict and len(cases) > 1):
                continue
            score = sum(min(r.weight, 2.0) for r in combo)
            if cases == {"nomn"} or not cases:
                score += 0.35                               # при прочих равных — как написано
            if score > best_score:
                best, best_score = combo, score
        if best is not None:
            for i, r in zip(slots, best):
                out[i] = r
            return out
    # Согласовать нельзя: уверенно приводим только имя и отчество, фамилию не трогаем
    for i in slots:
        if roles[i] in ("first", "patr"):
            top = sorted(options[i], key=lambda r: -r.weight)
            if len({r.lemma for r in top}) == 1:
                out[i] = top[0]
    return out


def _like(sample: str, lemma: str) -> str:
    """Начальная форма в регистре исходного слова: «ИВАНОВА» → «ИВАНОВ», «Саше» → «Саша»."""
    if sample.isupper() and len(sample) > 1:
        return lemma.upper()
    parts = lemma.split("-")
    return "-".join(p[:1].upper() + p[1:] for p in parts) if sample[:1].isupper() else lemma


def _parse_latin(text: str, tokens: list[str]) -> Mention:
    """Латиница: порядок слов ненадёжен (NURIEVA GUZEL / Guzel Nurieva), падежей нет — храним «мешок» слов."""
    parts = tuple(Part(t, "initial" if _is_initial(t) else "other", t.rstrip(".").lower()) for t in tokens)
    person = Person(words=sum(p.role != "initial" for p in parts))
    person.latin = {latin_key(p.lemma) for p in parts if p.role == "other"} - {""}
    person.initials = tuple(p.lemma for p in parts if p.role == "initial")
    return Mention(text, parts, text.strip(), person)


def nominative(text: str) -> str:
    """«Нурлыгаянова Рамиля Фаритовича» → «Нурлыгаянов Рамиль Фаритович»."""
    return parse(text).nominative

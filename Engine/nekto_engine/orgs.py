"""Организации — только в режиме «Скрывать организации» (`configure hide: ["ОРГ"]`).

По умолчанию названия компаний не скрываются: это не ПДн, и без них нейросеть теряет смысл документа (кто заказчик,
кто подрядчик). Режим — для случаев, когда в чат нельзя отдавать и названия клиентов.

Модель здесь не помогает: у неё нет класса организаций (у прежней, gliner2, на любую метку вроде «организация»
находились люди). Поэтому только то, что видно по самому тексту:
- форма собственности + название: ПАО «Сибмедь», ООО Ромашка, ГБУЗ «Городская больница № 7», Acme Corp, LLC "Vector";
- «компания / банк / завод / заказчик … «Название»»;
- название в скобках сразу после найденного: АО «Брайтлайн Воркс» (Brightline Works);
- латинское название из двух-четырёх слов с заглавной внутри русского текста: Brightline Works, Microsoft Teams.
Найденное название дальше ищется по всему тексту и в падежах («Сибмеди») — recall.py.
ИП не считается организацией: имя предпринимателя — ПДн и скрывается всегда.
"""
from __future__ import annotations

import re

from .kinds import Kind
from .spans import Span

_QUOTED = r"(?:«[^»\n]{1,80}»|\"[^\"\n]{1,80}\"|“[^”\n]{1,80}”|„[^“\n]{1,80}“)"
_CAP_NAME = r"[A-ZА-ЯЁ][\w&+-]*(?:\.[\w&+-]+)*(?:\s+[A-ZА-ЯЁ][\w&+-]*(?:\.[\w&+-]+)*){0,2}"  # точку в конце не берём
_LEGAL_RU = (r"ООО|ОАО|ЗАО|ПАО|НАО|АО|НКО|АНО|ТСЖ|СНТ|ГУП|МУП|ФГУП|ФГБУ|ФГБОУ|ФГАОУ|ГБУЗ|ГБУ|ГАУЗ|ГКУ|МБОУ|МАОУ|МБУ|МКУ|"
             r"ТОО|ОДО|LLC|JSC|OOO")
_LEGAL_TAIL = r"LLC|Ltd\.?|Inc\.?|GmbH|JSC|PLC|Corp\.?|AG|S\.A\.|B\.V\.|LLP|Co\.,?\s+Ltd\.?"
_ORG_WORDS = (r"компани\w*|фирм\w*|групп\w*\s+компаний|ГК|банк\w*|завод\w*|холдинг\w*|корпораци\w*|концерн\w*|"
              r"предприяти\w*|организаци\w*|клиент\w*|заказчик\w*|подрядчик\w*|поставщик\w*|партн[её]р\w*|бренд\w*")

_PATTERNS = [
    re.compile(rf"(?<![\w-])(?:{_LEGAL_RU})(?![\w-])\s*(?:{_QUOTED}|{_CAP_NAME})"),
    re.compile(rf"(?<![\w-])[A-Z][\w&.+-]*(?:\s+[A-Z][\w&.+-]*){{0,3}},?\s+(?:{_LEGAL_TAIL})(?![\w])"),
    re.compile(rf"(?<![\w-])(?:{_ORG_WORDS})\s+({_QUOTED})", re.IGNORECASE),
]
# Название в кавычках — имя собственное: начинается с заглавной буквы или цифры. «Склад "лихорадит"» — не название.
_NAMED = re.compile(r"^[«\"“„]\s*[A-ZА-ЯЁ\d]")
_LATIN_SEQ = re.compile(r"(?<![\w.@/-])[A-Z][A-Za-z0-9&+-]*(?:\s+[A-Z][A-Za-z0-9&+-]*){1,3}(?![\w@/-])")
_ALIAS = re.compile(r"\s*\(([^()\n]{2,60})\)")
_CYRILLIC = re.compile(r"[а-яё]", re.IGNORECASE)


def find(text: str) -> list[Span]:
    spans: list[Span] = []
    for rx in _PATTERNS:
        for m in rx.finditer(text):
            g = 1 if rx.groups else 0
            if rx.groups and not _NAMED.match(m.group(1)):
                continue
            spans.append(Span(m.start(g), m.end(g), Kind.ORG, 1.0, "org"))
            alias = _ALIAS.match(text, m.end())
            if alias and re.search(r"[A-ZА-ЯЁ]", alias.group(1)) and not re.fullmatch(r"[\d\s.,-]+", alias.group(1)):
                spans.append(Span(alias.start(1), alias.end(1), Kind.ORG, 1.0, "org"))
    if _CYRILLIC.search(text):  # в английском тексте каждое предложение с заглавных — там это не признак названия
        for m in _LATIN_SEQ.finditer(text):
            spans.append(Span(m.start(), m.end(), Kind.ORG, 1.0, "org"))
    return spans


def inner_name(value: str) -> str | None:
    """«Сибмедь» из «ПАО «Сибмедь»»: по нему название ищется дальше — и без формы собственности, и в падежах."""
    m = re.search(_QUOTED, value)
    if m:
        name = m.group()[1:-1].strip()
    else:
        name = re.sub(rf"^(?:{_LEGAL_RU})\s+|,?\s+(?:{_LEGAL_TAIL})$", "", value.strip())
    return name if len(re.sub(r"\W", "", name)) >= 3 and name != value.strip() else None


def stem(name: str) -> str | None:
    """Основа однословного названия для падежей: «Сибмедь» → «сибмед» (Сибмеди, Сибмедью)."""
    if " " in name or len(name) < 5 or not re.fullmatch(r"[А-ЯЁа-яё-]+", name):
        return None
    low = name.lower()
    return low[:-1] if low[-1] in "аяоеьйиыу" else low


def key(value: str) -> str:
    """Ключ для одной метки на все упоминания: «ПАО «Сибмедь»», «Сибмедь» и «Сибмеди» — одна организация."""
    name = inner_name(value) or value.strip().strip("«»\"“”„")
    st = stem(name)
    return st or re.sub(r"[\W_]+", " ", name.lower().replace("ё", "е")).strip()

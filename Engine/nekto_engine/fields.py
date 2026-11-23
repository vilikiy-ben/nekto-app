"""Поля анкеты: значение, тип которого назван прямо рядом с ним.

    Фамилия: Ким            snils: 31383447060         Табельный номер
    Имя    ВИКТ0РИЯ          holder=ANNA MOROZ          07731
    Дата рождения  16.04.199O                          Skype: v.yarmolyuk

Модель в таких местах не нужна и часто бессильна: «ВИКТ0РИЯ» с нулём вместо буквы, «199O» с буквой вместо нуля,
номер без единого слова вокруг. Зато метка поля говорит всё. Метки — те же, что у заголовков столбцов
(`labels.py`): таблица и анкета отличаются только тем, где стоит заголовок.

Из значения берётся столько, сколько отвечает типу: у «Паспорт: 81 04 123456 выдан ОВД…» — номер, у «Фамилия: Ким
(девичья — Пак)» — слова с заглавной. Адрес оценивается так же, как найденный моделью (`entities.private_address`):
«Адрес: …» в шапке организации — не чьё-то жильё.
"""
from __future__ import annotations

import re

from . import labels as columns
from .kinds import Kind
from .names.lexicon import lookup
from .spans import Span

# «Метка: значение» и «метка = значение» в начале строки (после номера пункта) или в ячейке «a | b».
_LINE = re.compile(r"(?m)(?:^|(?<=\|))[ \t]*(?:\d{1,2}[.)][ \t]*)?([^\n:=|]{2,48}?)[ \t]*[:=][ \t]*(\S[^\n|]*)")
# Метка одна на строке, значение — на следующей.
_PAIR = re.compile(r"(?m)^[ \t]*(?:\d{1,2}[.)][ \t]*)?([А-ЯЁA-Z][^\n:=|]{1,48}?)[ \t]*:?[ \t]*\n[ \t]*(\S[^\n|]*)$")
# «key=value» внутри строки журнала или конфигурации.
_KEY_VALUE = re.compile(r"(?<![\w.])([A-Za-z_][\w.]{1,30})=[\"']?([^\s\"',;&|]+(?: [A-Z]{2,})?)")
# Метки, после которых значение стоит через пробелы, без двоеточия (распознанные бланки).
_BLANK = re.compile(r"(?<![\w])(фамилия|имя|отчество|дата\s+рождения|surname|given\s+names?|date\s+of\s+birth)"
                    r"(?:[ \t]*/[ \t]*[A-Za-z ]{3,20})?[ \t]{1,}(?![:=])([^\s:=][^\n|]*?)(?=[ \t]{2,}|[ \t]*$|[ \t]*\|)",
                    re.IGNORECASE | re.MULTILINE)

_NAME_WORD = r"(?:[A-ZА-ЯЁ][\w'’-]*\.?|[A-ZА-ЯЁ]\.)"
_NAME = re.compile(rf"{_NAME_WORD}(?:[ \t]+(?:{_NAME_WORD}|оглы|кызы|оглу|кизи|улы)){{0,4}}")
_NUMBER = re.compile(r"(?:[A-ZА-ЯЁ]{1,4}[ \t№-]{0,3}|\+)?\d[\dA-ZА-ЯЁ \t№/()+\-]*[\dA-ZА-ЯЁ]|\d")
# Метки, которые называют именно имя: значение — имя, каким бы словом оно ни было («Фамилия: Мороз»).
_NAME_LABEL = re.compile(r"фамили|^имя$|отчеств|^ф\.?\s?и\.?\s?о|full.?name|surname|first.?name|last.?name|given|holder", re.IGNORECASE)
_PREFIX = re.compile(r"(?:ИП|гр\.|гр-н|гр-ка|г-н|г-жа|тов\.)[ \t]+")
_DATE = re.compile(r"[\dOОЗзlI]{1,4}[./-][\dOОЗзlI]{1,2}[./-][\dOОЗзlI]{2,4}|\d{1,2}\s+[а-яё]+\s+\d{4}|\d{6,8}")
_NUMERIC = (Kind.PHONE, Kind.SNILS, Kind.INN, Kind.PASSPORT, Kind.CARD, Kind.ACCOUNT, Kind.ID)
# В значении-адресе есть чем адресу быть: улица, дом, квартира, город — словом или сокращением.
_ADDRESS = re.compile(r"(?<![\w])(?:ул|улиц\w*|пр-т|пр-кт|просп\w*|пер|переул\w*|ш|шоссе|б-р|бульвар\w*|наб\w*|мкр\w*|"
                      r"проезд|тракт|д|дом|кв|квартир\w*|г|гор|город\w*|пос\w*|с|село|дер\w*|обл\w*|р-н|район\w*|"
                      r"респ\w*|край)(?![\w])|\d+[а-яА-Я]?\s*[-–/]\s*\d+|,\s*\d+", re.IGNORECASE)
_SENDER = re.compile(r"(?m)^[ \t>]*(?:From|To|Cc|Bcc|Reply-To|От|Кому|Копия)[ \t]*:[ \t]*\"?([A-ZА-ЯЁ][^<>\n\"@:;]{2,60}?)\"?[ \t]*"
                     r"<[^<>\s@]+@[^<>\s]+>")
_DATE_WORDS = re.compile(r"\d{1,2}\s+[а-яё]{3,}\s+\d{4}(?:\s*г\.?|\s+года)?(?:\s*р\w*)?|\d{1,2}\.\d{1,2}\.\d{2,4}(?:\s*г\.?\s?р?\.?)?|"
                         r"(?:19|20)\d{2}\s*(?:г\.?|года)(?:\s*р\w*)?", re.IGNORECASE)
_NO_SECRET = {"нет", "отсутствует", "изменён", "изменен", "сброшен", "выдан", "прежний", "указан", "скрыт", "тот же",
              "такой же", "временный", "постоянный", "неизвестен", "забыл", "забыла", "утерян"}
# Где адрес в значении кончается: запятая и дальше обычные слова, а не «ул.», «д.», «кв.».
_AFTER_ADDRESS = re.compile(r",\s+(?!(?:ул|улиц\w*|пр|просп\w*|пер\w*|д|дом|кв\w*|корп\w*|стр\w*|г|гор\w*|пос\w*|с|село|обл\w*|"
                            r"р-н|район\w*|мкр\w*|подъезд|этаж|оф\w*|комн\w*)\b)[а-яё]{1,3}\s+[а-яё]{2,}|"
                            r"\s+\(|(?:(?<=\d)|(?<=[а-яё]{5}))\.\s+(?-i:[А-ЯЁ])|;\s|\s+—\s|\s+тел\b|\s+e-?mail\b", re.IGNORECASE)
_NOT_A_NAME = re.compile(r"^(?:не\s|нет\b|отсутств|указ|см\.|—|-+$)", re.IGNORECASE)


def find(text: str) -> list[Span]:
    """Значения полей с понятной меткой. Адреса возвращаются как есть — решает `entities.private_address`."""
    out: list[Span] = []
    for rx in (_LINE, _PAIR, _BLANK):
        for m in rx.finditer(text):
            label = re.sub(r"\s+", " ", m.group(1)).strip(" .")
            kind = columns.classify(label)
            if kind is None and rx is not _BLANK:
                continue
            if rx is _BLANK:
                kind = Kind.BIRTHDATE if "рожд" in label.lower() or "birth" in label.lower() else Kind.PERSON
            if rx is _PAIR and (":" in m.group(2)[:30] or columns.classify(m.group(2).strip(" :"))):
                continue                                   # следующая строка — сама поле или метка
            span = _value(kind, text, m.start(2), m.end(2), strict=not (rx is _BLANK or _NAME_LABEL.search(label)))
            if span:
                out.append(span)
    for m in _SENDER.finditer(text):                       # «To: Petrov, Vladislav <v.petrov@…>»
        value = m.group(1).strip()
        if any(lookup(w.lower()).first or lookup(w.lower()).patrs for w in re.findall(r"[^\W\d_]{3,}", value)):
            out.append(Span(m.start(1), m.start(1) + len(m.group(1).rstrip()), Kind.PERSON, 0.9, "field"))
    for m in _KEY_VALUE.finditer(text):
        kind = columns.classify(m.group(1).replace("_", " ").replace(".", " "))
        if kind is not None and kind is not Kind.ADDRESS:
            span = _value(kind, text, m.start(2), m.end(2))
            if span:
                out.append(span)
    return out


def _value(kind: Kind, text: str, start: int, end: int, strict: bool = False) -> Span | None:
    """Часть значения, отвечающая типу поля. `strict` — метка называет роль («Ответственный», «Клиент»), а не имя:
    значение должно быть похоже на имя само («Ответственный: Отдел кадров» — нет)."""
    value = text[start:end]
    if kind is Kind.PERSON:
        prefix = _PREFIX.match(value)
        if prefix:
            start, value = start + prefix.end(), value[prefix.end():]
        m = _NAME.match(value)
        if not m or _NOT_A_NAME.match(value) or not columns.accept(Kind.PERSON, m.group()):
            return None
        if re.match(r"[ \t]+[а-яёa-z]{2,}", value[m.end():]) and value[m.end():].strip() not in ("оглы", "кызы"):
            return None                                    # «Имя: Заполняется печатными буквами» — фраза, а не имя
        if strict and not _name_like(m.group()):
            return None
        return Span(start, start + m.end(), kind, 0.9, "field")
    if kind in _NUMERIC:
        m = _NUMBER.search(value)
        if not m or m.start() > 12:
            return None
        a, b = m.start(), m.end()
        while b > a and value[b - 1] in " \t№/(-":
            b -= 1
        tail = re.search(r"[ \t]+(?:[А-ЯЁ]?[а-яё]{3,}|[A-Za-z]{3,})", value[a:b])   # «…123456 выдан ОВД»: слово — уже не номер
        if tail:
            b = a + tail.start()
        if not columns.accept(kind, value[a:b]) or (kind is Kind.INN and sum(c.isdigit() for c in value[a:b]) != 12):
            return None
        return Span(start + a, start + b, kind, 0.9, "field")
    if kind is Kind.BIRTHDATE:
        m = _DATE.search(value)
        if not m or m.start() > 12:
            return None
        return Span(start + m.start(), start + m.end(), kind, 0.9, "field")
    if kind is Kind.SECRET and re.fullmatch(r"[А-ЯЁа-яё]{4,}\d*", value.strip()) and value.strip().lower() not in _NO_SECRET:
        return Span(start, start + len(value.rstrip()), kind, 0.9, "field")        # «Кодовое слово⏎ЧЕРЁМУХА»
    if kind in (Kind.HANDLE, Kind.SECRET):
        m = re.match(r"[^\s,;()«»\"']{3,}", value)
        if not m or not re.search(r"[A-Za-z0-9]", m.group()) or re.fullmatch(r"[а-яё]+", m.group(), re.IGNORECASE) \
                or not columns.accept(kind, m.group()):
            return None                                    # «Пароль: не менялся» — слово; «admin» — общая учётка
        return Span(start, start + m.end(), kind, 0.9, "field")
    if kind is Kind.ADDRESS:
        cut = _AFTER_ADDRESS.search(value)                 # «…, 12-48, в том, что он находился на лечении»
        if cut:
            value = value[:cut.start()]
        value = value[:140].rstrip(" .;,")
        probe = _DATE_WORDS.sub(" ", value)                # «Проживает: Долгих А. П., 1 июня 1941 г. рождения» — не адрес
        if len(value) < 6 or not re.search(r"\d", probe) or not re.search(r"[А-ЯЁA-Z]", value) or not _ADDRESS.search(probe):
            return None                                    # «Место жительства⏎Зарегистрирована 12 сентября 2014 г.»
        return Span(start, start + len(value), kind, 0.9, "field")
    return None


def _name_like(value: str) -> bool:
    """Хоть одно слово — имя, отчество, фамилия по словарю или форме, инициал или слово вне словаря."""
    for word in re.findall(r"[^\W\d_]+(?:-[^\W\d_]+)*\.?", value):
        if len(word.rstrip(".")) == 1:
            return True
        lex = lookup(word.rstrip(".").lower())
        if lex.first or lex.patrs or lex.surname or lex.shape or not lex.known:
            return True
    return False

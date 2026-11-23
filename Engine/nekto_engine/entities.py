"""Контакты, номера документов и адреса из меток модели.

Модель размечает слова, а не значения: у номера паспорта может быть помечена одна группа цифр из двух, у адреса —
город и улица, но не «д.» между ними. Здесь слова собираются в значения, значение дотягивается до своих границ
(весь номер, весь адрес с домом и квартирой) и проверяется по форме: «телефон» без семи цифр или «паспорт» без
цифр — выдумка модели, а не ПДн.

ФИО здесь нет — ими занимается `names.finder`: там одной модели мало.
"""
from __future__ import annotations

import re
from typing import Sequence

from .kinds import Kind
from .model import Tag
from .rules import OFFICE, ORG_NEAR, toll_free
from .spans import Span

_NUMBERS: dict[str, Kind] = {
    "PHONE": Kind.PHONE, "INN": Kind.INN, "SNILS": Kind.SNILS, "PASSPORT": Kind.PASSPORT, "CREDIT_CARD": Kind.CARD,
    "BIRTH_CERTIFICATE": Kind.ID, "DRIVER_LICENSE": Kind.ID, "MILITARY_ID": Kind.ID, "OMS": Kind.ID,
}
_TEXTUAL: dict[str, Kind] = {"EMAIL": Kind.EMAIL, "URL": Kind.URL}
_PLACES = {"COUNTRY", "REGION", "DISTRICT", "CITY", "STREET", "HOUSE"}
_THRESHOLD = 0.5

# Между частями одного номера: пробел, дефис, скобки, «№».
_NUMBER_GAP = re.compile(r"[\s\-–()№#/.]{0,3}")
_FILE = re.compile(r"\.(?:ya?ml|json|xml|csv|txt|log|conf|cfg|ini|py|js|ts|sh|sql|md|pdf|docx?|xlsx?|pptx?|zip|png|jpe?g|exe|"
                   r"html?|css|env|lock|toml|bak|tmp)$", re.IGNORECASE)
_MONEY = re.compile(r"[+\-−–]?\s?\d{1,3}(?:[ \u00a0]\d{3})*[.,]\d{2}")
_MIN_DIGITS = {Kind.PHONE: 7, Kind.INN: 10, Kind.SNILS: 11, Kind.PASSPORT: 4, Kind.CARD: 12, Kind.ID: 5}
_MAX_DIGITS = {Kind.PHONE: 12, Kind.INN: 12, Kind.SNILS: 11, Kind.PASSPORT: 10, Kind.CARD: 19, Kind.ID: 20}

_ABBR = (r"г|гор|город|ул|улица|улицы|пр|пр-т|пр-кт|просп|проспект|пер|переулок|ш|шоссе|б-р|бульвар|наб|набережная|пл|"
         r"площадь|мкр|мкрн|микрорайон|д|дом|дер|деревня|с|село|пос|п|посёлок|поселок|пгт|ст|станица|обл|область|край|"
         r"респ|республика|р-н|район|к|корп|корпус|стр|строение|кв|квартира|оф|офис|им|имени|проезд|тупик|аллея|линия")
_PLACE_GAP = re.compile(rf"[\s,.;]*(?:(?:{_ABBR})\.?[\s,]*){{0,3}}", re.IGNORECASE)
_LEFT = re.compile(rf"(?:\d{{6}},?\s*)?(?:(?:{_ABBR})\.?\s*)$", re.IGNORECASE)
_LEFT_INDEX = re.compile(r"\d{6},?\s*$")
# хвост адреса после помеченной части; без «^»: `match(text, pos)` и так начинает с pos, а «^» там не срабатывает
_RIGHT = re.compile(r"(?:,?\s*(?:д\.|дом|корп\.|корпус|к\.|стр\.|строение|кв\.?|квартира|оф\.|офис|лит\.|литера|подъезд|под\.|"
                    r"этаж|эт\.|комн\.|комната|пом\.)\s*[\dА-Яа-я/\-]+)+", re.IGNORECASE)
# Прямо сказано, что это чьё-то жильё.
# «зарегистрирован(а) в / по» — о человеке; «зарегистрировано в ОМВД» — о заявлении
_HOME = re.compile(r"прожива\w+|зарегистрирован[аы]?(?![а-яё])\s+(?:по|в)(?![а-яё])|прописан\w*|"
                   r"место\s+жительства|адрес\w*\s+(?:регистрации|проживания|места|фактическ|по\s+прописке)|"
                   r"домашн\w+\s+адрес|место\s+рождения|родил(?:ся|ась)\s+в|урожен", re.IGNORECASE)
_ADDRESS_WORD = re.compile(r"адрес", re.IGNORECASE)
_APARTMENT = re.compile(r"(?<![\w])(?:кв\.?|квартир\w*|комн\.?|комнат\w*)\s*\d|\d+[а-яА-Я]?\s*[-–]\s*\d+\s*$", re.IGNORECASE)


def from_tags(text: str, tags: Sequence[Tag]) -> list[Span]:
    """Спаны контактов, номеров и адресов по меткам модели."""
    return _numbers(text, tags) + _textual(text, tags) + _addresses(text, tags)


def _numbers(text: str, tags: Sequence[Tag]) -> list[Span]:
    out: list[Span] = []
    for start, end, label, score in _runs(text, tags, _NUMBERS, _NUMBER_GAP):
        kind = _NUMBERS[label]
        wide = _whole_number(text, start, end)
        if sum(ch.isdigit() for ch in text[wide[0]:wide[1]]) <= _MAX_DIGITS[kind]:
            start, end = wide                                # иначе рядом чужие цифры: «30.06.2001 9005550611»
        value = text[start:end]
        digits = sum(ch.isdigit() for ch in value)
        masked = "*" in value and digits >= 4                # «2202 **** **** 9692»
        if digits < _MIN_DIGITS[kind] and not masked:
            continue
        if kind is Kind.INN and digits == 10:                # ИНН организации — не ПДн
            continue
        if kind is Kind.PHONE and (toll_free(value) or (digits > 12 and "+" not in value)):
            continue                                         # 8-800 — горячая линия; 15 цифр подряд — серийный номер
        if kind is Kind.PHONE and _MONEY.fullmatch(value.strip()):
            continue                                         # «+96 400,00», «131 216,48» — сумма в выписке
        span = Span(start, end, kind, score, "model")
        if span not in out:                                  # две помеченные группы одного номера дают его дважды
            out.append(span)
    return out


def _textual(text: str, tags: Sequence[Tag]) -> list[Span]:
    out: list[Span] = []
    for start, end, label, score in _runs(text, tags, _TEXTUAL, re.compile(r"\S{0,2}")):
        stops = "<>()«»\"'|" + (";,:=" if label == "EMAIL" else "")        # в строке «a;b@c.ru;d» почта — только «b@c.ru»
        while start > 0 and not text[start - 1].isspace() and text[start - 1] not in stops:
            start -= 1
        while end < len(text) and not text[end].isspace() and text[end] not in stops:
            end += 1
        while end > start and text[end - 1] in ".,;:!?":
            end -= 1
        value = text[start:end]
        if label == "EMAIL" and not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", value):
            continue
        if label == "URL" and not re.search(r"[\w-]\.[a-zа-я]{2,}|://", value, re.IGNORECASE):
            continue
        if label == "URL" and "/" not in value and _FILE.search(value):          # «docker-compose.override.yml»
            continue
        if label == "EMAIL" and "[bot]" in value:   # робот, а не человек
            continue
        out.append(Span(start, end, _TEXTUAL[label], score, "model"))
    return out


def _addresses(text: str, tags: Sequence[Tag]) -> list[Span]:
    """Адрес — цепочка частей (регион, город, улица, дом). Город или страна сами по себе — не ПДн: «офис в Казани».
    Цепочка скрывается, если в ней есть улица или дом, либо перед ней сказано, что это чьё-то место жительства."""
    out: list[Span] = []
    chain: list[Tag] = []
    places = [t for t in tags if t.label in _PLACES and t.score >= _THRESHOLD]
    for tag in places + [None]:  # type: ignore[list-item]
        if tag is not None and chain and tag.start - chain[-1].end <= 24 and _continues(text[chain[-1].end:tag.start]):
            chain.append(tag)
            continue
        if chain:
            span = _address(text, chain)
            if span:
                out.append(span)
        chain = [tag] if tag is not None else []
    return out


def _continues(gap: str) -> bool:
    """Следующая часть адреса — тот же адрес? На новой строке — только после запятой или с «ул.», «д.», «кв.»:
    иначе это уже следующий пункт анкеты («…, 12/1–96⏎6. Место работы»)."""
    if not _PLACE_GAP.fullmatch(gap):
        return False
    return "\n" not in gap or "," in gap or bool(re.search(r"[^\W\d]", gap))


def _address(text: str, chain: list[Tag]) -> Span | None:
    labels = {t.label for t in chain}
    start, end = chain[0].start, chain[-1].end
    house = any(t.label == "HOUSE" and any(ch.isdigit() for ch in text[t.start:t.end]) for t in chain)
    tail = _RIGHT.match(text, end)
    if tail:
        end = tail.end()
    head = _LEFT.search(text, max(0, start - 28), start) or _LEFT_INDEX.search(text, max(0, start - 9), start)
    if head:
        start = head.start()
    street = "STREET" in labels and (house or tail is not None or len(labels) > 1)
    if not private_address(text, start, end, street=street, located=bool(labels & {"CITY", "STREET", "DISTRICT"}) or house):
        return None
    return Span(start, end, Kind.ADDRESS, min(t.score for t in chain), "model")


def private_address(text: str, start: int, end: int, street: bool = True, located: bool = True) -> bool:
    """Это адрес человека, а не организации? Свидетельства складываются:

      за жильё        — квартира; «проживает», «зарегистрирован», «адрес регистрации»; просто слово «адрес» (слабо);
      за организацию  — «офис», «пом.», «ТЦ», «склад» в адресе или сразу за ним; ООО / ИНН из 10 цифр / КПП /
                        «юридический адрес» / «место работы» / «клиника» в предыдущих строках.
    Без единого свидетельства улица с домом считается жильём (пропуск дороже), город сам по себе — нет."""
    inside = text[start:end]
    line_end = text.find("\n", end)
    after = text[end:min(len(text), end + 40) if line_end < 0 else min(line_end, end + 40)]
    before = text[max(0, start - 200):start]
    near = before.rsplit("\n", 2)                              # эта строка и две предыдущие
    near_text = "\n".join(near[-3:])
    this_line = near[-1]
    score = 0
    home = bool(_HOME.search(this_line) or (len(near) > 1 and _HOME.search(near[-2])))
    if _APARTMENT.search(inside) or _APARTMENT.search(inside + after[:16]):
        score += 2
    if home:
        score += 2
    elif _ADDRESS_WORD.search(this_line):
        score += 1
    office = bool(OFFICE.search(inside) or OFFICE.search(after))
    if office:
        score -= 2
    if ORG_NEAR.search(near_text):
        score -= 2
    if not street:                                            # город, регион: только если сказано, что там живут
        return home and located and score > 0
    return score >= 0


def _runs(text: str, tags: Sequence[Tag], labels, gap: re.Pattern[str]):
    """Соседние слова с одной меткой → одно значение: (начало, конец, метка, уверенность)."""
    cur: list | None = None
    for tag in tags:
        if tag.label not in labels or tag.score < _THRESHOLD:
            continue
        if cur and cur[2] == tag.label and gap.fullmatch(text[cur[1]:tag.start]):
            cur[1] = tag.end
            cur[3] = min(cur[3], tag.score)
        else:
            if cur:
                yield tuple(cur)
            cur = [tag.start, tag.end, tag.label, tag.score]
    if cur:
        yield tuple(cur)


def _whole_number(text: str, start: int, end: int) -> tuple[int, int]:
    """Расширяет помеченный кусок до всего номера: модель нередко метит одну группу цифр из двух.
    Идём в обе стороны по цифрам и разделителям внутри номера; слово, запятая или двойной пробел — граница."""
    inner = "0123456789*-–()№ \u00a0"
    while start > 0 and text[start - 1] in inner and not (text[start - 1] in " \u00a0" and start > 1 and text[start - 2] in " \u00a0"):
        start -= 1
    while end < len(text) and text[end] in inner and not (text[end] in " \u00a0" and text[end + 1:end + 2] in (" ", "\u00a0")):
        end += 1
    if start > 0 and text[start - 1] == "+":
        start -= 1
    while start < end and text[start] in " \u00a0-–)№":
        start += 1
    while end > start and text[end - 1] in " \u00a0-–(№":
        end -= 1
    return start, end

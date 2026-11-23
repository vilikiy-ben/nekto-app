"""Метки полей: что лежит в столбце таблицы, под ключом JSON или после «Фамилия:» в анкете.

Если столбец называется «ФИО» или «Телефон», каждая непустая ячейка — ПДн этого типа, модель не нужна: это быстрее
и надёжнее (номер паспорта без слова «паспорт» модель может пропустить). Те же метки читает `fields` в сплошном
тексте: таблица и анкета отличаются только тем, где стоит заголовок. Для ИНН учитываем длину: 10 цифр — организация.
"""
from __future__ import annotations

import re

from .kinds import Kind
from .rules import only_digits, SERVICE_ACCOUNT as _SERVICE_ACCOUNT

_RULES: list[tuple[Kind, re.Pattern[str]]] = [
    (Kind.EMAIL, re.compile(r"e-?mail|почт|электронн\w* адрес|mail$", re.I)),
    (Kind.PHONE, re.compile(r"телеф|моб|^тел\b|phone|mobile|cell|whatsapp|telegram ?(номер|phone)", re.I)),
    (Kind.SNILS, re.compile(r"снилс|snils", re.I)),
    (Kind.INN, re.compile(r"^инн\b|^inn\b|\bинн физ|tax ?id|\btin\b", re.I)),
    (Kind.PASSPORT, re.compile(r"паспорт|passport|серия.*номер|документ.*удостов", re.I)),
    (Kind.CARD, re.compile(r"(номер )?карт[аы]\b|card ?(number|no)", re.I)),
    (Kind.ACCOUNT, re.compile(r"сч[её]т\b|л/с|лицев|account|iban", re.I)),
    (Kind.BIRTHDATE, re.compile(r"дата рожд|д\.?\s?р\.?$|^др$|birth|dob\b|день рожд|^родил|рождени", re.I)),
    (Kind.ADDRESS, re.compile(r"адрес|address|прожива|регистрац|место жит", re.I)),
    (Kind.IP, re.compile(r"^ip\b|ip.?адрес|ip.?address", re.I)),
    (Kind.SECRET, re.compile(r"парол|password|passwd|^pwd$|^pass$|пин.?код|^pin$|кодов\w+ слов|secret|секрет|"
                             r"^token$|токен|api.?key|^session|^sid$", re.I)),
    (Kind.HANDLE, re.compile(r"^skype$|скайп|telegram|телеграм|^tg$|^ник|nickname|^логин|^login$|^user(name)?$|^actor$|имя пользовател|"
                             r"уч[её]тн\w+ запис|^уч[её]тка|аккаунт|account.?name", re.I)),
    (Kind.ID, re.compile(r"таб\.?\s*(№|номер)?$|табельн|employee.?id|personnel|^id сотр|полис|снилс|медкарт|"
                         r"^документ$|^док\.?$|удостоверени|водительск|^в/у$|doc.?number|номер документа|patent|патент|"
                         r"^птс$|^стс$|^vin$|огрнип|licen[sc]e.?(no|number)|диплом|военн\w+ билет|travel document|"
                         r"number of .{0,20}document|document.?(no|number)|^элн$|больничн", re.I)),
    (Kind.PERSON, re.compile(r"^фио$|ф\.\s?и\.\s?о|^ф\.?и\.?о\.?|фамили|^имя\b|отчеств|full.?name|^name$|first.?name|"
                             r"last.?name|surname|сотрудник|работник|руководител|получател|пациент|клиент$|"
                             r"контактн\w* лиц|ответственн|исполнитель$|manager$|employee$|contact$|"
                             r"holder|владел\w+ карт|given.?names?", re.I)),
]

# Ключи, где лежат чужие ПДн, но заголовок слишком общий для целого столбца
_SKIP = re.compile(r"компан|организац|отдел|подраздел|департамент|должност|company|department|title|position|"
                   r"product|товар|услуг|сумм|amount|price|цена|кол-?во|qty|статус|status", re.I)


_ORG = re.compile(r"\b(ООО|ОАО|ЗАО|ПАО|АО|НКО|ГУП|МУП|ГАУЗ|ГБУЗ|ФГУП|LLC|Ltd|Inc|GmbH|JSC|PLC|Corp)\b|[«»\"]", re.I)


_SHARED_ACCOUNTS = {"admin", "administrator", "root", "user", "guest", "test", "demo", "support", "info", "system", "security",
                    "service", "postgres", "mysql", "oracle", "www-data", "nobody", "default", "anonymous", "админ"}


def classify(header: str | None) -> Kind | None:
    if not header:
        return None
    h = str(header).strip().lower().replace("_", " ")
    if not h or _SKIP.search(h):
        return None
    for kind, rx in _RULES:
        if rx.search(h):
            return kind
    return None


def accept(kind: Kind, value: str) -> bool:
    """Значение подходит под тип столбца? Защита от «—», «нет», организационных ИНН и т. п."""
    v = value.strip()
    if not v or v.lower() in {"-", "—", "нет", "n/a", "na", "null", "none", "не указан", "не указано"}:
        return False
    digits = only_digits(v)
    if kind is Kind.INN:
        return len(digits) == 12
    if kind is Kind.ACCOUNT and len(digits) == 20 and digits[:3] in ("405", "406", "407"):
        return False                         # расчётный счёт организации — не ПДн
    if kind is Kind.PHONE and len(digits) == 11 and digits[1:4] in ("800", "804"):
        return False                         # горячая линия
    if kind in (Kind.PHONE, Kind.SNILS, Kind.PASSPORT, Kind.CARD, Kind.ACCOUNT):
        return len(digits) >= 6
    if kind is Kind.ID:                      # номер, а не название документа («Паспорт РФ», «Договор»)
        return len(digits) >= 3
    if kind is Kind.HANDLE:                  # учётная запись — одно слово, и не общая («admin», «root»)
        return len(v) >= 3 and " " not in v and v.lower() not in _SHARED_ACCOUNTS and not _SERVICE_ACCOUNT.match(v)
    if kind is Kind.ADDRESS:                 # «самовывоз, пункт выдачи № 14» в столбце адреса — не адрес человека
        return not re.search(r"самовывоз|пункт\w*\s+выдачи|постамат|\bпвз\b", v, re.I)
    if kind is Kind.SECRET:
        return len(v) >= 4 and " " not in v
    if kind is Kind.PERSON:
        return bool(re.search(r"[A-Za-zА-Яа-яЁё]{2,}", v)) and not _ORG.search(v) and len(v) < 80
    return True

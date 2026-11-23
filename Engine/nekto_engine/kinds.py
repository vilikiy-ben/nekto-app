"""Типы персональных данных и их метки в обезличенном тексте."""
from __future__ import annotations

from enum import Enum


class Kind(str, Enum):
    PERSON = "ФИО"
    ADDRESS = "АДРЕС"
    DATE = "ДАТА"
    BIRTHDATE = "ДР"     # дата рождения: ПДн всегда, режим «Оставить даты» её не открывает
    PHONE = "ТЕЛЕФОН"
    EMAIL = "EMAIL"
    PASSPORT = "ПАСПОРТ"
    SNILS = "СНИЛС"
    INN = "ИНН"
    ACCOUNT = "СЧЁТ"
    CARD = "КАРТА"
    IP = "IP"
    MAC = "MAC"
    URL = "ССЫЛКА"
    HANDLE = "НИК"
    ID = "НОМЕР"
    SECRET = "СЕКРЕТ"
    ORG = "ОРГ"          # организация: скрывается только в режиме «Скрывать организации» (orgs.py)
    OTHER = "ПДН"

    @property
    def tag(self) -> str:
        return self.value


# При пересечении спанов побеждает более «узкий» и надёжный тип.
# Регулярки с контрольной суммой надёжнее модели, конкретный класс модели надёжнее общего «ПДН».
PRIORITY: dict[Kind, int] = {
    Kind.OTHER: 0,
    Kind.ID: 1,
    Kind.ORG: 1,
    Kind.DATE: 2,
    Kind.BIRTHDATE: 3,
    Kind.ADDRESS: 3,
    Kind.PERSON: 4,
    Kind.HANDLE: 5,
    Kind.URL: 6,
    Kind.PHONE: 7,
    Kind.PASSPORT: 7,
    Kind.EMAIL: 8,
    Kind.IP: 8,
    Kind.MAC: 8,
    Kind.SNILS: 9,
    Kind.INN: 9,
    Kind.ACCOUNT: 9,
    Kind.CARD: 9,
    Kind.SECRET: 10,
}

# Типы, которые по умолчанию видны и скрываются только по выбору пользователя (`Session.hide`).
OPT_IN: frozenset[Kind] = frozenset({Kind.ORG})

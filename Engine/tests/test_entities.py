"""Контакты, номера и адреса из меток модели: сборка слов в значение и проверка формы."""
import re

from nekto_engine import entities
from nekto_engine.kinds import Kind
from nekto_engine.model import Tag


def tags(text: str, said: dict[str, str]) -> list[Tag]:
    out = []
    for word, label in said.items():
        out += [Tag(m.start(), m.end(), label, 0.99) for m in re.finditer(re.escape(word), text)]
    return sorted(out, key=lambda t: t.start)


def spans(text: str, said: dict[str, str]) -> list[tuple[str, Kind]]:
    return [(text[s.start:s.end], s.kind) for s in entities.from_tags(text, tags(text, said))]


def test_partly_labelled_number_is_taken_whole():
    text = "Паспорт 45 11 123456 выдан в 2010 году"
    assert spans(text, {"123456": "PASSPORT"}) == [("45 11 123456", Kind.PASSPORT)]
    text = "звоните +7 (900) 555-01-48, добавочный 12"
    assert spans(text, {"900": "PHONE", "555-01-48": "PHONE"}) == [("+7 (900) 555-01-48", Kind.PHONE)]


def test_number_does_not_swallow_its_neighbour():
    text = "5. Жук Д. А. 30.06.2001 9005550611 водитель"
    assert spans(text, {"9005550611": "PHONE"}) == [("9005550611", Kind.PHONE)]
    assert spans("Серийный номер: 770120240500117", {"770120240500117": "PHONE"}) == []      # 15 цифр — не телефон


def test_next_form_item_is_not_part_of_the_address():
    text = "Адрес: РБ, Уфа, Сипайловская ул., 12/1–96\n6. Место работы, должность"
    found_ = spans(text, {"Уфа": "CITY", "Сипайловская": "STREET", "12/1–96": "HOUSE", "6": "HOUSE"})
    assert [value for value, _k in found_ if "\n" in value or value == "6"] == []


def test_shape_is_checked():
    assert spans("телефон печатка-9 и всё", {"печатка-9": "PHONE"}) == []          # «телефон» без цифр
    assert spans("ИНН 7707083893", {"7707083893": "INN"}) == []                    # 10 цифр — организация
    assert spans("ИНН 500100732259", {"500100732259": "INN"}) == [("500100732259", Kind.INN)]
    assert spans("горячая линия 8-800-555-35-35", {"8-800-555-35-35": "PHONE"}) == []
    assert spans("почта ivan@", {"ivan@": "EMAIL"}) == []
    assert spans("карта 2202 **** **** 9692", {"2202": "CREDIT_CARD", "9692": "CREDIT_CARD"}) == [("2202 **** **** 9692", Kind.CARD)]


def test_address_is_a_chain_with_street_or_house():
    text = "Проживает: Республика Татарстан, д. Берёзовка, ул. Маршала Жукова, д. 62, кв. 5, рядом с парком"
    said = {"Республика": "REGION", "Татарстан": "REGION", "Берёзовка": "CITY", "Маршала": "STREET", "Жукова": "STREET", "62": "HOUSE"}
    assert spans(text, said) == [("Республика Татарстан, д. Берёзовка, ул. Маршала Жукова, д. 62, кв. 5", Kind.ADDRESS)]


def test_city_alone_is_not_personal_data():
    assert spans("Офис в Казани, склад в Сибири.", {"Казани": "CITY", "Сибири": "REGION"}) == []
    assert spans("Мы работаем на улице Баумана уже десять лет.", {"Баумана": "STREET"}) == []
    # но место жительства человека — да
    assert spans("Зарегистрирован в г. Казань с 2010 года.", {"Казань": "CITY"}) == [("г. Казань", Kind.ADDRESS)]


def test_office_address_stays():
    text = "Офис компании расположен по адресу: г. Москва, Пресненская наб., д. 12"
    assert spans(text, {"Москва": "CITY", "Пресненская": "STREET", "12": "HOUSE"}) == []

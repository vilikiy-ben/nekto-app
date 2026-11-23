"""Правки пользователя в панели «Скрыто»: обратимы, не гоняют модель заново и не меняют таблицу меток зря."""
import threading

from fakes import CountingDetector
from nekto_engine.formats import Context
from nekto_engine.kinds import Kind
from nekto_engine.session import Session


TEXT = "Звонил Пётр Смирнов из Казани по поводу договора. Реквизиты прислал Пётр Смирнов."
PLAIN = "Реквизиты прислали вчера, договор подписан."   # без имён: их нашёл бы и словарь, без модели


def _ctx(detector, session):
    return Context(detector, session, threading.Event(), lambda _: None)


def test_edit_reuses_findings_without_model():
    d = CountingDetector({"Пётр Смирнов": "LAST_NAME"})
    s = Session()
    first = _ctx(d, s).clean_text(TEXT)
    assert d.model_calls == 1 and "[ФИО_1]" in first

    s.allow("[ФИО_1]")
    second = _ctx(d, s).clean_text(TEXT)
    assert d.model_calls == 1, "правка не должна запускать модель"
    assert "Пётр Смирнов" in second and "[ФИО_1]" not in second

    s.unallow("[ФИО_1]")
    assert _ctx(d, s).clean_text(TEXT) == first
    assert d.model_calls == 1


def test_cache_tells_documents_apart():
    d = CountingDetector({"Пётр Смирнов": "LAST_NAME"})
    _ctx(d, Session()).clean_segments(["Пётр", "Смирнов"])
    _ctx(d, Session()).clean_segments(["Пётр Смирнов"])   # тот же текст, другие сегменты
    assert d.model_calls == 2


def test_manual_hide_survives_uncheck_and_recheck():
    """«Скрыть» вручную → снять галочку → поставить снова: значение снова под меткой."""
    d = CountingDetector({})
    s = Session()
    s.force("Реквизиты", Kind.OTHER)
    hidden = _ctx(d, s).clean_text(PLAIN)
    assert "Реквизиты" not in hidden and "[ПДН_1]" in hidden

    s.allow("[ПДН_1]")
    assert "Реквизиты" in _ctx(d, s).clean_text(PLAIN)
    assert s.mapping()[0]["allowed"] is True

    s.unallow("[ПДН_1]")
    assert _ctx(d, s).clean_text(PLAIN) == hidden
    assert s.mapping()[0]["allowed"] is False


def test_mapping_is_stable_across_reprocessing():
    """Пересчёт того же документа не меняет таблицу меток: панель не должна видеть разницы."""
    d = CountingDetector({"Пётр Смирнов": "LAST_NAME", "Казани": "CITY"})
    s = Session()
    _ctx(d, s).clean_text(TEXT)
    before = s.mapping()
    for _ in range(3):
        _ctx(d, s).clean_text(TEXT)
    assert s.mapping() == before


def test_allowed_survives_new_canonical_form():
    """Снятое значение остаётся снятым, даже если позже нашлась более полная форма имени."""
    s = Session()
    s.placeholder(Kind.PERSON, "Смирнов")
    s.allow("[ФИО_1]")
    # Более полная форма того же человека нашлась в другом документе: она тоже не скрывается.
    assert s.placeholder(Kind.PERSON, "Смирнов Пётр Иванович") == "Смирнов Пётр Иванович"
    entry = s.mapping()[0]
    assert entry["original"] != "Смирнов"
    assert entry["allowed"] is True


def test_manual_hide_of_one_form_rehides_the_value():
    """Значение снято, а потом одну его форму скрыли вручную — значение снова скрывается целиком."""
    d = CountingDetector({"Пётр Смирнов": "LAST_NAME"})
    s = Session()
    hidden = _ctx(d, s).clean_text(TEXT)
    s.allow("[ФИО_1]")
    assert "Пётр Смирнов" in _ctx(d, s).clean_text(TEXT)
    s.force("Пётр Смирнов", Kind.PERSON)
    assert _ctx(d, s).clean_text(TEXT) == hidden
    assert s.mapping()[0]["allowed"] is False

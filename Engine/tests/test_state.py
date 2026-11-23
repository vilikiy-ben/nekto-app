"""Обработка переживает перезапуск: состояние сессии сохраняется и поднимается без потерь."""
import json
import threading

from nekto_engine.formats import Context
from nekto_engine.kinds import Kind
from nekto_engine.session import Session
from nekto_engine.spans import Span


def _apply(session, text, *pieces):
    spans = []
    for value, kind in pieces:
        i = text.index(value)
        spans.append(Span(i, i + len(value), kind, 1.0, "test"))
    return session.apply(text, session.adjust(text, spans))


def test_roundtrip_keeps_labels_and_people():
    s = Session()
    _apply(s, "Ахмерова Гульнара Ильдаровна, +7 900 555-01-48",
           ("Ахмерова Гульнара Ильдаровна", Kind.PERSON), ("+7 900 555-01-48", Kind.PHONE))
    s.force("Проект Сокол", Kind.OTHER)
    state = json.loads(json.dumps(s.to_state(), ensure_ascii=False))  # как на диске

    r = Session.from_state(state)
    # Тот же человек в другом падеже и тот же телефон в другой записи — прежние метки.
    out = _apply(r, "Звонила Ахмеровой Г. И. с 89005550148",
                 ("Ахмеровой Г. И.", Kind.PERSON), ("89005550148", Kind.PHONE))
    assert out == "Звонила [ФИО_1] с [ТЕЛЕФОН_1]"
    # Новый человек продолжает нумерацию, а не начинает заново.
    assert _apply(r, "Иванов Пётр", ("Иванов Пётр", Kind.PERSON)) == "[ФИО_2]"
    # Ручная правка тоже восстановилась.
    assert any(sp.source == "user" for sp in r.adjust("проект сокол", []))


def test_roundtrip_allowed_and_keep():
    s = Session()
    _apply(s, "ООО Ромашка", ("ООО Ромашка", Kind.OTHER))
    s.allow("[ПДН_1]")
    s.set_keep({Kind.DATE})
    r = Session.from_state(s.to_state())
    assert r.is_allowed("ООО Ромашка")
    assert r.keep == {Kind.DATE}


def test_keep_dates(detector):
    session = Session()
    session.set_keep({Kind.DATE})
    ctx = Context(detector, session, threading.Event(), lambda _: None)
    out = ctx.clean_text("Договор с Гиниятуллиным Ильдаром Маратовичем от 03.08.2025, тел. +7 900 555-00-55.")
    assert "03.08.2025" in out
    assert "Гиниятуллин" not in out and "[ТЕЛЕФОН_1]" in out

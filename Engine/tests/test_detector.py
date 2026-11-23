"""Детектор: когда зовётся модель, что ей показывается и что из её ответа запоминается."""
import threading

from fakes import CountingDetector
from nekto_engine.detector import needs_model
from nekto_engine.formats import Context
from nekto_engine.formats import rows as rows_mod
from nekto_engine.kinds import Kind
from nekto_engine.session import Session


def _ctx(detector, session=None):
    return Context(detector, session or Session(), threading.Event(), lambda _: None)


def test_gate():
    assert not needs_model("Все отлично, спасибо большое!")
    assert not needs_model("Оценка 10 из 10, сроки — 2 недели, скидка 15%.")
    assert needs_model("Номер заказа 4510123456 потеряли.")              # длинный номер
    assert needs_model("Живу на ул. Мира, 5")                            # адрес с номером дома
    assert needs_model("Спасибо Ире!")


def test_model_is_not_called_for_text_without_candidates():
    d = CountingDetector()
    _ctx(d).clean_segments(["Все отлично.", "Сроки соблюдаются, качество хорошее.", "Оценка 10 из 10."])
    assert d.model_calls == 0


def test_identical_cells_are_one_call_and_one_piece_of_work():
    """Тысяча строк с одним названием отдела — модель видит его один раз (и то, если в нём есть на что смотреть)."""
    d = CountingDetector({"Зуевой": "LAST_NAME"})
    long_cell = "Служба эксплуатации / Смена Б / Бригада Зуевой, дежурства по вечерам и выходным"
    table = [[rows_mod.Item(long_cell, "Кто пишет")] for _ in range(1000)]
    found = rows_mod.find_rows(_ctx(d), table)
    assert all(len(cells[0]) == 1 for cells in found)
    assert d.model_calls == 1
    assert sum(len(batch) for batch in d.tagger.seen) == 1


def test_rows_do_not_share_context_but_lines_do():
    d = CountingDetector()
    ctx = _ctx(d)
    rows_mod.find_rows(ctx, [[rows_mod.Item("Иванов", "Кто")], [rows_mod.Item("Петров", "Кто")]])
    assert sorted(d.tagger.seen[-1]) == ["Кто: Иванов", "Кто: Петров"], "ячейки разных строк — отдельные тексты"
    ctx.clean_segments(["Фамилия", "Иванов", "Имя", "Иван"])
    assert d.tagger.seen[-1] == ["Фамилия\nИванов\nИмя\nИван"], "строки сплошного текста — одним окном, с соседями"


def test_short_cells_of_a_row_go_together_long_ones_alone():
    d = CountingDetector()
    comment = "Очень длинный комментарий про работу отдела, где упомянута Оксана и ещё много разных слов. " * 2
    rows_mod.find_rows(_ctx(d), [[rows_mod.Item("Иванов И. И.", "Кто"), rows_mod.Item("12.03.85", "Родился"),
                                  rows_mod.Item(comment, "Комментарий")]])
    assert sorted(d.tagger.seen[-1], key=len) == ["Кто: Иванов И. И.; Родился: 12.03.85", "Комментарий: " + comment]


def test_number_next_to_a_person_in_a_row_is_hidden():
    d = CountingDetector({"Иванов": "LAST_NAME"})
    (cells,) = rows_mod.find_rows(_ctx(d), [[rows_mod.Item("Иванов И. И.", "Кто"), rows_mod.Item("4510000000", "Документ №"),
                                             rows_mod.Item("1 500 000", "Оклад"), rows_mod.Item("4510000001", "Сумма")]])
    assert [sp.kind for sp in cells[1]] == [Kind.ID]
    assert cells[2] == [] and cells[3] == [], "сумма остаётся: по виду числа и по заголовку"


def test_link_is_one_value_not_a_phone_and_a_password():
    text = "Ссылка: https://meet.example.com/j/89012345678?pwd=Qw7Ut3mBv8RcQe1ZsJ9w.1\nИдентификатор конференции: 890 1234 5678\nКод доступа: 135790"
    session = Session()
    out = _ctx(CountingDetector(), session).clean_text(text)
    assert out == "Ссылка: [ССЫЛКА_1]\nИдентификатор конференции: [НОМЕР_1]\nКод доступа: [СЕКРЕТ_1]"
    assert [e["original"] for e in session.mapping()][0].startswith("https://meet.example.com/j/")


def test_answers_are_remembered_per_window():
    d = CountingDetector({"Пётр Смирнов": "LAST_NAME"})
    _ctx(d).clean_text("Звонил Пётр Смирнов.")
    _ctx(d).clean_text("Звонил Пётр Смирнов.")
    assert d.model_calls == 1
    _ctx(d).clean_text("Звонил Пётр Смирнов. Перезвоню.")
    assert d.model_calls == 2

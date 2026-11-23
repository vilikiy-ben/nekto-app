"""Имена: разбор упоминаний, начальная форма, склейка упоминаний в одного человека."""
import pytest

from nekto_engine.kinds import Kind
from nekto_engine.names import nominative, parse
from nekto_engine.names.registry import compatible
from nekto_engine.session import Session
from nekto_engine.spans import Span


def _people(*mentions: str) -> list[str]:
    """Метки упоминаний, если они встретились в одном тексте (каждое — отдельным сегментом, область одна)."""
    s = Session()
    found = s.bind(list(mentions), [[Span(0, len(m), Kind.PERSON)] for m in mentions])
    return [spans[0].ref for spans in found]


SAME = [
    ("Ахмерова Гульнара Ильдаровна", "Ахмеровой Г. И."),
    ("Ахмерова Гульнара Ильдаровна", "Гуля Ахмерова"),
    ("Гиниятуллин Ильдар Маратович", "Гиниятуллина Ильдара Маратовича"),
    ("Гиниятуллин Ильдар Маратович", "Гиниятуллин И. М."),
    ("Тарасова Дарья Андреевна", "Тарасову Дарью Андреевну"),
    ("Камалов Ришат", "Ришат"),
    ("Ибрагимова Резеда", "Резеды"),
    ("NURIEVA GUZEL", "Нуриева Гузель Хамитовна"),
    ("Yunusov Azat", "Юнусов Азат Ильдусович"),
    ("Alsu Mansurova", "Мансурова Алсу Ринатовна"),
    ("Лёха Смирнов", "Смирнов Алексей"),
    # трудные случаи: падеж, порядок слов, ласкательные, несклоняемые
    ("Абдуллиной Еленой", "Лене Абдуллиной"),
    ("Веронике Сафоновой", "Сафонову Веронику"),
    ("Ольга Орлова", "Орлова Оля"),
    ("Ольга Орлова", "Оленька"),
    ("Федотовой Ульяны", "Федотовой Ульяна"),
    ("Шубин Константин", "Шубина"),
    ("Тен Романа Владимировича", "Тену"),
    ("Коломенская Злата", "Златы Коломенской"),
]
DIFFERENT = [
    ("Ахмерова Гульнара Ильдаровна", "Ахмеров Ильдар Ринатович"),
    ("Гиниятуллин Ильдар Маратович", "Гиниятуллина Алсу Ринатовна"),
    ("Michael O'Connor", "Michael Becker"),
    ("Алина", "Ирина Камалова"),
    # те самые ошибки склейки: общее имя или буква — не повод
    ("Жукова Варвара", "Варвары Кобза"),
    ("Константина Иволга", "Шубин Константин"),
    ("Ксении Зуевой", "Ксении Макаровой"),
]


@pytest.mark.parametrize("a,b", SAME)
def test_same_person(a, b):
    first, second = _people(a, b)
    assert first == second


@pytest.mark.parametrize("a,b", DIFFERENT)
def test_different_people(a, b):
    first, second = _people(a, b)
    assert first != second


def test_bare_first_name_joins_only_within_its_scope():
    """«Спасибо Ксении» в одной строке таблицы и «Ксения Зуева» в другой — разные записи; в одной — один человек."""
    s = Session()
    segments = ["Ксении", "Ксения Зуева", "Ксюша"]
    spans = [[Span(0, len(x), Kind.PERSON)] for x in segments]
    apart = [sp[0].ref for sp in s.bind(segments, spans, scopes=[1, 2, 2])]
    assert apart[0] != apart[1] and apart[1] == apart[2]


def test_bare_first_name_is_one_value_not_one_person():
    """Одно имя без фамилии в разных строках — одна метка «Ксения»: это значение, а не утверждение о человеке."""
    s = Session()
    segments = ["Ксении", "Ксению", "Ксения Зуева"]
    refs = [sp[0].ref for sp in s.bind(segments, [[Span(0, len(x), Kind.PERSON)] for x in segments], scopes=[1, 2, 3])]
    assert refs[0] == refs[1] != refs[2]
    assert {e["original"] for e in s.mapping()} == {"Ксения", "Ксения Зуева"}


def test_order_of_mentions_does_not_matter():
    """Короткое упоминание раньше полного: результат тот же, что и в обратном порядке."""
    assert len(set(_people("Лене", "Абдуллина Елена"))) == 1
    assert len(set(_people("Абдуллина Елена", "Лене"))) == 1


def test_two_people_with_one_surname_stay_apart():
    a, b, c = _people("Иванов Иван", "Иванов Игорь", "Иванов И.")
    assert a != b and c not in (a, b), "«Иванов И.» при двух Ивановых на «И» — неоднозначно, отдельная метка"


def test_session_merges_mentions_and_phones():
    s = Session()
    p1 = s.placeholder(Kind.PERSON, "Ахмерова Гульнара Ильдаровна")
    assert s.placeholder(Kind.PERSON, "Ахмеровой Г. И.") == p1
    assert s.placeholder(Kind.PERSON, "Гиниятуллин Ильдар") != p1
    t1 = s.placeholder(Kind.PHONE, "8 900 555-01-48")
    assert s.placeholder(Kind.PHONE, "+79005550148") == t1
    entry = next(e for e in s.mapping() if e["placeholder"] == p1)
    assert entry["original"] == "Ахмерова Гульнара Ильдаровна"


def test_ambiguous_first_name_is_not_glued():
    s = Session()
    a = s.placeholder(Kind.PERSON, "Ильдар Гиниятуллин")
    b = s.placeholder(Kind.PERSON, "Ильдар Сафиуллин")
    c = s.placeholder(Kind.PERSON, "Ильдар")
    assert c not in (a, b)


@pytest.mark.parametrize("src,expected", [
    ("Нурлыгаянова Рамиля Фаритовича", "Нурлыгаянов Рамиль Фаритович"),
    ("Ахмеровой Г. И.", "Ахмерова Г. И."),
    ("Ахмерова Г. И.", "Ахмерова Г. И."),
    ("Тарасову Дарью Андреевну", "Тарасова Дарья Андреевна"),
    ("Петрову Дмитрию Олеговичу", "Петров Дмитрий Олегович"),
    ("Гиниятуллин Ильдар Маратович", "Гиниятуллин Ильдар Маратович"),
    ("John Smith", "John Smith"),
    ("Ильназ", "Ильназ"),
    ("Мансуровой", "Мансурова"),
    # согласование рода и падежа между словами: «Жене» + «Ольшанской» → «Женя Ольшанская», а не «Жене Ольшанская»
    ("Жене Ольшанской", "Женя Ольшанская"),
    ("Полины Свешкиной", "Полина Свешкина"),
    ("Давлетшин Ринат", "Давлетшин Ринат"),
    ("Сафонову Веронику", "Сафонова Вероника"),
    ("Олесе Фоминой", "Олеся Фомина"),
    ("Юле Соболевой", "Юля Соболева"),
    ("Нелли Зотову", "Нелли Зотова"),
    ("Петровой Светы", "Петрова Света"),
    ("Ершовой-Ширшиной", "Ершова-Ширшина"),
    ("Ахмерова Гульнара Ильдаровна", "Ахмерова Гульнара Ильдаровна"),
    # фамилию вне словаря в живом тексте часто не склоняют — придумывать форму нельзя
    ("Константина Иволга", "Константин Иволга"),
    ("Варвары Кобза", "Варвара Кобза"),
    ("Тен Романа Владимировича", "Тен Роман Владимирович"),
    ("Саркисян Армену", "Саркисян Армен"),
    ("Фоминых Наталья", "Фоминых Наталья"),
    ("Федотовой Ульяна", "Федотова Ульяна"),
    ("ИВАНОВА МАРИЯ ПЕТРОВНА", "ИВАНОВА МАРИЯ ПЕТРОВНА"),
])
def test_nominative(src, expected):
    assert nominative(src) == expected


@pytest.mark.parametrize("text,roles", [
    ("Юшкевич Алексей", ["surname", "first"]),          # -евич перед именем — фамилия, а не отчество
    ("Борис Абрамович", ["first", "patr"]),
    ("Абрамович Роман", ["surname", "first"]),
    ("Сафонову Веронику", ["surname", "first"]),
    ("Евстигнеевым П.", ["surname", "initial"]),
    ("Танюшу К.", ["first", "initial"]),
])
def test_roles(text, roles):
    assert [p.role for p in parse(text).parts] == roles


def test_compatible_respects_initials_and_gender():
    assert compatible(parse("Иванов И. П.").person, parse("Иванов Иван Петрович").person)
    assert not compatible(parse("Иванов С. П.").person, parse("Иванов Иван Петрович").person)
    assert not compatible(parse("Иванова Мария").person, parse("Иванов Иван").person)


def test_nfd_filename_matches_person():
    import unicodedata
    s = Session()
    p = s.placeholder(Kind.PERSON, "Мансурова Алсу Ринатовна")
    assert s.placeholder(Kind.PERSON, unicodedata.normalize("NFD", "Мансуровой")) == p


def test_user_overrides():
    s = Session()
    text = "Продукт Медведь-Софт внедряет Олег Кузнецов, договор ЛС-77"
    spans = [Span(8, 20, Kind.OTHER), Span(30, 43, Kind.PERSON)]
    first = s.apply(text, s.adjust(text, spans))
    assert "Медведь-Софт" not in first and "Олег Кузнецов" not in first and "ЛС-77" in first
    ph = next(e["placeholder"] for e in s.mapping() if e["original"] == "Медведь-Софт")
    s.allow(ph)                 # ложное срабатывание: это продукт, не человек
    s.force("лс-77", Kind.ID)   # пропущено моделью
    second = s.apply(text, s.adjust(text, spans))
    assert "Медведь-Софт" in second and "Олег Кузнецов" not in second and "ЛС-77" not in second
    assert next(e for e in s.mapping() if e["placeholder"] == ph)["allowed"] is True
    s.unallow(ph)
    assert "Медведь-Софт" not in s.apply(text, s.adjust(text, spans))

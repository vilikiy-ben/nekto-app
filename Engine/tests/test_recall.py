"""Полнота: по тесту на каждую найденную причину пропусков. Все люди и номера вымышлены.

Здесь — то, что не должно вернуться.
"""
import json
import threading
import zipfile

from nekto_engine.formats import Context, process
from nekto_engine.formats.plaintext import clean_lines
from nekto_engine.kinds import Kind
from nekto_engine.session import Session

PEOPLE = ["Белый П. А.", "Соловей К. Д.", "Вьюга Г. Е.", "Тен Р. В.", "Мороз А. С.", "Волк Д. И.", "Гладкий О. Н.",
          "Иванова М. П.", "Петросян А. Г.", "Шевченко Б. В.", "Ким Е. Р.", "Черных Л. М.", "Бикбаева Р. Р.",
          "Карпов Р. В.", "Долгих И. Р.", "Толстая В. А.", "Нуриев Т. И.", "Ковальская Л. А.", "Седых К. М.",
          "Абдуллаев Р. Р."]


def _people_rows(n):
    rows = []
    for i in range(n):
        p = PEOPLE[i % len(PEOPLE)]
        rows.append((p, f"{(i % 27) + 1:02d}.{(i % 12) + 1:02d}.{60 + i % 40}", f"8916{1000000 + i * 7919:07d}"))
    return rows


def test_full_name_not_cut_to_surname(ctx):
    """flat: «Козлова» побеждало «Козлова Сергея Николаевича», имя и отчество оставались."""
    text = ("Районный суд в составе судьи Киселёвой З. Л., рассмотрев дело по иску Козлова Сергея Николаевича "
            "к Долгих Ильдару Руслановичу о взыскании задолженности, УСТАНОВИЛ: истец Козлов С. Н. обратился в суд. "
            "РЕШИЛ: взыскать с Долгих Ильдара Руслановича в пользу Козлова 1 200 000 руб.")
    out = ctx.clean_text(text)
    for leak in ("Сергея", "Николаевича", "Ильдару", "Руслановичу", "Ильдара", "Козлов", "Долгих"):
        assert leak not in out, out


def test_dense_list(ctx):
    """60 коротких строк в одном окне упирались в лимит кандидатов модели: находилась треть ФИО."""
    rows = _people_rows(60)
    out = ctx.clean_text("\n".join(f"{p} {d} {ph}" for p, d, ph in rows))
    leaked = [v for row in rows for v in row if v in out]
    assert len(leaked) <= 2, leaked


def test_pasted_excel_table(ctx):
    """Вставка из Excel: табуляция, заголовки, которых классификатор не знает. Строкой с заголовками — всё."""
    head = "Кто\tРодился\tСвязь\tГде живёт"
    lines = [head] + [f"{p}\t{d}\t{ph}\tул. Мира, {i + 3}" for i, (p, d, ph) in enumerate(_people_rows(25))]
    out = clean_lines("\n".join(lines), ctx)
    assert out.splitlines()[0] == head
    leaked = [x for line in lines[1:] for x in line.split("\t") if x in out]
    assert not leaked, leaked
    assert "[ДР_" in out


def test_xlsx_numbers_in_unknown_columns(tmp_path, ctx, out_dir):
    """Телефоны и паспорта, сохранённые Excel как числа, в столбце с непонятным заголовком не проверял никто."""
    import datetime as dt

    import openpyxl
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.append(["Кто", "Связь", "Документ", "Родился", "Сумма"])
    for i, (p, _d, ph) in enumerate(_people_rows(15)):
        ws.append([p, int(ph), 4510000000 + i * 1013, dt.date(1980 + i, 3, 1 + i), 1500 + i])
    src = tmp_path / "выгрузка.xlsx"
    wb.save(src)
    res = process(src, out_dir, ctx)
    vals = [str(v) for row in openpyxl.load_workbook(res.output).active.iter_rows(min_row=2, values_only=True) for v in row]
    text = " ".join(vals)
    for i, (p, _d, ph) in enumerate(_people_rows(15)):
        assert ph not in text and str(4510000000 + i * 1013) not in text and p not in text, text
    assert "1500" in text, "суммы не должны скрываться"
    assert "[ДР_" in text


def test_docx_table_uses_headers(tmp_path, ctx, out_dir):
    """В DOCX заголовок «Паспорт» ничего не значил: ячейки шли в модель по одной и упирались в лимит."""
    import docx
    d = docx.Document()
    rows = _people_rows(40)
    t = d.add_table(rows=len(rows) + 1, cols=3)
    for c, h in enumerate(["ФИО", "Паспорт", "Адрес"]):
        t.cell(0, c).text = h
    for r, (p, _d, _ph) in enumerate(rows, 1):
        t.cell(r, 0).text = p
        t.cell(r, 1).text = f"45 {10 + r % 9} {100000 + r * 37}"
        t.cell(r, 2).text = f"ул. Ленина, д. {r}"
    src = tmp_path / "список.docx"
    d.save(src)
    res = process(src, out_dir, ctx)
    with zipfile.ZipFile(res.output) as z:
        text = z.read("word/document.xml").decode()
    leaked = [f"45 {10 + r % 9} {100000 + r * 37}" for r in range(1, len(rows) + 1) if f"{100000 + r * 37}" in text]
    assert not leaked, leaked
    assert "ул. Ленина, д. 7<" not in text
    assert ">Паспорт<" in text, "заголовок остаётся"


def test_json_record_rows(tmp_path, ctx, out_dir):
    src = tmp_path / "clients.json"
    src.write_text(json.dumps([{"кто": "Мороз Алексей Сергеевич", "связь": 79161234567, "заказов": 12},
                               {"кто": "Белый Павел", "связь": 79035550199, "заказов": 3}], ensure_ascii=False))
    out = process(src, out_dir, ctx).output.read_text()
    assert "79161234567" not in out and "79035550199" not in out and "Мороз" not in out and "Белый" not in out
    assert '"заказов": 12' in out


def test_birthdate_survives_keep_dates(detector):
    """«Оставить даты» открывал и даты рождения: тип был один."""
    session = Session()
    session.set_keep({Kind.DATE})
    ctx = Context(detector, session, threading.Event(), lambda _: None)
    out = ctx.clean_text("Работник Гарипов Ильнур Ринатович, 14.02.1988 г.р., принят 03.03.2025. "
                         "Дата рождения супруги: 21.07.1990.")
    assert "03.03.2025" in out
    assert "14.02.1988" not in out and "21.07.1990" not in out
    assert "[ДР_" in out


def test_short_dates_have_rule(ctx):
    out = ctx.clean_text("Сверка: 25.10.81, 06.12.75 и 1985-03-12, а также 7 апреля 1977.")
    for d in ("25.10.81", "06.12.75", "1985-03-12", "7 апреля 1977"):
        assert d not in out, out


def test_found_once_hidden_everywhere(ctx):
    """Модель узнаёт человека в одном абзаце и пропускает в другом — значение из таблицы меток закрывает все."""
    out = ctx.clean_text("Кладовщик Тен Роман Владимирович работает с 2019 года.\n\n"
                         "Охранник видел, как Тен выносит коробки. Тену предложено дать объяснение.")
    assert "Тен" not in out and "Тену" not in out, out
    # и в следующем документе той же обработки
    out2 = ctx.clean_text("Объяснение Тена приложено.")
    assert "Тена" not in out2, out2


def test_lowercase_word_is_not_a_person(ctx):
    ctx.clean_text("Договор подписал Белый Павел Андреевич.")
    out = ctx.clean_text("Стены покрасить в белый цвет.")
    assert "белый цвет" in out


def test_force_whole_word():
    """Ручное «Скрыть» искало подстроку: «Ким» резал «Кимоно» и «сакимы»."""
    s = Session()
    s.force("Ким", Kind.PERSON)
    seg = "Кимоно и сакимы, Ким нет"
    assert s.apply(seg, s.adjust(seg, [])) == "Кимоно и сакимы, [ФИО_1] нет"


def test_reset_forgets_known_values(ctx):
    ctx.clean_text("Договор подписал Бикбаев Ильнур Ринатович.")
    ctx.session.reset()
    out = ctx.clean_text("Версия Бикбаев-2 выпущена.")
    assert "Бикбаев" in out, out


# ---------- учётные записи и заголовки реплик (контрольный набор) ----------

def test_account_built_from_a_known_surname():
    from nekto_engine import recall
    from nekto_engine.kinds import Kind
    from nekto_engine.spans import Span
    segs = ["Приказ подготовила Шевчук Лариса Андреевна", " 09:02:11 | shevchuk_la | UPDATE employee", "письмо от kravets.n@example.org",
            "10482;kravets.n;бухгалтер", "сервер app-03.prod, файл docker-compose.override.yml"]
    found = [[Span(19, 42, Kind.PERSON, 1.0, "names")], [], [Span(10, 31, Kind.EMAIL, 1.0, "rule")], [], []]
    known = recall.Known()
    known.add(Kind.PERSON, "Шевчук Лариса Андреевна")
    known.add(Kind.EMAIL, "kravets.n@example.org")
    out = recall.extend(segs, found, [known])
    assert [(segs[1][s.start:s.end], s.kind) for s in out[1]] == [("shevchuk_la", Kind.HANDLE)]
    assert [(segs[3][s.start:s.end], s.kind) for s in out[3]] == [("kravets.n", Kind.HANDLE)]
    assert out[4] == []


def test_message_headers_of_a_chat_export():
    from nekto_engine import recall
    segs = ["Daniyar Seitkali  10:07", "Роман с этим согласен", "Белый Стас 10:31", "Белый список обновили", "Сегодня 10:40"]
    out = recall.speakers(segs, [[] for _ in segs])
    assert [[seg[s.start:s.end] for s in spans] for seg, spans in zip(segs, out)] == [["Daniyar Seitkali"], [], ["Белый Стас"], [], []]


def test_rare_name_and_latin_surname_of_a_known_person():
    from nekto_engine import recall
    from nekto_engine.kinds import Kind
    known = recall.Known()
    known.add(Kind.PERSON, "Рахимов Фаррух Саидович")
    known.add(Kind.PERSON, "Бондарь Олег")
    segs = ["михалыч а фаррух где жить будет?", "Give Bondar a raise.", "вера в команду и надежда на лучшее"]
    out = recall.extend(segs, [[], [], []], [known])
    assert [[seg[s.start:s.end] for s in spans] for seg, spans in zip(segs, out)] == [["фаррух"], ["Bondar"], []]

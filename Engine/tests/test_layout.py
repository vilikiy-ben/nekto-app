"""Вид документа для редактора (formats/layout.py): форма каждого формата, служебные части и отсутствие ПДн в самом виде."""
import json
from email.message import EmailMessage

import pytest

from nekto_engine.formats import layout as L
from nekto_engine.formats import process, views

PII = ["Гиниятуллин", "Ахмеров", "Тарасов", "+7 900 555-00-55", "79005550055", "i.giniyatullin@brightline-soft.example", "9209 446712"]


def blocks_of(kind, blocks):
    """Все блоки типа `kind`, включая вложенные в разделы."""
    out = []
    for b in blocks:
        if b["type"] == kind:
            out.append(b)
        if b["type"] == "section":
            out += blocks_of(kind, b["blocks"])
    return out


def sections(blocks, kind=None):
    return [b for b in blocks_of("section", blocks) if kind is None or b["kind"] == kind]


def no_pii(view):
    dumped = json.dumps(view, ensure_ascii=False)
    leaked = [p for p in PII if p in dumped]
    assert not leaked, f"утечка в виде: {leaked}"


# MARK: Без модели

def test_text_blocks_lists_tables_and_paragraphs():
    text = ("Итоги встречи\n\n- первый пункт\n  - вложенный\n1.1. Работник принимается на должность\n"
            "ФИО\tТелефон\tОтдел\n[ФИО_1]\t[ТЕЛЕФОН_1]\tПродажи\n[ФИО_2]\t[ТЕЛЕФОН_2]\tСклад\n\nКонец")
    blocks = views.text_blocks(text)
    kinds = [b["type"] for b in blocks]
    assert kinds == ["paragraph", "item", "item", "item", "table", "paragraph"]
    assert blocks[2]["level"] == 1 and blocks[3]["marker"] == "1.1."
    assert blocks[4]["header"] and blocks[4]["rows"][1] == ["[ФИО_1]", "[ТЕЛЕФОН_1]", "Продажи"]


def test_markdown_only_when_it_looks_like_markdown():
    assert views.text_blocks("# 5 в списке ожидания\nтекст")[0]["type"] == "paragraph"
    md = "# План\n\n## Сроки\n\n| Кто | Что |\n|---|---|\n| [ФИО_1] | отчёт |\n\n```\nкод\n```"
    blocks = views.text_blocks(md)
    assert [b["type"] for b in blocks] == ["heading", "heading", "table", "code"]
    assert blocks[2]["header"] and blocks[2]["rows"] == [["Кто", "Что"], ["[ФИО_1]", "отчёт"]]


def test_key_value_table_has_no_header():
    rows = [["Работодатель", "АО «Ромашка»"], ["Работник", "[ФИО_1]"], ["Руководитель", "[ФИО_2]"]]
    assert not L.looks_like_header(rows)
    assert L.looks_like_header([["ФИО", "Телефон", "Отдел"], ["[ФИО_1]", "[ТЕЛЕФОН_1]", "Склад"]])
    assert not L.looks_like_header([["Иванов", "+7 900 000-00-00"], ["Петров", "+7 900 000-00-01"]])


def test_html_blocks():
    html = ("<html><head><title>x</title><style>p{}</style></head><body><h1>Отчёт</h1><p>Текст\nв две строки<br>и перенос</p>"
            "<ul><li>раз</li><li>два</li></ul><ol><li>первый</li></ol>"
            "<table><tr><th>Кто</th><th>Где</th></tr><tr><td>[ФИО_1]</td><td>Казань</td></tr></table>"
            "<script>var a = 1</script></body></html>")
    blocks = views.html_blocks(html)
    assert [b["type"] for b in blocks] == ["heading", "paragraph", "paragraph", "item", "item", "item", "table"]
    assert blocks[1]["text"] == "Текст в две строки"
    assert blocks[5]["marker"] == "1."
    assert blocks[6]["header"] and blocks[6]["rows"][1] == ["[ФИО_1]", "Казань"]
    assert "var a" not in json.dumps(blocks, ensure_ascii=False)


def test_budget_cuts_big_tables_but_keeps_asides(monkeypatch):
    monkeypatch.setattr(L, "MAX_CELLS", 100)
    rows = [[f"r{i}", "x", "y", "z"] for i in range(60)]
    view = L.finish([L.table(rows, header=True), L.paragraph("после таблицы"),
                     L.section("aside", "Колонтитулы", [L.paragraph("[ФИО_1]")], copy=False)])
    table, rest_note, aside = view["blocks"][0], view["blocks"][-1], view["blocks"][1]
    assert len(table["rows"]) == 25 and table["more"] == 35
    assert aside["kind"] == "aside"                       # служебные части видны всегда
    assert rest_note["type"] == "note" and "1" in rest_note["text"]


def test_budget_counts_table_text(monkeypatch):
    # Лист с длинными отзывами: ячеек мало, а текста много — режется по символам, а не по числу ячеек.
    monkeypatch.setattr(L, "MAX_TEXT", 1_000)
    rows = [[f"r{i}", "отзыв " * 30] for i in range(20)]
    view = L.finish([L.table(rows, header=False, row_labels=[str(i + 1) for i in range(20)])])
    table = view["blocks"][0]
    assert 1 <= len(table["rows"]) < 20 and table["more"] == 20 - len(table["rows"])
    assert len(table["row_labels"]) == len(table["rows"])


def test_markdown_copy_text():
    blocks = [L.heading("Отчёт"), L.item("раз"), L.item("два"), L.table([["А", "Б|В"], ["1", "2\n3"]], header=True),
              L.section("aside", "Колонтитулы", [L.paragraph("[ФИО_1]")], copy=False),
              L.section("meta", "Свойства файла", [L.fields([("Автор", "[ФИО_2]")])])]
    md = L.to_markdown(blocks)
    assert md.startswith("# Отчёт\n\n- раз\n- два\n\n| А | Б\\|В |")
    assert "| 1 | 2 3 |" in md
    assert "[ФИО_1]" not in md and "[ФИО_2]" not in md     # колонтитулы и свойства в буфер не идут


def test_safely_returns_none_on_error(capsys):
    def broken():
        raise KeyError("Иванов Иван")
    assert L.safely(broken) is None
    assert "Иванов" not in capsys.readouterr().err        # в журнал — только тип ошибки


# MARK: Файлы (нужна модель)

def test_docx_view(tmp_path, ctx, out_dir):
    docx = pytest.importorskip("docx")
    d = docx.Document()
    d.core_properties.author = "Гиниятуллин Ильдар"
    d.sections[0].header.paragraphs[0].text = "Brightline Works · исполнитель Ахмерова Г. И."
    d.add_heading("Приказ о командировке", level=1)
    d.add_paragraph("Направить Гиниятуллина Ильдара Маратовича в ПАО «ПРИМЕРТЕХ».")
    d.add_paragraph("Купить билеты", style="List Number")
    d.add_paragraph("Забронировать гостиницу", style="List Number")
    t = d.add_table(rows=2, cols=3)
    for i, v in enumerate(["ФИО", "Телефон", "Отдел", "Тарасова Дарья Андреевна", "+7 900 555-00-55", "Склад"]):
        t.cell(i // 3, i % 3).text = v
    src = tmp_path / "Приказ.docx"; d.save(src)
    res = process(src, out_dir, ctx)
    no_pii(res.layout)
    kinds = [b["type"] for b in res.layout]
    assert kinds[:5] == ["heading", "paragraph", "item", "item", "table"]
    items = blocks_of("item", res.layout)
    assert [i["marker"] for i in items] == ["1.", "2."]
    table = blocks_of("table", res.layout)[0]
    assert table["header"] and table["rows"][1][0].startswith("[ФИО_")
    head = sections(res.layout, "aside")[0]
    assert head["title"] == "Колонтитулы" and "[ФИО_" in head["blocks"][0]["text"]
    meta = sections(res.layout, "meta")[0]
    assert meta["blocks"][0]["rows"][0][0] == "Автор"
    assert "| ФИО | Телефон | Отдел |" in res.preview        # в буфер — таблица Markdown, без колонтитулов
    assert "Brightline Works · исполнитель" not in res.preview


def test_xlsx_view(tmp_path, ctx, out_dir):
    openpyxl = pytest.importorskip("openpyxl")
    from datetime import date
    from openpyxl.comments import Comment
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = "Сотрудники"
    ws.append(["ФИО", "Телефон", "Выезд", "Сумма"])
    ws.append(["Гиниятуллин Ильдар Маратович", 79005550055, date(2025, 5, 19), 187400])
    ws.append([None, None, None, None])
    ws.append(["Тарасова Дарья Андреевна", "+7 900 555-00-55", date(2025, 6, 2), 99000])
    ws["A2"].comment = Comment("Согласовано с Ахмеровой Г. И.", "Гиниятуллин И.")
    hidden = wb.create_sheet("Служебный"); hidden.sheet_state = "hidden"
    hidden.append(["Паспорт 9209 446712, Ахмерова Г. И."])
    src = tmp_path / "t.xlsx"; wb.save(src)
    res = process(src, out_dir, ctx)
    no_pii(res.layout)
    sheets = sections(res.layout, "sheet")
    assert [s["title"] for s in sheets] == ["Сотрудники", "Служебный · скрытый лист"]
    table = blocks_of("table", sheets[0]["blocks"])[0]
    assert table["header"] and table["row_labels"] == ["1", "2", "4"]   # номера строк Excel, пустая строка пропущена
    assert table["rows"][1][3] == "187400" and table["rows"][1][0] == "[ФИО_1]"
    notes = sections(sheets[0]["blocks"], "aside")[0]
    label, text = notes["blocks"][0]["rows"][0]
    assert label.startswith("A2 · [ФИО_") and "[ФИО_" in text


def test_pptx_view(tmp_path, ctx, out_dir):
    pptx = pytest.importorskip("pptx")
    prs = pptx.Presentation()
    first = prs.slides.add_slide(prs.slide_layouts[1])
    first.shapes.title.text = "Проект Brightline Works × ПАО «ПРИМЕРТЕХ»"
    first.placeholders[1].text = "Руководитель: Гиниятуллин Ильдар Маратович\nТелефон: +7 900 555-00-55"
    first.notes_slide.notes_text_frame.text = "Напомнить Ахмеровой Г. И. про паспорт 9209 446712"
    second = prs.slides.add_slide(prs.slide_layouts[5])
    second.shapes.title.text = "Сроки"
    # второй слайд в показе идёт первым: порядок — по presentation.xml, а не по номерам файлов
    ids = prs.slides._sldIdLst
    ids.insert(0, ids[-1])
    src = tmp_path / "p.pptx"; prs.save(src)
    res = process(src, out_dir, ctx)
    no_pii(res.layout)
    slides = sections(res.layout, "slide")
    assert [s["title"] for s in slides] == ["Слайд 1", "Слайд 2"]
    assert slides[0]["blocks"][0]["text"] == "Сроки"
    body = slides[1]["blocks"]
    assert body[0]["type"] == "heading" and [b["type"] for b in body[1:3]] == ["item", "item"]
    notes = sections(body, "aside")[0]
    assert notes["title"] == "Заметки докладчика" and "[ПАСПОРТ_" in notes["blocks"][0]["text"]
    assert res.preview.startswith("## Слайд 1")


def test_csv_eml_json_views(tmp_path, ctx, out_dir):
    csv_src = tmp_path / "r.csv"
    csv_src.write_text("ФИО;Телефон;Сумма\nГиниятуллин Ильдар Маратович;+7 900 555-00-55;12 450,00\n", encoding="utf-8")
    res = process(csv_src, out_dir, ctx)
    no_pii(res.layout)
    assert res.layout[0]["type"] == "table" and res.layout[0]["header"]
    assert res.layout[0]["rows"][1][2] == "12 450,00"

    m = EmailMessage()
    m["From"] = "Гиниятуллин Ильдар <i.giniyatullin@brightline-soft.example>"
    m["Subject"] = "Командировка"
    m.set_content("Добрый день!\n\nТелефон +7 900 555-00-55.")
    m.add_attachment(b"x", maintype="application", subtype="pdf", filename="scan.pdf")
    eml = tmp_path / "m.eml"; eml.write_bytes(bytes(m))
    res = process(eml, out_dir, ctx)
    no_pii(res.layout)
    head = res.layout[0]
    assert head["type"] == "fields" and head["rows"][0][0] == "От" and head["rows"][1] == ["Тема", "Командировка"]
    assert res.layout[-1]["type"] == "note"

    js = tmp_path / "e.json"
    js.write_text(json.dumps({"name": "Гиниятуллин Ильдар Маратович"}, ensure_ascii=False), encoding="utf-8")
    res = process(js, out_dir, ctx)
    no_pii(res.layout)
    assert res.layout == [{"type": "code", "text": res.output.read_text(encoding="utf-8"), "lang": "json"}]

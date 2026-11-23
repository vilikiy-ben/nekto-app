"""Сквозные тесты форматов: ни одна исходная строка ПДн не должна остаться ни в одном файле архива."""
import json
import zipfile
from email.message import EmailMessage

import pytest

from nekto_engine.formats import process

PII = ["Гиниятуллин", "Ахмеров", "Тарасов", "+7 900 555-00-55", "79005550055", "i.giniyatullin@brightline-soft.example",
       "9209 446712", "Баумана", "165912873405"]
KEEP = ["Brightline Works", "Руководитель проекта", "ПРИМЕРТЕХ"]


def all_text(path):
    if path.suffix == ".eml":
        from email import policy
        from email.parser import BytesParser
        msg = BytesParser(policy=policy.default).parsebytes(path.read_bytes())
        parts = [f"{k}: {v}" for k, v in msg.items()]
        parts += [p.get_content() for p in msg.walk() if p.get_content_maintype() == "text"]
        return "\n".join(parts)
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            return "\n".join(z.read(n).decode("utf-8", "ignore") for n in z.namelist())
    return path.read_text(encoding="utf-8", errors="ignore")


def assert_clean(path, pii=PII, keep=KEEP):
    text = all_text(path)
    leaked = [p for p in pii if p in text]
    assert not leaked, f"утечка: {leaked}"
    for k in keep:
        assert k in text, f"потеряно: {k}"
    assert "[ФИО_" in text


def test_csv(tmp_path, ctx, out_dir):
    src = tmp_path / "staff.csv"
    src.write_text(
        "таб_номер;фио;должность;телефон;email;паспорт;адрес;комментарий\n"
        "00731;Гиниятуллин Ильдар Маратович;Руководитель проекта;+7 900 555-00-55;i.giniyatullin@brightline-soft.example;"
        "9209 446712;г. Казань, ул. Баумана, д. 37, кв. 12;Командировка в ПАО «ПРИМЕРТЕХ» с Ахмеровой Г. И., Brightline Works\n"
        "01288;Тарасова Дарья Андреевна;Аналитик;89600471932;d.tarasova@brightline-soft.example;4517 093821;Казань;ИНН 165912873405\n",
        encoding="utf-8")
    res = process(src, out_dir, ctx)
    assert_clean(res.output)
    lines = res.output.read_text(encoding="utf-8").splitlines()
    assert lines[0].startswith("таб_номер;фио")          # заголовок не тронут
    assert lines[1].split(";")[1] == "[ФИО_1]"


def test_docx(tmp_path, ctx, out_dir):
    docx = pytest.importorskip("docx")
    d = docx.Document()
    d.core_properties.author = "Гиниятуллин Ильдар"
    d.sections[0].header.paragraphs[0].text = "Brightline Works · исполнитель Ахмерова Г. И."
    p = d.add_paragraph("Руководитель проекта ")
    p.add_run("Гиниятуллин").bold = True          # ФИО разбито на runs с разным форматированием
    p.add_run(" Ильдар Маратович, тел. +7 900 555-00-55, ")
    p.add_run("i.giniyatullin@brightline-soft.example").italic = True
    t = d.add_table(rows=1, cols=2)
    t.cell(0, 0).text = "Паспорт 9209 446712"
    t.cell(0, 1).text = "г. Казань, ул. Баумана, д. 37, кв. 12; поездка в ПАО «ПРИМЕРТЕХ»"
    d.add_paragraph("Тарасова Дарья, ИНН 165912873405")
    src = tmp_path / "doc.docx"; d.save(src)
    res = process(src, out_dir, ctx)
    assert_clean(res.output)
    out = docx.Document(res.output)                  # файл валиден
    runs = out.paragraphs[0].runs
    assert runs[1].bold and runs[1].text.startswith("[ФИО_")   # форматирование сохранено
    assert out.core_properties.author.startswith("[ФИО_")


def test_xlsx(tmp_path, ctx, out_dir):
    openpyxl = pytest.importorskip("openpyxl")
    from openpyxl.comments import Comment
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = "Сотрудники"
    ws.append(["ФИО", "Должность", "Телефон", "Комментарий", "Сумма"])
    ws.append(["Гиниятуллин Ильдар Маратович", "Руководитель проекта", 79005550055, "Командировка в ПАО «ПРИМЕРТЕХ», Brightline Works", 187400])
    ws.append(["Тарасова Дарья Андреевна", "Руководитель проекта", "+7 900 555-00-55", "паспорт 9209 446712, ул. Баумана, д. 37, кв. 12", 99000])
    ws["D2"].comment = Comment("Согласовано с Ахмеровой Г. И.", "Гиниятуллин И.")
    wb.properties.creator = "Гиниятуллин Ильдар"
    src = tmp_path / "t.xlsx"; wb.save(src)
    res = process(src, out_dir, ctx)
    assert_clean(res.output)
    out = openpyxl.load_workbook(res.output).active
    assert out["A2"].value == "[ФИО_1]" and out["E2"].value == 187400 and out["B2"].value == "Руководитель проекта"
    assert str(out["C2"].value).startswith("[ТЕЛЕФОН_")
    assert out["C2"].value == out["C3"].value         # один номер в разных записях → одна метка


def test_pptx(tmp_path, ctx, out_dir):
    pptx = pytest.importorskip("pptx")
    prs = pptx.Presentation()
    s = prs.slides.add_slide(prs.slide_layouts[1])
    s.shapes.title.text = "Проект Brightline Works × ПАО «ПРИМЕРТЕХ»"
    s.placeholders[1].text = "Руководитель проекта: Гиниятуллин Ильдар Маратович, +7 900 555-00-55"
    s.notes_slide.notes_text_frame.text = "Напомнить Ахмеровой Г. И. про паспорт 9209 446712"
    src = tmp_path / "p.pptx"; prs.save(src)
    res = process(src, out_dir, ctx)
    assert_clean(res.output)
    pptx.Presentation(res.output)


def test_json(tmp_path, ctx, out_dir):
    src = tmp_path / "e.json"
    src.write_text(json.dumps({"employee": {"full_name": "Гиниятуллин Ильдар Маратович", "phone": 79005550055,
                                            "position": "Руководитель проекта",
                                            "note": "Летит в ПАО «ПРИМЕРТЕХ» от Brightline Works, паспорт 9209 446712"}},
                              ensure_ascii=False, indent=2), encoding="utf-8")
    res = process(src, out_dir, ctx)
    assert_clean(res.output)
    data = json.loads(res.output.read_text(encoding="utf-8"))
    assert data["employee"]["position"] == "Руководитель проекта"


def test_html(tmp_path, ctx, out_dir):
    src = tmp_path / "m.html"
    src.write_text('<html><head><style>.a{color:red}</style></head><body><p>Уважаемый <b>Гиниятуллин Ильдар Маратович</b>!</p>'
                   '<p>Руководитель проекта Brightline Works, поездка в ПАО «ПРИМЕРТЕХ».</p>'
                   '<a href="tel:+79005550055">+7 900 555-00-55</a> <a href="mailto:i.giniyatullin@brightline-soft.example">почта</a>'
                   '<!-- подготовила Ахмерова Г. И. --></body></html>', encoding="utf-8")
    res = process(src, out_dir, ctx)
    assert_clean(res.output)
    assert ".a{color:red}" in res.output.read_text(encoding="utf-8")


def test_eml(tmp_path, ctx, out_dir):
    m = EmailMessage()
    m["From"] = "Гиниятуллин Ильдар <i.giniyatullin@brightline-soft.example>"
    m["To"] = "Ахмерова Гульнара <g.akhmerova@brightline.example>"
    m["Subject"] = "Командировка в ПАО «ПРИМЕРТЕХ» — Brightline Works"
    m.set_content("Руководитель проекта: Гиниятуллин Ильдар Маратович, тел. +7 900 555-00-55, паспорт 9209 446712.")
    m.add_attachment(b"secret", maintype="application", subtype="octet-stream", filename="passport.pdf")
    src = tmp_path / "mail.eml"; src.write_bytes(bytes(m))
    res = process(src, out_dir, ctx)
    assert_clean(res.output, pii=PII + ["g.akhmerova@brightline.example"])
    assert "passport.pdf" not in res.output.read_text(encoding="utf-8", errors="ignore")
    assert res.preview.splitlines()[0].startswith("From: [ФИО_")
    from email import policy
    from email.parser import BytesParser
    out = BytesParser(policy=policy.default).parsebytes(res.output.read_bytes())
    assert "[ФИО_" in str(out["From"]) and "[EMAIL_" in str(out["From"])


def test_long_text_recall(ctx, out_dir, tmp_path):
    """Длинный документ не должен «проседать» в конце (окна по 1000 символов)."""
    rows = [f"{i}. Сотрудник Гиниятуллин{'а' if i % 2 else ''} Ильдар, тел. +7 900 555-{i:02d}-55, почта user{i}@example.org."
            for i in range(60)]
    src = tmp_path / "long.txt"; src.write_text("\n".join(rows), encoding="utf-8")
    text = process(src, out_dir, ctx).output.read_text(encoding="utf-8")
    assert "Гиниятуллин" not in text and "@example.org" not in text and "+7 900" not in text

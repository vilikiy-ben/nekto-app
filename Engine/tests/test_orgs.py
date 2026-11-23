"""Режим «Скрывать организации» (orgs.py, Session.hide). По умолчанию названия компаний видны."""
import threading
import zipfile

from nekto_engine.formats import Context, process
from nekto_engine.kinds import Kind
from nekto_engine.session import Session

TEXT = ("Цифровой склад: ПАО «Сибмедь» × Brightline Works\n"
        "Руководитель проекта — Ахмерова Гульнара, +7 900 555-01-48. Договор с ИП Гарипов Р. Р.\n"
        "Отчёт для Сибмеди готов, вектор развития согласован с ООО Вектор. Сибмедь довольна.")


def _ctx(detector, hide=()):
    s = Session()
    s.set_hide(set(hide))
    return Context(detector, s, threading.Event(), lambda _: None)


def test_off_by_default(detector):
    out = _ctx(detector).clean_text(TEXT)
    for org in ("ПАО «Сибмедь»", "Brightline Works", "Сибмеди", "ООО Вектор"):
        assert org in out, out
    assert "Ахмерова" not in out


def test_on_hides_with_one_label(detector):
    ctx = _ctx(detector, {Kind.ORG})
    out = ctx.clean_text(TEXT)
    for org in ("Сибмедь", "Сибмеди", "Brightline Works", "Вектор."):
        assert org not in out, out
    assert "вектор развития" in out, "обычное слово не трогаем"
    assert "Гарипов" not in out and "[ФИО_" in out, "ИП — человек, а не организация"
    sibmed = [e for e in ctx.session.mapping() if e["original"] == "ПАО «Сибмедь»"]
    assert len(sibmed) == 1 and {"Сибмеди", "Сибмедь"} <= set(sibmed[0]["variants"])
    assert out.count(sibmed[0]["placeholder"]) == 3


def test_state_and_turning_off(detector):
    ctx = _ctx(detector, {Kind.ORG})
    ctx.clean_text(TEXT)
    restored = Session.from_state(ctx.session.to_state())
    assert restored.hide == {Kind.ORG}
    restored.set_hide(set())
    out = Context(detector, restored, threading.Event(), lambda _: None).clean_text(TEXT)
    assert "ПАО «Сибмедь»" in out and "Brightline Works" in out, out


def test_english_text_untouched(detector):
    out = _ctx(detector, {Kind.ORG}).clean_text("The Quarterly Report was sent to the Board on Monday.")
    assert "Quarterly Report" in out and "Board" in out


def test_pptx_slide(tmp_path, detector, out_dir):
    from pptx import Presentation
    prs = Presentation()
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    slide.shapes.title.text = "Цифровой склад: ПАО «Сибмедь» × Brightline Works"
    slide.placeholders[1].text = "Руководитель проекта — Ахмерова Гульнара, +7 900 555-01-48"
    src = tmp_path / "Статус проекта.pptx"
    prs.save(src)
    res = process(src, out_dir, _ctx(detector, {Kind.ORG}))
    with zipfile.ZipFile(res.output) as z:
        xml = "".join(z.read(n).decode("utf-8", "ignore") for n in z.namelist() if n.startswith("ppt/slides/"))
    assert "Сибмедь" not in xml and "Brightline Works" not in xml and "Ахмерова" not in xml
    assert "[ОРГ_1]" in xml

"""Синтетические корпоративные файлы для ручной проверки. Все люди и номера вымышлены.

Запуск: python Engine/tests/make_fixtures.py build/share/fixtures
"""
import csv
import json
import sys
from email.message import EmailMessage
from pathlib import Path

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "build/share/fixtures")
OUT.mkdir(parents=True, exist_ok=True)

CONTRACT = [
    "ТРУДОВОЙ ДОГОВОР № ТД-2025/0417",
    "г. Казань, «03» марта 2025 г.",
    "АО «Брайтлайн Воркс» (Brightline Works), ИНН 1655091234, в лице генерального директора Нурлыгаянова Рамиля "
    "Фаритовича, и Мансурова Алсу Ринатовна, 17.09.1993 г.р., паспорт 92 15 № 604218, зарегистрированная по адресу: "
    "420138, г. Казань, пр-т Победы, д. 46А, кв. 218, СНИЛС 162-847-395 07, ИНН 165912873405, заключили настоящий договор.",
    "1.1. Работник принимается на должность ведущего инженера отдела сопровождения SAP.",
    "Реквизиты Работника: счёт 40817810362001847261, карта «Мир» 2202 2053 7781 4406, тел. +7 (987) 263-41-90.",
]


def make_docx():
    import docx
    d = docx.Document()
    d.core_properties.author = "Мансурова Алсу"
    d.sections[0].header.paragraphs[0].text = "Brightline Works · Кадровая служба · исп. Ахмерова Г. И."
    d.add_heading(CONTRACT[0], level=1)
    for line in CONTRACT[1:]:
        p = d.add_paragraph()
        if "Мансурова Алсу Ринатовна" in line:
            a, b = line.split("Мансурова Алсу Ринатовна")
            p.add_run(a); p.add_run("Мансурова Алсу Ринатовна").bold = True; p.add_run(b)
        else:
            p.add_run(line)
    t = d.add_table(rows=3, cols=2)
    t.style = "Table Grid"
    for i, (k, v) in enumerate([("Работодатель", "АО «Брайтлайн Воркс», г. Казань, ул. Лесная, д. 15"),
                                ("Работник", "Мансурова А. Р., +7 (987) 263-41-90, a.mansurova@brightline.example"),
                                ("Руководитель", "Гиниятуллин Ильдар Маратович")]):
        t.cell(i, 0).text = k; t.cell(i, 1).text = v
    d.save(OUT / "Трудовой договор Мансуровой.docx")


def make_xlsx():
    import openpyxl
    from openpyxl.comments import Comment
    from openpyxl.styles import Font, PatternFill
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = "Сотрудники"
    ws.append(["Таб. №", "ФИО", "Должность", "Отдел", "Моб. телефон", "E-mail", "Дата рождения", "Оклад", "Комментарий"])
    rows = [
        ("00731", "Гиниятуллин Ильдар Маратович", "Руководитель проекта", "Внедрение ERP", 79005550055, "i.giniyatullin@brightline-soft.example", "03.08.1985", 245000, "Командировка в ПАО «ПРИМЕРТЕХ» 19–23 мая"),
        ("01288", "Тарасова Дарья Андреевна", "Аналитик 1С", "Внедрение ERP", "+7 960 047-19-32", "d.tarasova@brightline-soft.example", "21.12.1997", 168000, "Замещает Гиниятуллина на время отпуска"),
        ("01403", "Бикбаев Тимур Рустамович", "DevOps-инженер", "Инфраструктура", "8 906 321-55-77", "t.bikbaev@brightline-soft.example", "30.06.1994", 210000, "Доступ к стенду, IP 203.0.113.47"),
        ("01519", "Пак Вера Сергеевна", "HR BP", "Персонал", "+79274409218", "v.pak@brightline-soft.example", "15.01.1990", 190000, "паспорт 9218 715340, проживает: г. Казань, ул. Чистопольская, д. 77/2, кв. 41"),
    ]
    for r in rows:
        ws.append(list(r))
    for c in ws[1]:
        c.font = Font(bold=True, color="FFFFFF"); c.fill = PatternFill("solid", fgColor="1F3BFF")
    ws["I2"].comment = Comment("Согласовано с Ахмеровой Г. И.", "Гиниятуллин И.")
    wb.properties.creator = "Тарасова Дарья"
    wb.save(OUT / "Сотрудники ERP.xlsx")


def make_pptx():
    from pptx import Presentation
    prs = Presentation()
    s = prs.slides.add_slide(prs.slide_layouts[1])
    s.shapes.title.text = "Цифровой склад: ПАО «Сибмедь» × Brightline Works"
    s.placeholders[1].text = ("Руководитель проекта — Гиниятуллин Ильдар, +7 900 555-00-55\n"
                              "Аналитик — Тарасова Дарья (d.tarasova@brightline-soft.example)\n"
                              "Заказчик: Голубев Павел Сергеевич")
    s.notes_slide.notes_text_frame.text = "Напомнить Ахмеровой Г. И. про пропуск для Олега Ветрова, паспорт 4519 302817"
    prs.save(OUT / "Статус проекта.pptx")


def make_csv():
    with open(OUT / "Реестр выплат.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(["ФИО получателя", "Счёт", "ИНН", "Сумма", "Назначение"])
        w.writerow(["Ершова Наталья Павловна", "40817810100004417352", "165208937710", "12 450,00", "Компенсация такси, гостиница «Корстон»"])
        w.writerow(["Гарипов Ильнур Раисович", "40817810601815908301", "166131860940", "8 900,00", "Аванс на командировку в ПАО «ПРИМЕРТЕХ»"])
        w.writerow(["Белова Ольга Игоревна", "40817810432319487574", "161862527600", "31 000,00", "Премия по итогам квартала"])


def make_eml():
    m = EmailMessage()
    m["From"] = "Ахмерова Гульнара <g.akhmerova@brightline.example>"
    m["To"] = "Голубев Павел <pavel.golubev@sibmed.example>"
    m["Subject"] = "RE: Доступ к стенду ERP для подрядчика"
    m.set_content("Павел Сергеевич, добрый день!\n\nУчётку для Олега Ветрова создали, логин o.vetrov.ext, временный пароль "
                  "Qv#2025!lmR4. VPN привязан к ноутбуку, внешний IP 203.0.113.47.\nЕсли будут вопросы — Телеграм "
                  "@gulya_akh или мобильный 8 900 555-01-48.\n\n--\nГульнара Ахмерова\nBrightline Works")
    m.add_attachment(b"%PDF-1.4 fake", maintype="application", subtype="pdf", filename="паспорт_Ветров.pdf")
    (OUT / "Письмо про доступ.eml").write_bytes(bytes(m))


def make_json():
    data = {"source": "CRM Brightline Works", "contacts": [
        {"full_name": "Юнусов Азат Ильдусович", "phone": 79005556543, "email": "azat.yunusov@example.com",
         "company": "ООО «ТехноСнаб Поволжье»", "note": "Самозанятый, ИНН 165714920386, договор на поддержку 1С"},
        {"full_name": "Jonas Becker", "phone": "+49 151 5550 7790", "email": "jonas.becker@kestrel-log.example",
         "company": "Kestrel Logistics GmbH", "note": "Contact for MSA-BLW-2025-031, prefers calls after 15:00"},
    ]}
    (OUT / "Выгрузка CRM.json").write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def make_txt():
    (OUT / "Рабочий чат.txt").write_text(
        "[10:42] Лёха Смирнов: ребят, кто знает мобилу Айгуль из бухгалтерии?\n"
        "[10:43] Ильназ: 89272105533, только она до обеда у врача\n"
        "[10:44] Лёха Смирнов: спс. и закажите пропуск для подрядчика, его зовут Кирилл Жданов, паспорт 4519 302817\n"
        "[10:46] Ильназ: ок, заказал через proxod.brightline.local, пропуск № 7731\n", encoding="utf-8")


def make_scans():
    """Скан справки (PNG) и «сканированный» PDF без текстового слоя — для OCR."""
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
    font_path = "/System/Library/Fonts/Supplemental/Arial.ttf"
    lines = ["СПРАВКА", "", "Выдана Шайдуллину Айдару Ренатовичу, 12.02.1988 г.р.,",
             "в том, что он работает в АО «Брайтлайн Воркс»", "в должности инженера с 01.04.2019.",
             "Паспорт 9208 553127. Телефон +7 900 555-12-34.", "", "Справка дана для предъявления по месту требования.",
             "", "Начальник отдела кадров        Шакирова Л. Ф."]
    img = Image.new("RGB", (1700, 1100), (250, 248, 243))
    d = ImageDraw.Draw(img)
    for i, line in enumerate(lines):
        size = 54 if i == 0 else 38
        f = ImageFont.truetype(font_path, size)
        d.text((140 if i else 700, 110 + i * 82), line, font=f, fill=(25, 25, 30))
    img = img.rotate(0.6, fillcolor=(250, 248, 243)).filter(ImageFilter.GaussianBlur(0.6))
    img.save(OUT / "Скан справки.png")
    img.convert("RGB").save(OUT / "Справка (скан).pdf", "PDF", resolution=150)


def make_feedback():
    """Большой лист с длинными отзывами: проверка вида и прокрутки больших таблиц."""
    import random
    import openpyxl
    rnd = random.Random(7)
    people = ["Ивановой Марине", "Петрову Олегу", "Бикбаеву Тимуру", "Тарасовой Дарье", "Пак Вере", "Гиниятуллину Ильдару",
              "Голубеву Павлу", "Ахмеровой Гульнаре", "Ветрову Олегу", "Гариповой Алсу"]
    units = ["Москва / Пункт выдачи на Тверской", "Пункт выдачи / Возвраты",
             "Кухня / Посуда / Сковороды",
             "Дом / Текстиль / Пледы", "Казань / Пункт выдачи у метро",
             "Электроника / Наушники"]
    phrases = ["Инструкцию по сборке в этой партии переписали заметно понятнее.",
               "Наконец-то!", "Отдельное спасибо за доставку в выходные.", "Медленно", "Думали, не успеем.",
               "Видео по настройке стоит переснять.", "Чек пришёл сразу.",
               "Пару раз переносили доставку, но предупреждали заранее.", "Видно, что вникали в задачу.",
               "Телефон для связи +7 916 {:03d}-{:02d}-{:02d}, пишите в любое время."]
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = "Отзывы"
    ws.append(["Магазин", "Отзыв", "Товар", "Доставка", "Упаковка", "Итог"])
    for _ in range(300):
        parts = rnd.sample(phrases, rnd.randint(1, 5))
        text = " ".join(p.format(rnd.randint(100, 999), rnd.randint(10, 99), rnd.randint(10, 99)) if "{" in p else p for p in parts)
        if rnd.random() < 0.6:
            text = f"Спасибо {rnd.choice(people)} за помощь. " + text
        ws.append([rnd.choice(units), text, rnd.choice(units), rnd.randint(1, 10), rnd.randint(1, 10), 10])
    wb.save(OUT / "Обратная связь.xlsx")


if __name__ == "__main__":
    for fn in (make_docx, make_xlsx, make_pptx, make_csv, make_eml, make_json, make_txt, make_scans, make_feedback):
        fn()
    print("\n".join(sorted(p.name for p in OUT.iterdir())))

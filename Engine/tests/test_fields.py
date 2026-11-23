"""Поля анкеты, адрес человека или организации, правила для номеров — всё, что решается без модели."""
import threading

import pytest

from fakes import CountingDetector
from nekto_engine import entities, fields, rules
from nekto_engine.formats import Context
from nekto_engine.kinds import Kind
from nekto_engine.session import Session


def found(text: str) -> list[tuple[str, Kind]]:
    return [(text[s.start:s.end], s.kind) for s in fields.find(text)]


def cleaned(text: str) -> str:
    return Context(CountingDetector(), Session(), threading.Event(), lambda _: None).clean_segments(text.split("\n")) \
        and "\n".join(Context(CountingDetector(), Session(), threading.Event(), lambda _: None).clean_segments(text.split("\n")))


def test_labelled_values():
    assert found("Фамилия: Ким\nИмя: Виктория") == [("Ким", Kind.PERSON), ("Виктория", Kind.PERSON)]
    assert found("snils: 31383447060\ndoc_number: FA8336962") == [("31383447060", Kind.SNILS), ("FA8336962", Kind.ID)]
    assert found("Skype: v.yarmolyuk") == [("v.yarmolyuk", Kind.HANDLE)]
    assert ("m.kuznetsova", Kind.HANDLE) in found("logout user=m.kuznetsova ok")


def test_scanned_form_with_ocr_errors():
    """Распознанный бланк: без двоеточий, с нулём вместо «О» и буквой вместо нуля — метка поля решает."""
    text = "Фамилия   КИМ\nИмя    ВИКТ0РИЯ\nОтчество  СЕРГЕЕВНА\nПол  ЖЕН.    Дата рождения  16.04.199O"
    assert found(text) == [("КИМ", Kind.PERSON), ("ВИКТ0РИЯ", Kind.PERSON), ("СЕРГЕЕВНА", Kind.PERSON), ("16.04.199O", Kind.BIRTHDATE)]


def test_value_on_the_next_line():
    assert found("Табельный номер\n07731\nИНН\n772771348446") == [("07731", Kind.ID), ("772771348446", Kind.INN)]


def test_only_the_part_that_fits_the_kind():
    assert found("11. Паспорт: № 81 04 123456 выдан ОВД Советского района") == [("81 04 123456", Kind.PASSPORT)]
    assert found("ФИО: Орлов Иван Петрович (директор)") == [("Орлов Иван Петрович", Kind.PERSON)]
    assert found("Исполнитель: ИП Зуев П. П.") == [("Зуев П. П.", Kind.PERSON)]


@pytest.mark.parametrize("text", [
    "Имя файла: report.pdf",
    "Имя\nЗаполняется печатными буквами",   # после метки — фраза, а не имя
    "Фамилия: Указывается как в паспорте",
    "Имя пользователя: admin",
    "Пароль: не менялся",
    "Ответственный: Отдел кадров",          # метка-роль: значение само должно быть похоже на имя
    "Заказчик: ООО «Ромашка»",
    "Статус: активен",
    "ИНН: 7707083893",                      # 10 цифр — организация
    "payout_account: 40702810220619617472", # счёт юрлица
    "Телефон поддержки: 8-800-333-41-90",
])
def test_not_personal(text):
    assert found(text) == []


def test_role_label_accepts_a_real_name():
    assert found("Ответственный: Мороз П. С.") == [("Мороз П. С.", Kind.PERSON)]
    assert found("Клиент: Сидоров Иван") == [("Сидоров Иван", Kind.PERSON)]


# ---------- адрес: жильё или организация ----------

HOME = [
    "Зарегистрирован по адресу: г. Казань, ул. Космонавтов, д. 49В",
    "Адрес: г. Тула, ул. Мира, д. 5, кв. 7",
    "проживает: Оренбург, проезд Северный, 16/1, подъезд 3, этаж 8, кв. 127",
    "Луговой проезд 45-172",
]
OFFICE = [
    "Место работы: г. Казань, ул. Петербургская, д. 52, офис 310",
    "ООО «Северный мост», ИНН 6307041833, КПП 770401001\n119021, г. Москва, Зубовский бульвар, д. 13, стр. 1",
    "В ПАО «Банк Прикамье»\n614000, г. Пермь, ул. Монастырская, д. 61",
    "Приём по адресу: г. Тверь, Петербургское шоссе, д. 105, ТЦ «Вертикаль», 3 этаж",
    "Склад и шоурум: г. Казань, ул. Техническая, д. 23, корп. 2",
]


@pytest.mark.parametrize("text", HOME)
def test_home_address(text):
    start = text.find(": ") + 2 if ": " in text else 0
    assert entities.private_address(text, start, len(text))


@pytest.mark.parametrize("text", OFFICE)
def test_office_address(text):
    start = max(text.rfind("\n") + 1, text.find(": ") + 2 if ": " in text.split("\n")[-1] else 0)
    assert not entities.private_address(text, start, len(text))


# ---------- правила ----------

def kinds(text: str) -> set[tuple[str, Kind]]:
    return {(text[s.start:s.end], s.kind) for s in rules.rule_spans(text)}


def test_passport_forms():
    assert ("51 79", Kind.PASSPORT) in kinds("паспорт серии 51 79 номер 504661") and ("504661", Kind.PASSPORT) in kinds("паспорт серии 51 79 номер 504661")
    assert ("75 3406837", Kind.PASSPORT) in kinds("Passport No.: 75 3406837, действителен до 2030")
    assert ("4005 286130", Kind.PASSPORT) in kinds("данные из прошлой заявки (4005 286130)")
    assert ("15 34 621813", Kind.PASSPORT) in kinds("15 34 621813")
    assert kinds("в 2024 123456 штук") == set()


def test_passport_number_from_machine_readable_zone():
    text = "Р RUS 75 5330241\nP<RUSIVANOV<<IVAN<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n7553302414RUS8712092M2911085<<<<<<<<<<<<<<06"
    found_ = kinds(text)
    assert ("75 5330241", Kind.PASSPORT) in found_
    assert any(value.startswith("P<RUS") for value, _k in found_) and any(value.startswith("7553302414RUS") for value, _k in found_)


def test_document_numbers():
    assert ("14/21-ТД", Kind.ID) in kinds("к трудовому договору от 01.02.2021 № 14/21-ТД")
    assert ("ДМС-2025-0048817", Kind.ID) in kinds("номер полиса? ДМС-2025-0048817")
    assert ("ХХХ 0312457788", Kind.ID) in kinds("по полису ОСАГО ХХХ 0312457788")
    assert ("78 РК 208796", Kind.ID) in kinds("ПТС: 78 РК 208796")
    assert ("304775183054951", Kind.ID) in kinds("ОГРНИП 304775183054951")
    assert ("О 771 АК 116 RUS", Kind.ID) in kinds("гос. знак О 771 АК 116 RUS")


@pytest.mark.parametrize("text", [
    "ОГРН 1081654544773, КПП 165501001",                  # реквизиты организации; 13 цифр иногда сходятся по Луну
    "GDB1550 | 3322937388226 | Колодки тормозные",        # штрих-код
    "Заявка №48213, SLA — 8 часов",
    "Лицензия № Л041-01137-05/00361472",
    "банкомат № 60714",
    "Франшиза по полису: 30 000 руб.",
    "healthcheck passed: status=200, latency=38 ms",      # «passed» — не «pass»
    "встреча в 12:30:45 и в 10:15",
    "Телефон горячей линии 8-800-555-35-35",
])
def test_not_identifiers(text):
    assert kinds(text) == set()


def test_secrets_at_a_distance():
    assert ("Kotik1987!", Kind.SECRET) in kinds("Пароль точно верный: Kotik1987!, я его не менял")
    assert ("hotel2025guest", Kind.SECRET) in kinds("пароль от сети дали только на третий день (hotel2025guest)")
    assert ("17к4408", Kind.SECRET) in kinds("квартира 17, домофон 17к4408")
    assert ("4471#", Kind.SECRET) in kinds("код сейфа сменили → 4471#")
    assert ("584 219", Kind.SECRET) in kinds("Временный код для входа: 584 219, действует 10 минут")
    assert kinds("пароль меняется каждые 90 дней, версия v2.8") == set()


def test_handles_and_network():
    assert ("k.nepeyvoda", Kind.HANDLE) in kinds("Учётка k.nepeyvoda, ошибка 809")
    assert ("sevmost\\g.ten", Kind.HANDLE) in kinds("учётная запись sevmost\\g.ten")
    assert ("shubin_gs", Kind.HANDLE) in kinds("логин клиента shubin_gs")
    assert ("79127460358", Kind.PHONE) in kinds("[sms] to=79127460358 text")
    assert ("2a02:6b8:c1f:3e02::5d1a", Kind.IP) in kinds("429 from 2a02:6b8:c1f:3e02::5d1a")


def test_values_broken_by_a_line_break(ctx):
    """Правила и адреса видят соседние строки: серия паспорта на одной строке, номер — на следующей."""
    out = ctx.clean_segments(["Личная подпись", "08 10", "908591", "Адрес постоянного места жительства",
                              "Калининградская область, г. Светлогорск,", "Калининградский проспект, дом 77Б, квартира 3"])
    assert "08 10" not in out[1] and "908591" not in out[2]
    assert "Светлогорск" not in out[4] and "77Б" not in out[5]


def test_number_next_to_a_person_in_a_text_row():
    ctx = Context(CountingDetector({"Седых": "LAST_NAME"}), Session(), threading.Event(), lambda _: None)
    (out,) = ctx.clean_segments(["10474 | Седых Наталья В. | 6782601827 | одобрено | 1 500 000"])
    assert "6782601827" not in out and "10474" in out and "1 500 000" in out


def test_birth_year_after_a_relative():
    ctx = Context(CountingDetector(), Session(), threading.Event(), lambda _: None)
    (out,) = ctx.clean_segments(["Состав семьи: жена — Зуева Мария Сергеевна, 1982; сын — Зуев Иван Петрович, 2009"])
    assert "1982" not in out and "2009" not in out


# ---------- случаи контрольного набора ----------

def test_request_and_order_numbers_are_not_documents():
    for text in ("заказали ThinkPad, заявка HD-20418", "инвойс INV-2025-0871 / контейнер", "ticket #SD-40127 created",
                 "КОММЕРЧЕСКОЕ ПРЕДЛОЖЕНИЕ № КП-2511/073 от 21.11.2025", "ноутбук HP, инв. № НБ-004417"):
        assert not {k for _v, k in kinds(text)} & {Kind.ID}, text
    assert ("ДМС-2025-0048817", Kind.ID) in kinds("[13:04] Регина: ДМС-2025-0048817")
    assert ("910 245 388 107", Kind.ID) in kinds("принесла больничный, ЭЛН № 910 245 388 107, с 3-го по 12-е")
    assert ("16 АА 7302215", Kind.ID) in kinds("по доверенности 16 АА 7302215 от 02.10.2025")
    assert ("КП-58/25", Kind.ID) in kinds("к договору купли-продажи № КП-58/25 от 11.04.2025")


def test_versions_are_not_ip_addresses():
    assert not kinds("известная проблема версии 4.18.2.117, исправление выйдет")
    assert not kinds("node=app-03.prod ver=2.14.0.3")
    assert ("10.12.4.87", Kind.IP) in kinds("last_login_ip: 10.12.4.87")


def test_secrets_in_configuration():
    assert ("qwfp-zxcv-arst-neio", Kind.SECRET) in kinds("      SMTP_PASS: qwfp-zxcv-arst-neio")
    assert ("r3d1s-St@ge", Kind.SECRET) in kinds("command: redis-server --requirepass r3d1s-St@ge --maxmemory 512mb")
    assert ("9*4418", Kind.SECRET) in kinds("код подъезда 9*4418, звонить заранее")
    assert not kinds("const TOKEN = import.meta.env.VITE_API_TOKEN;")
    assert not {k for _v, k in kinds("терминал 10482217, код авторизации A39F01")} & {Kind.SECRET}


def test_accounts():
    assert ("@m.okhotnikova", Kind.HANDLE) in kinds("заведи тикет и тегни @m.okhotnikova, она ведёт договор")
    assert ("d.zayats", Kind.HANDLE) in kinds("INFO [profile] user d.zayats changed phone")
    assert not kinds("login: svc_backup")


def test_passport_in_forms_and_json():
    text = "ПАСПОРТ ГРАЖДАНИНА РФ\nСЕРИЯ\n5008\nНОМЕР\n413370\n4. АДРЕС"
    assert {("5008", Kind.PASSPORT), ("413370", Kind.PASSPORT)} <= kinds(text)
    text = '"passport": {"series": "0817", "number": "455209", "issuedAt": "2017"}'
    assert {("0817", Kind.PASSPORT), ("455209", Kind.PASSPORT)} <= kinds(text)
    assert ("75 9120446", Kind.PASSPORT) in kinds("spouse, passport 75 9120446")


def test_lowercase_plate_and_maiden_name():
    assert ("о902мр116", Kind.ID) in kinds("2. Лада Веста, о902мр116, водитель")
    assert ("Иволга", Kind.PERSON) in kinds("сменила фамилию (до брака — Иволга), свидетельство")


def test_field_values_from_control_set():
    found = {(s.kind, text[s.start:s.end]) for text in ["12. КОДОВОЕ СЛОВО\nЧЕРЁМУХА\nПОДПИСЬ ЗАЯВИТЕЛЯ"] for s in fields.find(text)}
    assert (Kind.SECRET, "ЧЕРЁМУХА") in found
    text = "Адрес проживания: Москва, ул. Образцова, 12-48, в том, что он находился на амбулаторном лечении с диагнозом: ОРВИ"
    spans = [text[s.start:s.end] for s in fields.find(text) if s.kind is Kind.ADDRESS]
    assert spans == ["Москва, ул. Образцова, 12-48"]
    text = "Проживает: Долгих Антонина Прокопьевна, 1 июня 1941 г. рождения, инвалид II группы (справка № 0417826)"
    assert [s for s in fields.find(text) if s.kind is Kind.ADDRESS] == []


# ---------- случаи четвёртого набора ----------

def test_accounts_without_a_label():
    assert ("n.gogoberidze", Kind.HANDLE) in kinds("не я, по blame это n.gogoberidze, коммит a41c9e7")
    assert ("d.sokol", Kind.HANDLE) in kinds("[admin] unlock user=ivanov_pp by=d.sokol comment")
    assert ("tanya_mur", Kind.HANDLE) in kinds('"login": "tanya_mur",')
    assert ("olga_k_1984", Kind.HANDLE) in kinds("Оценка: ★★☆☆☆   Автор: olga_k_1984")
    assert ("kotik_2005", Kind.HANDLE) in kinds("мой ник там kotik_2005, если что")
    assert ("zarina-k", Kind.HANDLE) in kinds("7be02d4 zarina-k <zarina.kadyrova@example.org>")
    assert ("БабаджанянРС", Kind.HANDLE) in kinds("1С:УТ — пользователь «БабаджанянРС»")
    for text in ("user: billing_rw", "откройте config.yaml и docs.html", "listen: 0.0.0.0:8080", "GET /healthz 200 from 127.0.0.1",
                 "version 4.18.0.240 -> 4.18.1.3 by ci", "Откройте в браузере адрес 192.168.1.1"):
        assert not kinds(text), text


def test_plates_passports_and_codes_of_the_final_set():
    assert ("в 478 ру 198", Kind.ID) in kinds("закажите пропуск плиз: киа рио, в 478 ру 198")
    assert not kinds("цену поднимут с 500 на 700 рублей")
    assert ("FA 4471205", Kind.PASSPORT) in kinds("Рахимов Фаррух, 14.02.1994, паспорт FA 4471205, патент")
    assert ("ласточка", Kind.SECRET) in kinds("паспорт 6511 284773, кодовое слово ласточка, тел.")
    assert not {k for _v, k in kinds("назовите кодовое слово оператору.")} & {Kind.SECRET}
    found = kinds("пароль Wi-Fi (сеть Keenetic-5521): martin2023pak.")
    assert ("martin2023pak", Kind.SECRET) in found and not any("Keenetic" in v for v, _k in found)
    assert ("910 284 471 036", Kind.ID) in kinds("открыт листок нетрудоспособности по уходу № 910 284 471 036, с 14.11")
    assert ("3365 4944 0584", Kind.INN) in kinds("СНИЛС 130-484-249 35   ИНН 3365 4944 0584")


def test_sender_before_address():
    text = "To: Petrov, Vladislav <v.petrov@example.org>\nFrom: Отдел кадров <hr@example.org>"
    assert [text[s.start:s.end] for s in fields.find(text) if s.kind is Kind.PERSON] == ["Petrov, Vladislav"]

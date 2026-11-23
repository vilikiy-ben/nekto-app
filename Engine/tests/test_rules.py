from nekto_engine.kinds import Kind
from nekto_engine.rules import inn12_ok, luhn_ok, rule_spans, snils_ok


def kinds(text):
    return {(text[s.start:s.end], s.kind) for s in rule_spans(text)}


def test_checksums():
    assert snils_ok("11223344595")
    assert not snils_ok("11223344596")
    assert luhn_ok("4539148803436467")
    assert not luhn_ok("4539148803436468")
    assert inn12_ok("500100732259")
    assert not inn12_ok("500100732250")


def test_structured_numbers():
    found = kinds("СНИЛС 162-847-395 07, ИНН 165912873405, карта 4539 1488 0343 6467, счёт 40817810362001847261")
    assert ("162-847-395 07", Kind.SNILS) in found
    assert ("165912873405", Kind.INN) in found
    assert ("4539 1488 0343 6467", Kind.CARD) in found
    assert ("40817810362001847261", Kind.ACCOUNT) in found


def test_contacts():
    found = kinds("Пишите g.akhmerova@brightline.example, звоните 8 900 555-01-48 или +49 151 5550 7790, tg @gulya_akh, IP 203.0.113.47")
    assert ("g.akhmerova@brightline.example", Kind.EMAIL) in found
    assert ("8 900 555-01-48", Kind.PHONE) in found
    assert ("+49 151 5550 7790", Kind.PHONE) in found
    assert ("@gulya_akh", Kind.HANDLE) in found
    assert ("203.0.113.47", Kind.IP) in found


def test_passport_context():
    assert ("9204 № 518273", Kind.PASSPORT) in kinds("паспорт серия 9204 № 518273, выдан")
    assert ("4519 302817", Kind.PASSPORT) in kinds("его паспорт 4519 302817")


def test_no_false_positives_on_org_data():
    text = "ИНН 1655091234, КПП 165501001, ОГРН 1041621012345, р/с 40702810862000012345, БИК 049205603, версия 8.3.24.1586"
    assert not [s for s in rule_spans(text) if s.kind in (Kind.INN, Kind.ACCOUNT, Kind.CARD, Kind.PHONE, Kind.SNILS)]


def test_secrets():
    found = kinds('SMTP_PASS = "Qwerty!2025sid"\nвременный пароль Qv#2025!lmR4 и ключ sk-abcdefghijklmnopqrstuvwxyz123')
    assert ("Qwerty!2025sid", Kind.SECRET) in found
    assert ("Qv#2025!lmR4", Kind.SECRET) in found
    assert any(k is Kind.SECRET and v.startswith("sk-") for v, k in found)


def test_core_properties_skip_software():
    from nekto_engine.formats.ooxml import is_person_field
    assert not is_person_field("openpyxl") and not is_person_field("Microsoft Office User") and not is_person_field("  ")
    assert is_person_field("ivanov.ii") and is_person_field("Гиниятуллин Ильдар")

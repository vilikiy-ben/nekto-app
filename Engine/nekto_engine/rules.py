"""Регулярные правила для структурированных ПДн, которые модель пропускает или не типизирует.

Номера с контрольной суммой (ИНН, СНИЛС, карта) проверяются, чтобы не маскировать
случайные числа; рядом со словом-подсказкой («ИНН», «СНИЛС», «паспорт») сумма не нужна.
"""
from __future__ import annotations

import re
from typing import Callable, Iterable

from .kinds import Kind
from .spans import Span

# ---------- контрольные суммы ----------

def inn12_ok(digits: str) -> bool:
    if len(digits) != 12 or not digits.isdigit():
        return False
    d = [int(c) for c in digits]
    c1 = sum(a * b for a, b in zip((7, 2, 4, 10, 3, 5, 9, 4, 6, 8), d)) % 11 % 10
    c2 = sum(a * b for a, b in zip((3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8), d)) % 11 % 10
    return d[10] == c1 and d[11] == c2


def snils_ok(digits: str) -> bool:
    if len(digits) != 11 or not digits.isdigit():
        return False
    body, check = digits[:9], int(digits[9:])
    s = sum(int(c) * (9 - i) for i, c in enumerate(body))
    while s > 101:
        s %= 101
    expected = 0 if s in (100, 101) else s
    return expected == check


def luhn_ok(digits: str) -> bool:
    if not 13 <= len(digits) <= 19 or not digits.isdigit():
        return False
    total = 0
    for i, ch in enumerate(reversed(digits)):
        x = int(ch)
        if i % 2:
            x = x * 2 - 9 if x > 4 else x * 2
        total += x
    return total % 10 == 0


def only_digits(s: str) -> str:
    return re.sub(r"\D", "", s)


# ---------- правила ----------

Check = Callable[[re.Match[str]], bool]


class Rule:
    """Правило читает текст целиком, но значение по умолчанию не переходит на другую строку: «\\s» в шаблоне — это
    пробел или табуляция. `lines=True` — значение может быть разорвано переводом строки (номер паспорта на скане,
    «Табельный номер» и число под ним)."""

    __slots__ = ("kind", "rx", "check", "group", "trim")

    def __init__(self, kind: Kind, pattern: str, check: Check | None = None, group: int = 0, flags: int = 0,
                 trim: str = "", lines: bool = False):
        if not lines:
            pattern = _one_line(pattern)
        self.kind, self.rx, self.check, self.group, self.trim = kind, re.compile(pattern, flags), check, group, trim

    def find(self, text: str) -> Iterable[Span]:
        for m in self.rx.finditer(text):
            if self.check and not self.check(m):
                continue
            start, end = m.start(self.group), m.end(self.group)
            while end > start and text[end - 1] in self.trim:      # точка в конце предложения — не часть ссылки
                end -= 1
            if end > start:
                yield Span(start, end, self.kind, 1.0, "rule")


def _one_line(pattern: str) -> str:
    """«\\s» → пробел или табуляция (без перевода строки), и в классе символов, и вне его. В отрицании «[^\\s…]»
    остаётся как есть: «не пробельный» и так не включает перевод строки."""
    out, in_class, negated, i = [], False, False, 0
    while i < len(pattern):
        ch = pattern[i]
        if ch == "\\" and i + 1 < len(pattern):
            pair = pattern[i:i + 2]
            if pair == "\\s" and not negated:
                pair = " \\t" if in_class else "[ \\t]"
            out.append(pair)
            i += 2
            continue
        if ch == "[" and not in_class:
            in_class, negated = True, pattern[i + 1:i + 2] == "^"
        elif ch == "]" and in_class:
            in_class = negated = False
        out.append(ch)
        i += 1
    return "".join(out)


_I = re.IGNORECASE
_D = r"(?<![\d\w])"     # левая граница числа
_E = r"(?![\d\w])"      # правая граница числа

# Служебная учётная запись («svc_backup», «bot-deploy») человека не выдаёт.
SERVICE_ACCOUNT = re.compile(r"(?:svc|service|sys|system|app|bot|robot|cron|backup|test|tech|api|srv|daemon)[_.-]|"
                             r".*[_.-](?:rw|ro|svc|bot|app|service|reader|writer|prod|stage|dev|test)$|ci$", re.I)
_FILE_OR_ZONE = re.compile(r"ya?ml|json|conf|html?|yaml|local|localhost|prod|stage|test|data|coli|info|site|name|html|"
                           r"lock|toml|java|class|pyc|docx?|xlsx?|pptx?|jpe?g|tiff?|proto|go|rs|ts|js|py|sh|sql|log|txt|csv|xml|env|bak")
# Слово об автомобиле рядом: по нему строчные буквы с пробелами читаются как госномер.
_CAR_NEAR = re.compile(r"авто|машин|\bномер|\bгос|пропуск|водител|\bа/м|\bт/с|парков|шлагбаум|kia|киа|lada|лада|toyota|тойот|"
                       r"hyundai|хенд|хёнд|renault|рено|volkswagen|фольксваген|skoda|škoda|шкод|nissan|ниссан|bmw|бмв|mercedes|"
                       r"мерседес|audi|ауди|ford|форд|mazda|мазд|газель|\bуаз|камаз|chery|haval|geely|lexus|mitsubishi|honda|"
                       r"opel|chevrolet|шевроле|solaris|солярис|logan|логан|\bpolo|\brio|\bрио|octavia|camry|vin", re.I)


def _service(value: str) -> bool:
    return bool(SERVICE_ACCOUNT.match(value)) or value.lower() in ("admin", "root", "system", "user", "guest", "security", "ci")


def _login_like(value: str) -> bool:
    """После «by=», «author:» — учётная запись, а не слово: есть точка, подчёркивание, дефис или цифра, либо латиница от 5 букв."""
    return bool(re.search(r"[._\-\d]", value)) or (value.isascii() and value.islower() and len(value) >= 5)


def _nominative_noun(word: str) -> bool:
    from .names.lexicon import morph
    return any(p.is_known and p.tag.POS == "NOUN" and p.tag.case == "nomn" and p.tag.number == "sing"
               for p in morph().parse(re.sub(r"\d+$", "", word).lower())[:3])
_SERVICE_ACCOUNT = SERVICE_ACCOUNT

RULES: list[Rule] = [
    # пароли/токены/ключи: значение после «пароль:», PASS = "…", а также известные форматы ключей
    Rule(Kind.SECRET, r"(?<![^\W_])(?:парол\w*|password|passwd|pwd|pass|passphrase|secret|секрет\w*|токен\w*|token|api[_-]?key|"
                      r"session(?:[_-]?id)?|sid|bearer|ключ\w*\s+(?:api|доступа))(?![^\W_])[\"']?\s*[:=—-]?\s*[\"']?"
                      r"(?=[^\s\"',;=]*[\d!#$%&*@^])([^\s\"',;=]{6,})", group=1, flags=_I),
    # пароль не вплотную к слову: «Пароль точно верный: Kotik1987!», «пароль от сети дали на третий день (hotel2025guest)»
    Rule(Kind.SECRET, r"(?:парол\w*|password|passwd|\bpwd\b)[^.!?\n]{0,60}?(?<![\w#@!$%^&*-])"
                      r"((?=[^\s\"'«»(),;=]*\d)(?=[^\s\"'«»(),;=]*(?:[^\W\d]|[#!@$%^&*_]))[^\s\"'«»(),;=]{5,})(?![=\w])",
         group=1, flags=_I, trim=".:",
         check=lambda m: not re.match(r"\)\s*:\s*\S", m.string[m.end(1):m.end(1) + 5])),   # в скобках — пояснение, пароль дальше
    # «пароль Wi-Fi (сеть Keenetic-5521): martin2023pak»
    Rule(Kind.SECRET, r"(?:парол\w*|password)(?:\s+[\w-]+)?\s*\([^)\n]{1,40}\)\s*:\s*([^\s\"',;()]{5,})", group=1, flags=_I, trim="."),
    # «кодовое слово ласточка»: существительное в именительном падеже сразу после
    Rule(Kind.SECRET, r"кодов\w+\s+слов\w+\s*[:—–-]?\s*[«\"]?([А-ЯЁа-яё]{4,}\d*)(?![\w-])", group=1, flags=_I,
         check=lambda m: _nominative_noun(m.group(1))),
    Rule(Kind.SECRET, r"резервн\w+\s+код\w*\s*:?\s*(\d{4}-\d{4}(?:,\s*\d{4}-\d{4})*)", group=1, flags=_I),
    # код от двери, сейфа, домофона, одноразовый код: «домофон 17к4408», «код сейфа сменили → 4471#»
    Rule(Kind.SECRET, r"(?:код\w*\s+(?:от\s+)?(?:двер\w+|сейф\w+|домофон\w+|подъезд\w+|калитк\w+|замк\w+|для\s+входа|входа)|"
                      r"(?:временн\w+|одноразов\w+|смс|sms)[-\s]?код\w*(?:\s+для\s+входа)?|домофон\w*)"
                      r"[^.!?\n\d]{0,30}?(?<![\w])(\d{3}\s?\d{3}(?!\d)|\d+[^\W\d*#]\d+|\d+[*#]\d+|\d{4,8}[#*]?|\d{2,4}[^\W\d_](?![\w]))", group=1, flags=_I),
    # настройка с паролем: «SMTP_PASS: qwfp-zxcv-arst-neio», «--requirepass r3d1s-St@ge» — значение любое
    Rule(Kind.SECRET, r"(?<![^\W_])(?:[A-Z][A-Z0-9]*_)*(?:PASS(?:WORD|WD)?|SECRET|TOKEN|API_?KEY|PRIVATE_KEY)(?:_[A-Z0-9]+)*\s*[:=]\s*"
                      r"[\"']?([^\s\"',;#]{6,})", group=1,
         check=lambda m: m.group(1).lower() not in ("changeme", "password", "secret", "example", "null", "none", "true", "false")
         and not re.match(r"\$|[A-Za-z_][\w$]*(?:\.[A-Za-z_][\w$]*)+$|[A-Za-z_]\w*\(", m.group(1))),   # ссылка на переменную, а не значение
    Rule(Kind.SECRET, r"--?(?:requirepass|password|passwd|token)(?:=|\s+)[\"']?([^\s\"',;]{6,})", group=1, flags=_I),
    Rule(Kind.SECRET, r"\b(?:sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|xox[abp]-[A-Za-z0-9-]{10,}|"
                      r"AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})"),
    # код доступа, пин, идентификатор и пароль конференции: «Код доступа: 135790», «Идентификатор конференции: 912 3456 7801»
    Rule(Kind.SECRET, r"(?:код\s+(?:доступа|подтверждения|активации)|кодов\w+\s+слов\w+|пин(?:-|\s)?код\w*|"
                      r"\bpin\b|passcode|access\s+code|\bcvv2?\b|\bcvc2?\b)\s*[:=—–-]?\s*([\w-]{3,})", group=1, flags=_I,
         check=lambda m: any(ch.isdigit() for ch in m.group(1))),
    Rule(Kind.ID, r"(?:идентификатор\s+(?:конференции|встречи|совещания)|meeting\s+id|conference\s+id|webinar\s+id)"
                  r"\s*[:=—–-]?\s*(\d[\d \-]{4,18}\d)", group=1, flags=_I),
    Rule(Kind.EMAIL, r"[\w.+'-]+@[\w-]+(?:\.[\w-]+)*\.[a-zа-я]{2,}", flags=_I,
         check=lambda m: m.string[max(0, m.start() - 5):m.start()] != "[bot]"),
    # ссылка целиком: с протоколом или www — любая; без протокола — личные страницы и приглашения
    Rule(Kind.URL, r"(?:https?://|ftp://|www\.)[^\s<>\"'«»]+", flags=_I, trim=".,;:!?)]}",
         check=lambda m: bool(re.search(r"[\w-]\.[\w-]", m.group().split("//", 1)[-1].split("/", 1)[0]))),   # «http://backend» — не адрес
    Rule(Kind.URL, r"(?<![\w@.-])(?:github\.com|gitlab\.com|hh\.ru/resume|vk\.com|t\.me|linkedin\.com/in|facebook\.com|"
                   r"instagram\.com|ok\.ru/profile|zoom\.us/j|meet\.google\.com|telemost\.yandex\.ru/j|"
                   r"teams\.microsoft\.com/l)/[^\s<>\"'«»]+", flags=_I, trim=".,;:!?)]}"),
    Rule(Kind.HANDLE, r"(?<![\w.@])@[A-Za-z](?:[\w]|[.-](?=\w)){3,31}(?![\w])"),
    Rule(Kind.IP, _D + r"(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)" + _E,
         check=lambda m: not re.search(r"(?:\bver(?:sion)?|верси\w*|\bv|build|release|сборк\w*|релиз\w*|->|→)[\s=:.]*$",
                                       m.string[max(0, m.start() - 14):m.start()], _I)       # «версии 4.18.2.117»
         and not re.match(r"127\.|0\.0\.0\.0$|255\.|192\.168\.[01]\.1$|10\.0\.0\.1$", m.group())),   # свой узел, маска, роутер
    Rule(Kind.MAC, r"\b(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b", flags=_I),
    # счета физлиц (408xx), ИП (40802), вклады (423xx): 20 цифр
    Rule(Kind.ACCOUNT, _D + r"(?:408\d{2}|423\d{2})\d{15}" + _E),
    Rule(Kind.ACCOUNT, r"(?:лицев\w*\s+сч[её]т\w*|л/с)\s*(?:№\s*)?(\d[\d -]{5,24}\d)", group=1, flags=_I),
    Rule(Kind.CARD, _D + r"\d{4}(?:[ -]?\d{4}){2,3}(?:[ -]?\d{1,3})?" + _E, check=lambda m: _card_like(m)),
    Rule(Kind.INN, _D + r"\d{12}" + _E, check=lambda m: inn12_ok(m.group())),
    Rule(Kind.INN, r"(?:ИНН|INN|TIN)\W{0,10}(\d{12}|\d{4}\s\d{4}\s\d{4})" + _E, group=1, flags=_I),
    Rule(Kind.SNILS, _D + r"\d{3}[- ]?\d{3}[- ]?\d{3}[- ]\d{2}" + _E, check=lambda m: snils_ok(only_digits(m.group()))),
    Rule(Kind.SNILS, r"СНИЛС\W{0,10}(\d{3}[- ]?\d{3}[- ]?\d{3}[- ]?\d{2})" + _E, group=1, flags=_I),
    # российский номер: код оператора или города начинается с 3, 4, 8, 9 (6 и 7 — Казахстан);
    # «912 3456 7801» — номер конференции, а не телефон
    Rule(Kind.PHONE, r"(?<![\d\w+])(?:\+7|8)[\s(-]*[346789]\d{2}[\s)-]*\d{3}[\s-]*\d{2}[\s-]*\d{2}" + _E,
         check=lambda m: not toll_free(m.group())),
    Rule(Kind.PHONE, r"(?<![\d\w+/.-])79\d{9}(?![\d\w])"),      # «to=79127460358»: мобильный без плюса
    Rule(Kind.PHONE, r"(?<![\d\w])\+(?:[1-689]\d{0,2})[\s(.-]*\d{1,4}[\s).-]*\d{2,4}[\s.-]*\d{2,4}(?:[\s.-]*\d{2,4})?" + _E),
    Rule(Kind.PASSPORT, r"(?:паспорт\w*|passport)(?:\s+(?:серия|номер|№|no\.?|number|is))*[^\d]{0,60}?"
                        r"(\d{2}\s?\d{2}(?:\s*№\s*|\s+|\s*-\s*)?\d{6}|\d{2}\s\d{7}|[A-ZА-ЯЁ]{1,2}\s?\d{7,8})" + _E, group=1, flags=_I, lines=True),
    # адрес с квартирой — всегда жильё человека (адрес без квартиры может быть офисом — решает модель)
    Rule(Kind.ADDRESS, r"(?:(?:\d{6},\s*)?(?:г\.|город|пос\.|с\.)\s*[А-ЯЁ][\w-]+(?:\s[А-ЯЁ][\w-]+)?,\s*)?"
                       r"(?:ул\.|улиц[аеуы]|пр-т|просп\.|проспект\w?|пер\.|переул\w+|ш\.|шоссе|б-р|бульвар\w?|наб\.|"
                       r"набережн\w+|пр\.|мкр\.?|микрорайон\w?|пл\.|площад\w)"
                       r"\s*[^,\n]{2,40},\s*(?:д\.|дом)\s*\d+[\w/-]*(?:,?\s*(?:корп\.|к\.|стр\.|корпус)\s*\d+\w*)?"
                       r",?\s*(?:кв\.?|квартир[аеуы])\s*\d+", flags=_I),
    Rule(Kind.PASSPORT, r"(?:загран\w*|заграничн\w+\s+паспорт\w*|passport\s+no\.?)[^\d]{0,40}?(\d{2}\s?\d{7})" + _E,
         group=1, flags=_I),
    # серия и номер порознь: «паспорт серии 51 79 номер 504661»
    Rule(Kind.PASSPORT, r"сери[ияю]\s*(\d{2}\s?\d{2})(?=\s*,?\s*(?:номер|№)\s*\d{6})", group=1, flags=_I, lines=True),
    Rule(Kind.PASSPORT, r"сери[ияю]\s*\d{2}\s?\d{2}\s*,?\s*(?:номер|№)\s*(\d{6})" + _E, group=1, flags=_I, lines=True),
    # JSON внутри текста: "passport": {"series": "0817", "number": "455209"}
    Rule(Kind.PASSPORT, r"passport\W{1,8}(?:\w+\W{1,6}){0,2}?series\W{1,6}(\d{4})" + _E, group=1, flags=_I, lines=True),
    Rule(Kind.PASSPORT, r"passport[^\n]{0,60}?number\W{1,6}(\d{6})" + _E, group=1, flags=_I),
    # номера, привязанные к человеку, у которых нет своей метки модели: дело, табельный, пропуск, логин
    Rule(Kind.ID, r"\bдел[оау]\s*№\s*([\w/-]*\d[\w/-]*)", group=1, flags=_I, check=lambda m: len(m.group(1)) >= 4),
    Rule(Kind.ID, r"(?:таб\.?|табельн\w*)\s*(?:номер|№|no\.?)?\s*:?\s*((?:[A-ZА-ЯЁ]{1,3}-)?\d{3,10})" + _E, group=1, flags=_I),
    Rule(Kind.ID, r"пропуск\w*\s*(?:№|номер)\s*(\w*\d[\w-]*)", group=1, flags=_I),
    Rule(Kind.HANDLE, r"(?:(?<![^\W_])(?:[a-z]+_)?user(?:name)?|\blogin|логин|пользователь|\bby|\bauthor|\bowner|\bassignee|"
                      r"\breporter|\bmanager|автор|ник|никнейм|выгрузил\w*)[\"']?\s*[:=]\s*[\"']?([A-Za-z][\w.-]{2,}[A-Za-z0-9])(?![\w@])",
         group=1, flags=_I, check=lambda m: not _service(m.group(1)) and _login_like(m.group(1))),   # «login: svc_backup» — нет
    # «n.gogoberidze», «k.bonch»: инициал, точка, фамилия — так выглядит рабочая учётная запись
    Rule(Kind.HANDLE, r"(?<![\w.@/\\-])[a-z]\.[a-z]{4,}(?![\w@.-])",
         check=lambda m: not _FILE_OR_ZONE.fullmatch(m.group()[2:])),
    # автор перед адресом в угловых скобках: «zarina-k <zarina.k@…>»
    Rule(Kind.HANDLE, r"(?<![\w.@-])([a-z][a-z0-9]*(?:[._-][a-z0-9]+)+)\s+<[^<>\s@]+@[^<>\s]+>", group=1,
         check=lambda m: not _service(m.group(1))),
    # учётная запись 1С: «БабаджанянРС»
    Rule(Kind.HANDLE, r"(?<![\w])[А-ЯЁ][а-яё]{3,}[А-ЯЁ]{2}(?![\w])"),
    # «Учётка k.nepeyvoda», «логин ivanov_pp»: без двоеточия — только то, что выглядит как учётная запись
    Rule(Kind.HANDLE, r"(?:уч[её]тк\w*|уч[её]тн\w+\s+запис\w+|логин\w*|\blogin|аккаунт\w*|\buser|пользовател\w+|\bник\w*|профил\w+)"
                      r"(?:\s+[а-яё]{3,})?(?:\s+|\s*[—–-]\s*)[\"'«]?"
                      r"((?:[a-z][a-z0-9-]*\\)?(?:[a-z][a-z0-9]*[._-][a-z0-9._-]*[a-z0-9]|[a-z]+\d+[a-z0-9]*))(?![\w@])",
         group=1, flags=_I),
    # госномер автомобиля (буквы — только те, что есть в латинице, как на номерах), и с латиницей из OCR
    Rule(Kind.ID, r"(?<![\w])[АВЕКМНОРСТУХABEKMHOPCTYX]\s?\d{3}\s?[АВЕКМНОРСТУХABEKMHOPCTYX]{2}\s?\d{2,3}(?:\s?RUS)?(?![\w])", flags=_I,
         check=lambda m: bool(re.search(r"[А-ЯЁ]", m.group())) or m.group().isupper()
         or bool(re.fullmatch(r"[авекмнорстух]\d{3}[авекмнорстух]{2}\d{2,3}", m.group()))        # «о902мр116»
         or bool(_CAR_NEAR.search(m.string[max(0, m.start() - 70):m.start()]))),                    # «киа рио, в 478 ру 198»
    # адрес после «по адресу» / «адрес проживания» — и без квартиры; адреса организаций не трогаем
    Rule(Kind.ADDRESS, r"(?:по\s+адресу|адрес\w*(?:\s+(?:проживания|регистрации|места\s+жительства))?|прожива\w+|"
                       r"зарегистрирован\w*)\s*:?\s*"
                       r"((?:\d{6},\s*)?(?:[^,\n;:]{2,40},\s*){0,3}"
                       r"(?:ул\.|улиц\w+|пр-т|просп\.|проспект\w?|пер\.|переул\w+|ш\.|шоссе|б-р|бульвар\w?|наб\.|мкр\.?|пл\.)"
                       r"\s*[^,\n;]{2,40},?\s*(?:д\.|дом)?\s*\d+[\w/-]*(?:,?\s*(?:корп\.|к\.|стр\.|корпус)\s*\d+\w*)?"
                       r"(?:,?\s*(?:кв\.?|квартир\w+)\s*\d+)?)", group=1, flags=_I,
         check=lambda m: not ORG_NEAR.search(m.string[max(0, m.start() - 160):m.start()])
         and not OFFICE.search(m.group(1) + m.string[m.end():m.end() + 30])),
    # даты: у модели нет страховки, а в плотных списках она теряет короткие «25.10.81»
    Rule(Kind.DATE, r"(?<![\d.\w])(?:0?[1-9]|[12]\d|3[01])[./](?:0?[1-9]|1[0-2])[./](?:19|20)\d{2}(?![\w]|[./]\d)"),
    Rule(Kind.DATE, r"(?<![\d.\w])(?:0[1-9]|[12]\d|3[01])[./](?:0[1-9]|1[0-2])[./]\d{2}(?![\w]|[./]\d)"),
    Rule(Kind.DATE, r"(?<![\d\w])(?:19|20)\d{2}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])(?![\d\w])"),
    Rule(Kind.DATE, r"(?<![\d\w])(?:0?[1-9]|[12]\d|3[01])\s+(?:январ|феврал|март|апрел|ма[йя]|июн|июл|август|сентябр|октябр|"
                    r"ноябр|декабр)\w*\s+(?:19|20)\d{2}(?:\s+(?:года|г\.))?(?![\d\w])", flags=_I),
    Rule(Kind.DATE, r"(?<![\d\w-])(?:0[1-9]|[12]\d|3[01])-(?:0[1-9]|1[0-2])-(?:19|20)\d{2}(?![\d\w-])"),
]

# Номер после слова, которое называет документ или учётную запись: модель общего класса «прочие ПДн» не знает,
# а в деловых бумагах такие номера стоят именно так — «договор № ДК-689265», «полис 9923454279964053», «VIN …».
_NUMBERED = (r"а/к|талон\w*|ипра|договор\w*|контракт\w*|соглашени\w*|полис\w*|омс|дмс|удостоверени\w*|свидетельств\w*|в/у|"
             r"водительск\w+(?:\s+удостоверени\w+)?|мед\.?\s?карт\w*|медицинск\w+\s+карт\w*|амбулаторн\w+\s+карт\w*|"
             r"истори\w+\s+болезни|лицев\w+\s+сч[её]т\w*|табельн\w+(?:\s+номер\w*)?|таб\.?\s?(?:№|номер)|ву|"
             r"студенческ\w+(?:\s+билет\w*)?|зач[её]тн\w+(?:\s+книжк\w*)?|пропуск\w*|кредит\w*|за[её]м\w*|займ\w*|"
             r"паспорт\w*\s+тс|эптс|патент\w*|элн|лн|больничн\w+|лист(?:ок|к\w+)\s+нетрудоспособности|исполнительн\w+\s+лист\w*|"
             r"доверенност\w+|сертификат\w*|справк\w+\s+мсэ[\w-]*|"
             r"сотрудник\w*\s+(?:№|номер)|employee\s+id|staff\s+id|vin|вин|птс|стс|диплом\w*|аттестат\w*|"
             r"военн\w+\s+билет\w*|карт[аеуы]|картой")
RULES += [
    # между словом и номером — до трёх слов-пояснений: «договор оферты АК-2024/5567», «по полису ОСАГО ХХХ 0312457788»
    Rule(Kind.ID, rf"(?<![\w])(?i:{_NUMBERED})(?:\s+(?:[а-яё]+(?:-[а-яё]+)?|[A-ZА-ЯЁ]+)){{0,4}}?"
                  r"(?:\s+от\s+\d{1,2}[.\s]\S{1,10}[.\s]\d{2,4}(?:\s*г\.?)?)?\s*(?:№|#|:)?\s*(?:№\s*)?-?"
                  r"((?:[A-ZА-ЯЁ]{1,4}[ -])?(?=[\w/\-]*\d)[A-ZА-ЯЁ\d][\w/\-]*(?:\.\d[\w/\-]*)*(?:[ ]\d{2,}){0,3}(?:\s*№\s*\d{5,})?)(?![\w])"
                  r"(?!\s*(?:руб|₽|р\.|коп|%|шт|тыс|млн|usd|eur|\$|€|дн|лет|год|час|мес))",
         group=1, check=lambda m: _id_like(m.group(1)) and not _amount_like(m.group(1)), lines=True),
    # прежняя фамилия: «до брака — Иволга», «девичья фамилия Белая»
    Rule(Kind.PERSON, r"(?:девичь\w+\s+фамили\w+|до\s+брака|в\s+девичестве|урожд[её]нн\w+)\s*[—–:-]?\s*([А-ЯЁ][а-яё]{2,}(?:-[А-ЯЁ][а-яё]+)?)"
                      r"(?![\w-])", group=1, flags=_I,
         check=lambda m: m.group(1)[:1].isupper()),
    # номер с буквами серии — «ДМС-2025-0048817», «Д-823748» — когда в той же строке перед ним названа бумага человека;
    # сам по себе так же выглядит номер заявки, заказа или счёта («HD-20418», «INV-2025-0871»)
    Rule(Kind.ID, r"(?<![\w-])[A-ZА-ЯЁ]{1,5}-(?:\d{2,4}[-/]\d{3,}|\d{5,})(?![\w-])", check=lambda m: _paper_before(m)),
    # серия буквами и номер: «серия ХХХ № 8396964188»; регион и номер: «77 № 2400959306»
    Rule(Kind.ID, r"сери[ияю]\s+([A-ZА-ЯЁ]{2,4}\s*№\s*\d{6,})" + _E, group=1, flags=_I),
    Rule(Kind.ID, _D + r"\d{2}\s*№\s*\d{8,}" + _E),
    # документы на автомобиль и права: «78 РК 208796», «52 ОК 688105»
    Rule(Kind.ID, r"(?<![\w])\d{2}\s[А-ЯЁ]{2}\s\d{6,7}(?![\w])"),
    Rule(Kind.ID, r"ОГРНИП\W{0,6}(\d{15})" + _E, group=1),
    # машиночитаемая зона паспорта: в ней и имя, и номер, и дата рождения
    Rule(Kind.ID, r"^[A-Z0-9<]*<<[A-Z0-9<]{8,}$|^(?=[A-Z0-9<]*<)[A-Z0-9<]{28,}$", flags=re.MULTILINE),
    Rule(Kind.IP, r"(?<![\w:])(?:[0-9a-f]{1,4}:){2,7}(?::[0-9a-f]{1,4}|[0-9a-f]{1,4})(?::[0-9a-f]{1,4})*(?![\w:])", flags=_I,
         check=lambda m: "::" in m.group() or m.group().count(":") >= 5),
    # год рождения без даты: «Хайруллина Диляра Наилевна, 1990 г. р.»
    Rule(Kind.BIRTHDATE, _D + r"((?:19|20)\d{2})\s*(?:г\.?\s?р\.?(?!\w)|года\s+рожд|г\.?\s*рожд)", group=1, flags=_I),
    # внутренний и добавочный номер: «внутр. 76799», «доб. 1234»
    Rule(Kind.ID, r"(?<![\w])(?:внутр|внутренний|доб|добавочный|ext)\.?\s*(?:№|номер)?\s*:?\s*(\d{3,6})" + _E, group=1, flags=_I),
    # паспорт без слова «паспорт»: серия из двух пар цифр и шестизначный номер — «15 34 621813», «81 62 № 413849»
    Rule(Kind.PASSPORT, _D + r"\d{2}\s\d{2}\s*(?:№\s*)?\s\d{6}" + _E, lines=True),
    Rule(Kind.PASSPORT, _D + r"\d{4}\s(?:№\s*)?\d{6}" + _E, check=lambda m: m.group()[:2] not in ("19", "20")),
    Rule(Kind.ID, r"\bVIN\b[\s:№]*([A-HJ-NPR-Z0-9]{17})(?![\w])", group=1, flags=_I),
    # «Адрес: Луговой проезд 45-172» — поле анкеты; адреса организаций не трогаем
    Rule(Kind.ADDRESS, r"(?:^|[\n;|])\s*(?:домашний\s+)?адрес\w*(?:\s+(?:проживания|регистрации|места\s+жительства|по\s+прописке))?"
                       r"\s*:\s*([^\n;|]{4,90}?\d[\w/-]*)(?=\s*(?:$|[\n;|]))", group=1, flags=_I | re.MULTILINE,
         check=lambda m: bool(re.search(r"[А-ЯЁA-Z]", m.group(1)))
         and not ORG_NEAR.search(m.string[max(0, m.start() - 160):m.start()]) and not ORG_NEAR.search(m.group(1))
         and not OFFICE.search(m.group(1) + m.string[m.end():m.end() + 30])),
    # маскированная карта: «4276 **** **** 8909»
    Rule(Kind.CARD, _D + r"\d{4}(?:[ -]?[*•xXхХ]{4}){1,2}[ -]?(?:[*•xXхХ]{4}[ -]?)?\d{4}" + _E),
    Rule(Kind.ID, r"(?<![\w])[A-HJ-NPR-Z0-9]{17}(?![\w])", check=lambda m: _vin_like(m.group())),
]


def _card_like(m: re.Match[str]) -> bool:
    """Номер карты: контрольная сумма Луна и 16 цифр платёжной системы. Другая длина — только рядом со словом «карта»:
    у штрих-кода, ОГРН или инвентарного номера сумма Луна сходится в одном случае из десяти."""
    digits = only_digits(m.group())
    if not luhn_ok(digits):
        return False
    if len(digits) == 16 and digits[0] in "23456":
        return True
    return bool(re.search(r"карт|card|visa|master|\bмир\b|\bpan\b", m.string[max(0, m.start() - 40):m.start()], _I))


_PAPER = re.compile(rf"(?<![\w])(?:{_NUMBERED})(?![\w])", _I)


def _paper_before(m: re.Match) -> bool:
    if m.group().split("-")[0].lower() in ("дмс", "омс", "элн", "птс", "стс", "эптс"):     # бумага названа самим номером
        return True
    line = m.string[m.string.rfind("\n", 0, m.start()) + 1:m.start()]
    return bool(_PAPER.search(line[-60:]))


def _amount_like(value: str) -> bool:
    """«30 000», «1 250 000» — сумма (разряды по три цифры), а не номер. Двенадцать цифр тройками — уже номер."""
    return bool(re.fullmatch(r"\d{1,3}(?:[ \u00a0]\d{3}){1,2}", value.strip()))


def toll_free(value: str) -> bool:
    """8-800 и 8-804 — бесплатные номера организаций: горячая линия — не персональные данные."""
    digits = only_digits(value)
    return len(digits) == 11 and digits[0] in "78" and digits[1:4] in ("800", "804")


def _id_like(value: str) -> bool:
    """Номер документа: не меньше четырёх цифр («2019» после «договор» — год, а не номер)."""
    digits = sum(ch.isdigit() for ch in value)
    if digits < 4:
        return False
    return not (digits == 4 and value.isdigit() and value[:2] in ("19", "20"))


def _vin_like(value: str) -> bool:
    return sum(ch.isdigit() for ch in value) >= 4 and sum(ch.isalpha() for ch in value) >= 4


# Рядом с адресом: это организация, а не жильё. Регистр важен только для форм собственности.
ORG_NEAR = re.compile(r"(?i:офис|компани|организаци|юридическ|фирм|магазин|филиал|место\s+работы|склад|шоурум|клиник|"
                      r"гостиниц|отел[ьяюе]|\bбанк|инспекци|лицензи|учрежден|салон|сервис|завод|фабрик|\bкпп\b|\bогрн\b|"
                      r"employer|company|\boffice\b|\bllc\b|\bltd\b|\bооо\b|\booo\b)|"
                      r"\b(?:ООО|ОАО|ЗАО|ПАО|АО|ГБУЗ?|ГАУЗ?|МБОУ|ФГУП|МУП|ГУП|НКО|АНО)\b|\bИНН\W{0,3}\d{10}\b")
# В самом адресе или сразу за ним: помещение, а не квартира.
OFFICE = re.compile(r"(?<![\w])(?:офис|office|оф\.|пом\.|помещени\w+|бц|тц|трц|бокс|этаж|каб\.|кабинет|склад|вход|павильон|"
                    r"стр\.|строение|литер\w*)(?![\w])", _I)
# Без чего ни одно правило и ни одно поле анкеты не сработает: цифра, «@», «<», ссылка, слово про учётную запись
# или подпись поля. Дешёвая проверка перед полусотней шаблонов — в таблицах большинство ячеек её не проходит.
_MAY_MATCH = re.compile(r"[\d@<=]|://|www\.|\w\.(?:com|ru|me|us)/|парол|password|passwd|pwd|secret|секрет|token|токен|ключ|"
                        r"логин|login|уч[её]т|аккаунт|skype|скайп|telegram|телеграм|фамили|отчеств|\bимя\b|\bфио\b|"
                        r"name|holder|сотрудник|работник|руководител|получател|пациент|клиент|контактн|ответственн|"
                        r"исполнитель|manager|employee|contact|кодов|девичь|брака|урожд|\bник|профил|автор|author|owner|резервн|"
                        r"[a-z]\.[a-z]{4}|(?-i:[а-яё][А-ЯЁ]{2}\b)", re.IGNORECASE)


def may_match(text: str) -> bool:
    return bool(_MAY_MATCH.search(text))


# Вторая строка машиночитаемой зоны паспорта: номер (9 цифр), контрольная цифра, гражданство, дата рождения.
_MRZ_NUMBER = re.compile(r"(?m)^(\d{9})\d[A-Z<]{3}\d{6}\d[MF<]")


def rule_spans(text: str) -> list[Span]:
    out: list[Span] = []
    for rule in RULES:
        out.extend(rule.find(text))
    # номер из машиночитаемой зоны — тот же, что напечатан в шапке скана («75 5330241»)
    for m in _MRZ_NUMBER.finditer(text):
        number = m.group(1)
        for hit in re.finditer(rf"(?<!\d){number[:2]}\s?{number[2:]}(?!\d)", text):
            out.append(Span(hit.start(), hit.end(), Kind.PASSPORT, 1.0, "rule"))
    return out


# ---------- дата рождения ----------

_BIRTH_BEFORE = re.compile(r"рожд|родил|г\.?\s?р\b|д\.?\s?р\b|д/р|\bдр\b|dob\b|birth|born", _I)
_BIRTH_AFTER = re.compile(r"^\s*\(?\s*(?:г\.?\s?р\b|года\s+рожд|г\.?\s*рожд)", _I)
_LOOKBACK = 36


def birth(text: str, span: Span) -> Span:
    """Дата рядом со словом «рождения» / «г.р.» / «DOB» — дата рождения. Её режим «Оставить даты» не открывает.

    Смотрим назад только до ближайшего разделителя или другого числа: в «родился 12.03.1985, приказ от 01.02.2020»
    дата приказа рождением не станет."""
    if span.kind is not Kind.DATE:
        return span
    before = text[max(0, span.start - _LOOKBACK):span.start]
    for sep in (";", "\n", "|", ". "):
        before = before.rsplit(sep, 1)[-1]
    before = re.split(r"\d{2,}", before)[-1]
    before = _BIRTH_AFTER.sub("", before, count=1)  # «14.02.1988 г.р., принят 03.03.2025»: «г.р.» — о прошлой дате
    if _BIRTH_BEFORE.search(before) or _BIRTH_AFTER.match(text[span.end:span.end + 18]):
        return Span(span.start, span.end, Kind.BIRTHDATE, span.score, span.source)
    return span

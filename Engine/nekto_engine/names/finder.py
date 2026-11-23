"""Поиск людей в тексте: решение по совокупности свидетельств, а не по одному голосу модели.

Модель ошибается в обе стороны, и уверенность тут не помощник: «продажников» — фамилия с оценкой 0,99, «Олю» перед
«Нестеренко» — пропуск. Поэтому слово становится частью ФИО, только если сходятся независимые свидетельства:

  словарь   — имя, отчество, фамилия по форме или по словарю, обычное слово, топоним (`lexicon`);
  регистр   — заглавная в середине предложения (сильное свидетельство), в начале предложения или слово целиком
              заглавными (слабое: так пишут что угодно), строчная;
  соседи    — слово с заглавной вплотную к имени — фамилия («Константина Иволга»), буква с точкой рядом — инициал;
  документ  — слово, которое в этом же документе пишут со строчной («продажник», «продажника», «продажники»), — не фамилия,
              даже когда стоит в начале предложения с заглавной;
  модель    — метки имени/фамилии/отчества и их уверенность.

Чем слабее одно, тем больше требуется от остальных: «Петя молодец» в начале предложения проходит по словарю без
модели; «Рихтер сказал» — только с моделью; «Дизайнеры» с меткой модели, но обычное слово в начале предложения, — нет.
Каждое правило ниже названо примером, на котором оно проверено (tests/test_finder.py).
"""
from __future__ import annotations

import re
from bisect import bisect_left
from dataclasses import dataclass
from functools import lru_cache
from typing import Iterable, Sequence

from ..model import Tag
from . import mention
from .lexicon import Lex, lookup, morph

PERSON_LABELS = {"FIRST_NAME", "LAST_NAME", "MIDDLE_NAME"}
PLACE_LABELS = {"CITY", "REGION", "DISTRICT", "COUNTRY", "STREET"}

_WORD = re.compile(r"[^\W\d_]+(?:[-'’][^\W\d_]+)*")
_STRONG_SHAPES = {"ov", "sky", "enko", "ich", "yan", "ih", "uk", "geo"}
_SENTENCE_END = ".!?…"
_CLAUSE_START = ":;—–-•*·«\"“„'(/|\\>"
# Слова, которые стоят вплотную к имени с заглавной буквы, но фамилией не бывают.
_NOT_NAMES = {
    "уважаемый", "уважаемая", "уважаемые", "дорогой", "дорогая", "дорогие", "глубокоуважаемый", "глубокоуважаемая",
    "многоуважаемый", "многоуважаемая", "милый", "милая", "гражданин", "гражданка", "господин", "госпожа", "товарищ",
    "истец", "истица", "ответчик", "ответчица", "старший", "младший", "главный", "новый", "спасибо", "благодарю",
    "благодарим", "привет", "здравствуйте", "здравствуй", "коллега", "коллеги", "добрый", "доброе", "отдел", "группа",
    "департамент", "управление", "служба", "команда", "компания", "директор", "менеджер", "руководитель", "начальник",
    "заказчик", "исполнитель", "подрядчик", "поставщик", "покупатель", "продавец", "клиент", "пациент", "врач",
    "приложение", "глава", "статья", "пункт", "раздел", "таблица", "рисунок", "схема", "форма", "образец", "вариант",
    "рис", "табл", "прил", "гл", "ст", "см", "стр", "том", "кн", "тема", "итог", "дата", "подпись", "фио", "имя", "фамилия",
    "отчество", "кому", "от", "кто", "автор", "контакт", "ответственный", "сотрудник", "работник", "водитель",
    "бухгалтер", "инженер", "юрист", "аналитик", "разработчик", "дизайнер", "программист", "секретарь", "специалист",
    "администратор", "координатор", "консультант", "оператор", "кассир", "курьер", "охранник", "техник", "мастер",
    "стажёр", "стажер", "ассистент", "помощник", "заместитель", "председатель", "президент", "генеральный",
    "исполнительный", "технический", "финансовый", "коммерческий", "ведущий", "большое", "огромное", "отдельное",
    # стороны договора и участники дела: в документах пишутся с заглавной и склоняются, как фамилии
    "работодатель", "арендатор", "арендодатель", "заёмщик", "заемщик", "займодавец", "кредитор", "должник",
    "страхователь", "страховщик", "застрахованный", "выгодоприобретатель", "поручитель", "доверитель", "поверенный",
    "представитель", "заявитель", "сторона", "общество", "банк", "абонент", "пользователь", "лицензиат", "лицензиар",
    "агент", "принципал", "комитент", "комиссионер", "грузоотправитель", "грузополучатель", "перевозчик", "наниматель",
    "наймодатель", "собственник", "участник", "акционер", "учредитель", "даритель", "одаряемый", "наследник",
    "наследодатель", "потерпевший", "свидетель", "обвиняемый", "подсудимый", "взыскатель", "плательщик", "получатель",
    "отправитель", "держатель", "владелец", "работница", "сотрудница", "студент", "ученик",
    # подписи полей в двуязычных бланках
    "surname", "name", "names", "given", "sex", "date", "birth", "place", "nationality", "signature", "passport",
    "type", "code", "authority", "holder", "issue", "expiry", "пол",
}
# Частицы восточных отчеств: «Алиева Лейла Вагиф кызы», «Мамедов Эльчин Тофик оглы».
_PATRONYMIC_PARTICLES = {"оглы", "оглу", "кызы", "кизи", "гызы", "улы", "уулу"}
# После этих слов фамилия — название, а не человек: «Институт Склифосовского», «имени Баумана», «завод Лихачёва».
_NAMED_AFTER = {
    "лаборатория", "лаборатории", "лабораторию", "лабораторией", "имени", "им", "завод", "завода", "заводе", "фабрика",
    "фабрики", "театр", "театра", "театре", "музей", "музея", "музее", "институт", "института", "институте",
    "университет", "университета", "университете", "библиотека", "библиотеки", "парк", "парка", "парке", "сквер",
    "премия", "премии", "премию", "стипендия", "стипендии", "фонд", "фонда", "орден", "ордена", "медаль", "канал",
    "канала", "улица", "улицы", "улице", "ул", "проспект", "проспекта", "проспекте", "площадь", "площади", "метро",
    "станция", "станции", "переулок", "переулка", "шоссе", "набережная", "набережной", "бульвар", "бульвара",
}
# То же в медицине и науке: «болезнь Паркинсона», «симптом Пастернацкого», «проба Реберга», «диаграмма Ганта».
_NOUN_END = r"(?:а|у|ом|е|ы|ов|ам|ами|ах|и|ю|ей|ой|ь|я|й|ям|ями|ях)?"
_EPONYM = re.compile(r"(?:болезн|синдром|симптом|проб|метод|шкал|индекс|тест|реакци|триад|критери|закон|теорем|формул|"
                     r"эффект|принцип|диаграмм|аппарат|способ|классификаци|перелом|грыж|кист|палочк|пучк|узл|ряд|план|"
                     r"уравнени|интеграл|неравенств|постоянн|распределени|преобразовани|алгоритм|гипотез|парадокс|"
                     r"машин|цикл|правил)" + _NOUN_END
                     + r"|пучок|узел")
# «анализ мочи по Нечипоренко», «ФВ 52% по Симпсону», «мониторирование по Холтеру»: способ, названный по автору.
_BY_AUTHOR = re.compile(r"(?:анализ|оценк|окраск|пластик|операци|исследовани|мониторировани|фракци|клиренс|проб|метод|шкал|"
                        r"индекс|тест|классификаци|стади)" + _NOUN_END + r"|эхокг|узи|экг|фв|скф|соэ")
# Клички и названия: «кот Василий», «собака Найда» — не люди.
_PET = re.compile(r"(?:кот|кошк|котик|котён|котен|пёс|пес|пс|собак|щен|попуга|хомяк|питом|кличк|лошад|кон)" + r"[а-яё]{0,3}")
_ASSISTANT = re.compile(r"голосов|навык|колонк|станци|ассистент|умн\w+\s+дом|яндекс|yandex", re.IGNORECASE)
# Перед кавычками — слово о человеке: «на бейдже «Кристина»», «по имени «Гоша»».
_PERSON_CUE = re.compile(r"(?:бейдж|имен|им|зовут|звать|подпис|табличк|прозвищ|псевдоним|фамили|ник|строк|запис|значени|"
                         r"ячейк|пол)[а-яё]{0,3}")
_HONORIFIC = {"ак", "акад", "академика", "проф", "профессора", "д-ра", "доктора"}
_QUOTED = re.compile(r"[«\"“„]([^«»\"“”„\n]{2,40})[»\"”]")
# Реплика в переписке: «[12:05] Клиент: нет я исмаилов» — регистр судим по тексту после автора.
_CHAT_PREFIX = re.compile(r"\s*(?:\[[^\]\n]{1,24}\]\s*|\d{1,2}:\d{2}(?::\d{2})?\s*(?:[-–—]\s*)?)?(?:[^\s:][^:\n]{0,38}:\s+)?")
_CAPITALIZED = re.compile(r"[А-ЯЁ][а-яё]")
# Что словом документа не считается: почта, ссылки, логины — «giniyatullina@example.org» не делает фамилию обычным словом.
_NOT_PROSE = re.compile(r"\S*[@/_]\S*|[\w-]+(?:\.[\w-]+)+")
# Сокращения с точкой, после которых предложение не начинается: «г. Казань», «тов. Иванов», «им. Баумана».
# Именно список: «…пять раз. Вера в команду…» — «раз.» не сокращение, хоть и короткое.
_ABBREVIATIONS = frozenset("""
г гор ул пр просп пер пл наб ш мкр д кв корп стр оф каб эт пос с дер обл р-н респ им тов гр г-н г-жа проф акад доц др
инж зам нач зав рук дир ген исп отв пом ст мл вед гл тел моб факс эл см рис табл п пп ч т тт e-mail
""".split())
# Слово после имени-омонима, которое выдаёт обычное существительное: «Вера в…», «Надежда только на…», «Роман с…».
_AFTER_NOUN = {"в", "во", "на", "с", "со", "к", "ко", "о", "об", "от", "для", "без", "по", "из", "у", "за", "над", "под",
               "при", "про", "через", "между", "только", "лишь", "есть", "была", "был", "будет", "остаётся", "остается",
               "умирает", "закончен", "закончился", "затянулся"}
_OPEN_POS = {"NOUN", "ADJF", "ADJS", None}           # части речи, которыми бывает фамилия-слово («Иволга», «Белый»)


@dataclass(slots=True)
class Token:
    start: int
    end: int
    text: str
    cap: int                    # 0 — строчная, 1 — заглавная без веса (начало предложения, ВСЕ ЗАГЛАВНЫЕ), 2 — в середине
    upper: bool                 # слово целиком заглавными
    mixed: bool                 # регистр вперемешку: «ВкусВилл», «iPhone» — так имена не пишут
    initial: bool               # буква с точкой
    lex: Lex
    person: float = 0.0         # уверенность модели в метке имени/фамилии/отчества
    place: float = 0.0          # уверенность модели в топониме
    noun_use: bool = False      # дальше предлог или «только»: «Надежда только на вас», «Роман с агентством»
    by_initial: bool = False    # вплотную стоит инициал: «Волк М.», «И. Мороз»
    named_after: bool = False   # «Институт Склифосовского», «имени Баумана»: названо в честь, а не упомянут человек
    caseless: bool = False      # строка написана без заглавных вовсе: регистр в ней ничего не значит
    title: bool = False         # название в кавычках: диван «Мартин», тариф «Макс», БЦ «Аврора Плаза»
    eponym: bool = False        # «синдром Арнольда — Киари»: и имя тут — название
    honor: bool = False         # «им. ак. Е. Н. Мешалкина»: названо в честь, хоть и с инициалами
    accepted: bool = False

    @property
    def latin(self) -> bool:
        return self.text.isascii()

    @property
    def low(self) -> str:
        return self.text.lower()

    @property
    def given(self) -> bool:
        """Имя или отчество по словарю."""
        return self.lex.first or bool(self.lex.patrs)

    @property
    def surname_like(self) -> bool:
        return (self.lex.shape in _STRONG_SHAPES or self.lex.surname) and self.lex.common < 0.3 and not self.lex.geo

    @property
    def abbreviation(self) -> bool:
        return self.upper and len(self.text) <= 4 and not self.given


class Vocabulary:
    """Слова документа, написанные со строчной: что документ считает обычными словами."""

    _ENDINGS = ("иями", "ями", "ами", "ией", "иях", "ов", "ев", "ей", "ом", "ем", "ам", "ям", "ах", "ях", "ою", "ию",
                "ия", "ие", "ий", "ой", "ый", "ая", "яя", "ую", "юю", "а", "я", "у", "ю", "е", "ы", "и", "о", "ь", "й")

    def __init__(self, segments: Iterable[str] = ()) -> None:
        self._lower: set[str] = set()
        self.names: set[str] = set()         # имена, которые документ пишет с заглавной посреди фразы: «от Вики»
        for seg in segments:
            self.add(seg)

    def add(self, segment: str) -> None:
        if "@" in segment or "/" in segment or "_" in segment or "." in segment:
            segment = _NOT_PROSE.sub(lambda m: " " * len(m.group()), segment)
        for m in _WORD.finditer(segment):
            word = m.group()
            if len(word) < 3:
                continue
            if word[0].islower():
                self._lower.add(word)
                self._lower.add(self.stem(word))
            elif m.start() >= 2 and segment[m.start() - 1] == " " and (segment[m.start() - 2].islower() or segment[m.start() - 2] == ","):
                self.names.update(r.lemma for r in lookup(word.lower()).firsts)

    def names_any(self, lex: Lex) -> bool:
        return any(r.lemma in self.names for r in lex.firsts)

    def __contains__(self, word: str) -> bool:
        low = word.lower()
        return low in self._lower or self.stem(low) in self._lower

    @classmethod
    def stem(cls, low: str) -> str:
        for ending in cls._ENDINGS:
            if low.endswith(ending) and len(low) - len(ending) >= 3:
                return low[:-len(ending)]
        return low


def tokens(text: str) -> list[Token]:
    out: list[Token] = []
    plain = _caseless_lines(text)
    for m in _WORD.finditer(text):
        word = m.group()
        start, end = m.span()
        initial = len(word) == 1 and word.isupper() and text[end:end + 1] == "."
        upper = len(word) >= 2 and word.isupper()
        parts = [p for p in re.split(r"[-'’]", word) if p]
        proper = all(p[0].isupper() and (p[1:].islower() or p.isupper()) for p in parts)   # «Мирак-Орлова», не «ИИ-ассистентов»
        cap, mixed = 0, False
        if _code_part(text, start, end):                       # «Бикбаев-2», «Orion_X2», «Ту-154»: часть обозначения,
            upper = False                                      # заглавная тут ничего не говорит
        elif word[0].isupper() and (proper or upper):
            cap = 1 if (upper or initial or _starts_clause(text, start)) else 2
        elif word[0].isupper():
            cap, mixed = 1, True
        token = Token(start, end + (1 if initial else 0), word, cap, upper, mixed,
                      initial, Lex() if initial else lookup(word.lower()))
        if cap == 0 and any(a <= start < b for a, b in plain) and not _code_part(text, start, end):
            token.cap, token.caseless = 1, True            # «саш, привет»: как слово в начале предложения
        out.append(token)
    return out


def _caseless_lines(text: str) -> list[tuple[int, int]]:
    """Строки, написанные без единой заглавной буквы (так пишут в чатах): [начало, конец)."""
    out, pos = [], 0
    for line in text.split("\n"):
        if len(line) >= 3 and not any(ch.isupper() for ch in line) and sum(ch.isalpha() for ch in line) >= 3:
            out.append((pos, pos + len(line)))
        elif ":" in line:                                    # реплика: автор с заглавной, сам текст — без
            at = _CHAT_PREFIX.match(line).end()
            body = line[at:]
            first = next((ch for ch in body if ch.isalpha()), "")
            if at and first.islower() and not _CAPITALIZED.search(body) and sum(ch.isalpha() for ch in body) >= 3:
                out.append((pos + at, pos + len(line)))
        pos += len(line) + 1
    return out


def _code_part(text: str, start: int, end: int) -> bool:
    """Слово сцеплено с цифрой или подчёркиванием — это марка, версия или идентификатор, а не имя."""
    after, before = text[end:end + 2], text[max(0, start - 2):start]
    return bool(re.match(r"[-_]?\d|_", after) or re.search(r"(?:\d[-_]?|_)\Z", before))   # \Z: «$» сработал бы и перед «\n»


def _starts_clause(text: str, start: int) -> bool:
    """Заглавная здесь объясняется положением: начало строки, предложения, реплики, пункта списка, значения после
    двоеточия. После сокращения с точкой («г. Казань», «тов. Иванов», «И. О. Петров») — нет."""
    i = start - 1
    while i >= 0 and text[i] in " \t\u00a0":
        i -= 1
    if i > 0 and text[i] in "«\"“„'(" and (text[i - 1].isalnum() or text[i - 1] in " ,"):
        i -= 1                                             # «записали на «Хакимзянову»»: кавычка фразу не начинает
        while i >= 0 and text[i] in " \t\u00a0":
            i -= 1
    if i < 0 or text[i] in "\n\r":
        return True
    ch = text[i]
    if ch in _SENTENCE_END:
        j = i - 1
        while j >= 0 and (text[j].isalpha() or text[j] == "-"):
            j -= 1
        word = text[j + 1:i]
        if ch == "." and word and (len(word) == 1 or word.lower() in _ABBREVIATIONS):
            return False                                   # инициал или сокращение
        return True
    if ch.isdigit():
        return False
    return ch in _CLAUSE_START or ch in ")]»”"


def needs_model(text: str) -> bool:
    """Есть ли в тексте хоть одно слово, которое могло бы стать ФИО при каком-либо ответе модели.
    Если нет — модель по этому тексту не запускается (решает `detector` вместе с цифрами и адресами)."""
    return any(_could_be_name(t) for t in tokens(text))


def _could_be_name(t: Token) -> bool:
    if t.initial or len(t.text) < 2:
        return False
    if t.cap == 0:
        return (t.lex.first and not t.lex.ambiguous_first) or bool(t.lex.patrs) or _lower_surname(t)
    if t.abbreviation and not t.lex.first:
        return False
    if t.cap == 2:
        return True
    return t.given or t.surname_like or not t.lex.known or t.lex.surname


def find(text: str, tags: Sequence[Tag], vocabulary: Vocabulary | None = None) -> list[tuple[int, int, float]]:
    """ФИО в тексте: (начало, конец, уверенность). `tags` — слова с метками модели (может быть пусто)."""
    toks = tokens(text)
    if not toks:
        return []
    _apply_model(toks, tags)
    vocabulary = vocabulary or Vocabulary()
    for prev, t in zip(toks, toks[1:]):
        gap = text[prev.end:t.start]
        if gap in (" ", "\u00a0"):
            if t.initial and not prev.initial:
                prev.by_initial = True
            elif prev.initial and not t.initial:
                t.by_initial = True
        if (prev.low in _NAMED_AFTER or (prev.cap != 2 and _EPONYM.fullmatch(prev.low))) and gap in (" ", "\u00a0", ". "):
            t.named_after = True
            t.eponym = prev.low not in _NAMED_AFTER
        elif prev.named_after and t.cap >= 1 and gap in (" — ", " – ", " - ", "-", "–"):
            t.named_after, t.eponym = True, prev.eponym       # «симптом Щёткина — Блюмберга»
        if t.cap == 2 and gap == " " and prev.cap == 0 and _PET.fullmatch(prev.low):
            t.title = True                                    # «кот Василий»
        if _code_part(text, t.start, t.end) and t.lex.first:
            t.title = True                                    # «Диана-35» — препарат, а не Диана
        if prev.low == "лада" and gap == " " and t.low[:4] in ("вест", "гран", "кали", "прио", "ларг", "нива", "ниву", "нивы", "искр"):
            prev.title = t.title = True                       # автомобиль, а не Лада по фамилии Веста
        if prev.lex.homonym and gap in (" ", "\u00a0") and t.cap == 0 and t.low in _AFTER_NOUN:
            prev.noun_use = True
    for t in toks:                                            # «Пол: ж», «Вера / Faith»: имя-омоним как метка поля
        if t.lex.ambiguous_first and t.cap == 1 and re.match(r"[ \t]*[:/]", text[t.end:t.end + 3]):
            t.noun_use = True
    for i, t in enumerate(toks):
        if i >= 2 and t.cap == 2 and toks[i - 1].low == "и" and toks[i - 2].named_after \
                and t.start - toks[i - 2].end == 3:
            t.named_after = True                              # «симптомы Мейо-Робсона и Щёткина»
            if i + 1 < len(toks) and toks[i + 1].cap >= 1 and text[t.end:toks[i + 1].start] in (" — ", " – ", " - ", "-", "–"):
                toks[i + 1].named_after = True
    for i, t in enumerate(toks):                              # «анализ мочи по Нечипоренко»
        if i >= 2 and t.cap == 2 and toks[i - 1].low == "по" and text[toks[i - 1].end:t.start] == " " \
                and any(_BY_AUTHOR.fullmatch(x.low) for x in toks[max(0, i - 5):i - 1] if t.start - x.end <= 40):
            t.named_after = t.eponym = True
        if t.cap == 2 and t.low[:4] in ("алис", "марус") and t.lex.first \
                and _ASSISTANT.search(text[max(0, t.start - 50):t.end + 30]):
            t.title = True                                    # голосовой помощник
    for i, t in enumerate(toks):                              # «НМИЦ им. ак. Е. Н. Мешалкина»
        if t.low in ("им", "имени"):
            for n in toks[i + 1:i + 5]:
                if n.initial or n.low in _HONORIFIC:
                    continue
                if n.cap >= 1:
                    n.named_after = n.honor = True
                break
    _titles(text, toks)
    for t in toks:
        t.accepted = _own(t, vocabulary)
    _pairs(text, toks)
    for _ in range(3):
        if not _attach(text, toks, vocabulary):
            break
    _initial_pairs(text, toks)
    return [(a, b, score) for a, b, score in _groups(text, toks)]


def _apply_model(toks: list[Token], tags: Sequence[Tag]) -> None:
    k = 0
    for t in toks:
        while k < len(tags) and tags[k].end <= t.start:
            k += 1
        j = k
        while j < len(tags) and tags[j].start < t.end:
            tag = tags[j]
            if tag.label in PERSON_LABELS:
                t.person = max(t.person, tag.score)
            elif tag.label in PLACE_LABELS:
                t.place = max(t.place, tag.score)
            j += 1


def _own(t: Token, vocabulary: Vocabulary) -> bool:
    """Слово — часть ФИО по собственным свидетельствам, без соседей."""
    lex = t.lex
    sure, hint = t.person >= 0.5, t.person >= 0.25
    place = t.place >= 0.5 and t.place > t.person
    if t.initial or len(t.text) < 2 or t.title:
        return False
    if t.cap == 0:                                          # «спасибо оксане»: строчное имя — только с моделью;
        if lex.first and lex.ambiguous_first:               # «по всему свету» — нет, «спасибо ире» — при её уверенности
            return t.person >= 0.9 and not lex.homonym
        if lex.first or lex.patrs:
            return sure
        return t.person >= 0.9 and _lower_surname(t)        # «опять звонил нурлыгаянов»: форма фамилии и уверенная модель
    if t.abbreviation:                                      # «ОТК», «ЦФО», «ГЕРОИ»
        return False
    if t.upper and len(t.text) <= 4:                        # «ИРА», «MAX»: короткое имя заглавными — с моделью
        return sure and not place                           # (или рядом с фамилией — `_pairs`)
    if t.mixed:                                             # «ВкусВилл», «ИИ-ассистентов»
        return sure and not place and not lex.known
    if lex.first and t.eponym:                              # «синдром Арнольда — Киари»
        return False
    if lex.first:
        if t.cap == 2:                                      # «выделить Свету»
            return not place or sure
        if lex.ambiguous_first:                             # «Вера сказала» — с моделью; «Вера в победу» — нет и с ней
            if t.caseless and not t.noun_use and not place and vocabulary.names_any(lex):
                return True                                 # «вика ушла уже» в переписке, где есть «от Вики»
            return sure and not place and not t.noun_use
        return not place                                    # «Петя молодец», «Оленька, не забудь»
    if lex.patrs:
        return True
    if t.named_after and (not t.by_initial or t.honor):     # «болезнь Паркинсона», «по Нечипоренко», «имени Баумана»
        return False
    if t.caseless:                                          # в строке без заглавных — как строчное слово: фамилия
        return t.person >= 0.9 and _lower_surname(t)        # по словарю или от имени и уверенная модель
    if _role_word(t.low):                                   # «Работник», «Заказчика», «Стороны» — термины договора
        return False
    if t.low in vocabulary and (t.cap == 1 or not sure):    # «Продажник созвонится», «Продажников не хватает»
        return False
    if (lex.shape in _STRONG_SHAPES or lex.surname) and sure and not place:
        return True                                         # «Соловьёв», «Королёв», «Нагорная»: форма фамилии и модель
    if t.surname_like:
        if t.cap == 2 and len(t.text) >= 5:                 # «команде Гасановой», «группа Мирак-Орлова»: фамилия по
            return not place and (hint or not t.latin)      # словарю или по форме, с заглавной в середине фразы;
                                                            # латиницей так же кончаются «Daikin», «Bitcoin» — с моделью
        return hint and not place                           # «Иванов сказал» в начале фразы, короткое «Грин» — с моделью
    if t.by_initial and hint and not place and t.low not in _NOT_NAMES and _open_class(t):
        return True                                         # «Волк М.», «Белый П.»: слово, инициал и голос модели
    if t.cap == 2:                                          # «с Морозом», «спасибо Шульцу», «бэкап делает Белая»:
        return t.person >= 0.4 and not place and not lex.geo   # заглавная в середине фразы и голос модели
    if place or len(t.text) < 3:                            # «Де»
        return False
    if not lex.known:                                       # «Рихтер сказал»
        return sure
    # обычное слово в начале предложения: «Гладкий доложил» — да (модель уверена, слово в единственном числе),
    # «Кладовщики — герои недели» — нет
    return t.person >= 0.9 and t.low not in _NOT_NAMES and _singular(t)


def _adjacent(text: str, a: Token, b: Token) -> bool:
    """Слова стоят вплотную: между ними только пробел."""
    gap = text[a.end:b.start]
    return gap in (" ", "\u00a0", "  ")


def _attach(text: str, toks: list[Token], vocabulary: Vocabulary) -> bool:
    """Соседи признанных слов: фамилия вплотную к имени, имя вплотную к фамилии, инициалы."""
    changed = False
    for i, t in enumerate(toks):
        if not t.accepted:
            continue
        for j, after in ((i - 1, False), (i + 1, True)):
            if not 0 <= j < len(toks):
                continue
            n = toks[j]
            if n.accepted or not (_adjacent(text, t, n) if after else _adjacent(text, n, t)):
                continue
            if n.initial:                                    # «Евстигнеевым П.», «Танюшу К.», «П. С. Иванов»
                if t.initial or t.cap >= 1:
                    n.accepted = changed = True
                continue
            if t.initial:                                    # слово рядом с инициалом — только в паре инициалов (ниже)
                continue
            if after and n.low in _PATRONYMIC_PARTICLES:     # «Вагиф кызы»
                n.accepted = changed = True
                continue
            if _joins(t, n, after, vocabulary):
                n.accepted = changed = True
    return changed


def _joins(anchor: Token, n: Token, after: bool, vocabulary: Vocabulary) -> bool:
    """Сосед `n` — часть того же ФИО, что и признанное слово `anchor`?"""
    if n.low in _NOT_NAMES or len(n.text) < 2 or n.title:    # «С Арсением»: предлог перед именем — не фамилия
        return False
    if n.abbreviation:                                       # «BELAYA ANNA»: короткое слово заглавными — с моделью
        return anchor.upper and n.person >= 0.5
    if anchor.cap == 0 or anchor.caseless or n.caseless:     # строчными: «иван мороз» — только с моделью
        return n.person >= 0.5 or (n.surname_like and n.person >= 0.25)
    if n.cap == 0:
        return False
    if n.place >= 0.5 and n.place > n.person:                # «Олег Сибирь» — не фамилия
        return False
    if not _open_class(n):                                   # «Оля Сегодня», «Дима Привет»
        return False
    if n.lex.geo and n.person < 0.5:                         # «Иван Москва» в строке без запятых
        return False
    if anchor.given:                                         # сосед имени — фамилия
        if n.cap == 2:                                       # «Константина Иволга», «Варвары Кобза», «Нагорной Наде»:
            return True                                      # заглавную в середине фразы объясняет только имя рядом
        # перед именем в начале предложения: «Лисий Дима» — да, «Спасибо Ире» — нет
        return n.person >= 0.25 or not n.lex.known or n.surname_like or n.lex.surname
    # сосед фамилии — имя, которого нет в словаре: «Иванов Ильсур»
    return n.person >= 0.25 or (n.cap == 2 and not n.lex.known and n.low not in vocabulary)


def _pairs(text: str, toks: list[Token]) -> None:
    """Имя и фамилия рядом, оба с заглавной без веса (ВСЕ ЗАГЛАВНЫЕ, начало строки): «IVANOV IVAN», «ИВАНОВ ИВАН».
    По одному им нужна модель, вдвоём хватает словаря."""
    for a, b in zip(toks, toks[1:]):
        if (a.accepted and b.accepted) or not _adjacent(text, a, b) or a.caseless or b.caseless:
            continue
        if a.cap == 0 or b.cap == 0 or a.mixed or b.mixed or a.initial or b.initial or a.title or b.title:
            continue
        for given, family in ((a, b), (b, a)):
            if not given.given or given.lex.homonym or family.low in _NOT_NAMES:
                continue
            if family.place >= 0.5 and family.lex.shape not in _STRONG_SHAPES:   # «GINIYATULLIN AYRAT» модель зовёт местом,
                continue                                                         # но форма фамилии рядом с именем весомее
            if not _agree(given, family):                    # «Дана Джабраилову» — «дана кому», а не имя с фамилией
                continue
            # фамилия по словарю или форме; у слов ЗАГЛАВНЫМИ — любое слово вне словаря: «ANNA MOROZ»
            if family.surname_like or family.lex.surname or (given.upper and family.upper and len(family.text) >= 4
                                                             and not family.lex.known and not family.abbreviation):
                a.accepted = b.accepted = True
                break


def _lower_surname(t: Token) -> bool:
    """Строчное слово, которое может оказаться фамилией: фамилия по словарю («петрова») или образована от имени
    («исмаилов» — от «Исмаил»). Одной формы мало: так же кончаются «продажников» и «кэшбэков»."""
    lex = t.lex
    if len(t.text) < 5 or lex.common >= 0.3 or lex.geo or t.latin or lex.first:
        return False
    return lex.surname or _from_name(t.low)


@lru_cache(maxsize=20_000)
def _from_name(low: str) -> bool:
    m = re.match(r"^(.{3,}?)(?:ов|ев|ёв|ин|ын)(?:а|у|ым|е|ой|ых|ыми|ы)?$", low)
    if not m:
        return False
    return any((lex := lookup(base)).first and not lex.ambiguous_first
               for base in (m.group(1), m.group(1) + "й", m.group(1) + "ь", m.group(1) + "а", m.group(1) + "я"))


def _titles(text: str, toks: list[Token]) -> None:
    """Название в кавычках — не человек: диван «Мартин», тариф «Макс», БЦ «Аврора Плаза». Человек в кавычках стоит
    в косвенном падеже или после предлога («записали на «Хакимзянову»»), название — в именительном."""
    if not any(q in text for q in "«\"“„"):
        return
    starts = [t.start for t in toks]
    for m in _QUOTED.finditer(text):
        i, j = bisect_left(starts, m.start(1)), bisect_left(starts, m.end(1))
        inner = toks[i:j]
        if not 1 <= len(inner) <= 3 or inner[0].cap == 0 or any(t.initial for t in inner):
            continue
        if sum(1 for t in inner if t.given) >= 2 or (len(inner) >= 2 and any(t.lex.patrs for t in inner)):
            continue                                         # «Иванова Анна Петровна» в кавычках — всё же человек
        prev = toks[i - 1] if i and text[toks[i - 1].end:m.start()] in (" ", "\u00a0") else None
        if prev is not None and prev.cap == 0 and any(p.tag.POS == "PREP" for p in morph().parse(prev.low)[:2]):
            continue
        if prev is not None and _PERSON_CUE.fullmatch(prev.low):
            continue                                         # «на бейдже «Кристина»», «в строке «Ким Ен Сук»»
        if len(inner) >= 2 and any(t.given for t in inner) and not (prev is not None and not prev.latin and (
                prev.upper or any(p.is_known and p.tag.POS == "NOUN" for p in morph().parse(prev.low)[:3]))):
            continue                                         # «Заяц Дмитрий» <почта> — человек; пирожное «Анна Павлова» — название
        if not all(_nominative(t) for t in inner):
            continue
        for t in inner:
            t.title = True


@lru_cache(maxsize=20_000)
def _nominative_word(low: str) -> bool:
    lex = lookup(low)
    readings = list(lex.firsts) or mention.surname_readings(low)
    return not readings or any(r.case in (None, "nomn") for r in readings)


def _nominative(t: Token) -> bool:
    return _nominative_word(t.low)


@lru_cache(maxsize=50_000)
def _role_word(low: str) -> bool:
    if low in _NOT_NAMES:
        return True
    return any(p.is_known and p.normal_form in _NOT_NAMES and not any(tag in p.tag for tag in ("Name", "Surn", "Patr"))
               for p in morph().parse(low))


def _agree(given: Token, family: Token) -> bool:
    """Имя и фамилия стоят в одном падеже и роде (или хотя бы одно из них этого не показывает)."""
    if not given.lex.firsts and not given.lex.patrs:
        return True
    first = {(r.gender, r.case) for r in (given.lex.firsts or given.lex.patrs)}
    last = {(r.gender, r.case) for r in mention.surname_readings(family.low)}
    return any((g1 is None or g2 is None or g1 == g2) and (c1 is None or c2 is None or c1 == c2)
               for g1, c1 in first for g2, c2 in last)


def _open_class(t: Token) -> bool:
    """Слово может быть фамилией по части речи: существительное, прилагательное или вне словаря."""
    if not t.lex.known or t.given or t.lex.surname or t.lex.shape:
        return True
    return any(p.is_known and p.tag.POS in _OPEN_POS for p in morph().parse(t.low))


def _singular(t: Token) -> bool:
    return any(p.is_known and p.tag.POS in ("NOUN", "ADJF") and p.tag.number == "sing" and p.tag.case == "nomn"
               for p in morph().parse(t.low))


def _initial_pairs(text: str, toks: list[Token]) -> None:
    """«Вьюга Г. Е.», «Г. Е. Зима»: слово с заглавной и два инициала подряд — человек, даже если слово обычное."""
    tight = (" ", "", "\u00a0")
    for i in range(len(toks) - 2):
        a, b, c = toks[i], toks[i + 1], toks[i + 2]
        if text[a.end:b.start] not in tight or text[b.end:c.start] not in tight:
            continue
        if b.initial and c.initial and not a.initial:
            word = a
        elif a.initial and b.initial and not c.initial:
            word = c
        else:
            continue
        if word.cap == 0 or word.abbreviation or len(word.text) < 2 or word.low in _NOT_NAMES or not _open_class(word):
            continue
        if word.honor:                                       # «НМИЦ им. ак. Е. Н. Мешалкина»
            continue
        a.accepted = b.accepted = c.accepted = True


def _groups(text: str, toks: list[Token]) -> Iterable[tuple[int, int, float]]:
    """Признанные слова подряд → упоминания. Два человека без запятой («Иванов Иван Петров Пётр») делятся по ролям."""
    run: list[Token] = []
    for t in toks + [None]:  # type: ignore[list-item]
        if t is not None and t.accepted and (not run or text[run[-1].end:t.start] in (" ", "", "\u00a0", "  ")):
            run.append(t)
            continue
        if run:
            yield from _split_run(run)
        run = [t] if (t is not None and t.accepted) else []


def _split_run(run: list[Token]) -> Iterable[tuple[int, int, float]]:
    if all(t.initial for t in run):                          # одни инициалы — не человек
        return
    words = [t for t in run if not t.initial]
    if len(words) <= 3:
        yield _span(run)
        return
    used: set[str] = set()
    part: list[Token] = []
    for t in run:
        role = "initial" if t.initial else ("patr" if t.lex.patrs else "first" if (t.lex.first and not t.surname_like) else "surname")
        if role != "initial" and role in used and part:
            yield _span(part)
            part, used = [], set()
        part.append(t)
        used.add(role)
    if part and not all(t.initial for t in part):
        yield _span(part)


def _span(part: list[Token]) -> tuple[int, int, float]:
    scores = [t.person for t in part if not t.initial]
    return part[0].start, part[-1].end, max(max(scores, default=0.0), 0.6)

"""Что слово значит само по себе — без контекста и без модели.

Модель видит в незнакомом слове имя: «продажников», «кэшбэков», «ОТК», опечатку. Словарь отвечает на другой вопрос —
может ли это слово вообще быть именем, и не бывает ли оно обычным словом:
- имя (словарь OpenCorpora в pymorphy3: 12,8 тыс. имён со всеми падежами, уменьшительные; ласкательные выводятся:
  «Оленька» → «Оля»);
- отчество;
- фамилия по форме (-ов/-ин/-ский/-енко/-ян/-ич/-ых) или по словарю;
- обычное слово («сорока», «молодец») и топоним («Сибирь»).
Решение принимает `finder` — по словарю, регистру, соседям и мнению модели вместе.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from functools import lru_cache

CASES = ("nomn", "gent", "datv", "accs", "ablt", "loct")


@dataclass(frozen=True, slots=True)
class Reading:
    """Одно прочтение слова как части имени."""
    lemma: str                 # начальная форма, нижний регистр
    gender: str | None         # masc | femn | None — неизвестен или любой
    case: str | None           # падеж; None — любой (несклоняемое)
    weight: float = 1.0


@dataclass(frozen=True, slots=True)
class Lex:
    firsts: tuple[Reading, ...] = ()     # прочтения как имени
    patrs: tuple[Reading, ...] = ()      # как отчества
    surname: bool = False                # фамилия по словарю
    shape: str | None = None             # фамилия по форме: ov | sky | enko | ich | yan | ih | uk | geo
    common: float = 0.0                  # доля прочтений «обычное слово»
    geo: bool = False                    # топоним по словарю
    known: bool = False                  # слово есть в словаре хоть в каком-то значении

    @property
    def first(self) -> bool:
        return bool(self.firsts)

    homonym: bool = False                # имя, которое само по себе — обычное слово: Вера, Надежда, Роман, Лев

    @property
    def ambiguous_first(self) -> bool:
        """Имя, которое в начале предложения или строчными может оказаться обычным словом: Вера, Роман, Свету."""
        return self.first and (self.common >= 0.3 or self.homonym)


@lru_cache(maxsize=1)
def morph():
    import pymorphy3  # тяжёлый импорт — лениво

    return pymorphy3.MorphAnalyzer()


# Имена, которых нет в словаре или которые он знает только как слово. Форма → склонение по образцу.
_EXTRA_FIRST = {
    "марго": "femn", "ильназ": "masc", "лиана": "femn", "димон": "masc", "вован": "masc", "колян": "masc",
    "толян": "masc", "санёк": "masc", "санек": "masc", "лёха": "masc", "леха": "masc", "серёга": "masc",
    "серега": "masc", "андрюха": "masc", "ильсур": "masc", "ильгиз": "masc", "айнур": "masc", "ильшат": "masc",
    "рамис": "masc", "раиль": "masc", "ильсия": "femn", "алия": "femn", "алсу": "femn", "айсылу": "femn",
    "диляра": "femn", "гульшат": "femn", "зарина": "femn", "элина": "femn", "аделина": "femn", "николь": "femn",
    "мишель": "femn", "даниэль": "masc", "натали": "femn", "катрин": "femn", "ася": "femn",
}

# Частые имена. Словарь знает и редкие («Алин», «Марин», «Даниила», «Олесь»), и у них те же падежные формы, что у
# частых («Алину» — это «Алина» или «Алин»?). При равных прочтениях побеждает частое имя.
_FREQUENT = frozenset("""
александр алексей анатолий андрей антон аркадий арсений артём артур богдан борис вадим валентин валерий василий
виктор виталий владимир владислав всеволод вячеслав геннадий георгий герман глеб григорий даниил данил денис дмитрий
евгений егор иван игорь илья кирилл константин лев леонид макар максим марк матвей михаил никита николай олег павел
пётр роман руслан савелий семён сергей станислав степан тимофей тимур фёдор филипп эдуард юрий яков ярослав
александра алина алиса алла алёна анастасия ангелина анжела анна антонина валентина валерия варвара вера вероника
виктория галина дарья диана ева евгения екатерина елена елизавета жанна зинаида зоя инна ирина карина кира кристина
ксения лариса лидия лилия любовь людмила маргарита марина мария милана надежда наталия наталья нина оксана олеся
ольга полина раиса регина светлана софия софья таисия тамара татьяна ульяна юлия яна
азат айдар айрат альберт амир булат дамир ильдар ильнар ильнур ильшат марат наиль радик рамиль ренат ринат рустам
рустем тагир фарид шамиль эмиль айгуль алия альбина гузель гульнара гульшат диляра камилла лейсан ляйсан лилиана
эльвира эльмира тигран армен ашот давид гарик карен арам заур мурат аслан ислам магомед рамазан
саша лёша дима миша коля вова паша петя ваня костя женя стас влад макс серёжа юра толя витя гена лёня рома
аня настя вика галя даша катя лена лиза ира ксюша люба люда рита маша надя наташа оля поля света соня таня юля
""".split())

# Имена, которые в начале предложения чаще оказываются словом. Словарь оценивает их как имена («Надежда» — имя
# с весом 0,9), поэтому список явный: «Надежда только на вас», «Роман с агентством заканчиваем».
_HOMONYMS = frozenset("""
авиа вера надежда любовь роман лев роза слава мила майя рада лада злата гера тема тёма тома рая поля света лена юра марк
макс герман виктория вика ника лилия лиля марта августа ада алла ян яна кира нина неля эра идея гений алмаз мир
май август богдан владимир георгий виктор назар тихон прохор любава снежана аврора венера юнона диана пол дана
""".split()) - frozenset("владимир георгий виктор богдан назар тихон прохор диана".split())

_LATIN_SHAPES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("ov", re.compile(r"^.{2,}(?:ov|ev|in|yn)a?$")),
    ("sky", re.compile(r"^.{2,}(?:sk|tsk|ck)(?:y|iy|ii|i|aya|aia|oy)$|^.{3,}(?:aya|aia)$")),
    ("enko", re.compile(r"^.{2,}(?:enko|eiko|eyko)$")),
    ("ich", re.compile(r"^.{3,}(?:ovich|evich)$")),
    ("yan", re.compile(r"^.{3,}(?:yan|ian|iants|yants)$")),
    ("uk", re.compile(r"^.{3,}(?:chuk|yuk|iuk)$")),
    ("geo", re.compile(r"^.{3,}(?:shvili|dze)$")),
)

# Ласкательные суффиксы: «Оленька», «Ирочка», «Танюша», «Димочка», «Толик».
_AFFECTIONATE = re.compile(r"^(.{2,}?)(еньк|оньк|очк|ечк|юшк|ушк|юш|уш|ульк|уль|усь|ус|ик|чик|к)(а|я|и|ы|е|у|ю|ой|ей|ою)?$")
_ENDING_CASES = {"а": ("nomn",), "я": ("nomn",), "": ("nomn",), "и": ("gent",), "ы": ("gent",), "е": ("datv", "loct"),
                 "у": ("accs",), "ю": ("accs",), "ой": ("ablt",), "ей": ("ablt",), "ою": ("ablt",)}

_PATR_SHAPE = re.compile(r"^.{3,}(?:ович|евич|ьич)(?:а|у|ем|е)?$|^.{3,}(?:овн|евн|ичн|иничн)(?:а|ы|е|у|ой)$")
_SHAPES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("ov", re.compile(r"^.{2,}(?:ов|ев|ёв|ин|ын)(?:а|у|ым|е|ой|ых|ыми|ы)?$")),
    ("sky", re.compile(r"^.{2,}(?:ск|цк)(?:ий|ая|ого|ому|им|ом|ой|ую|ие|их|ими)$")),
    ("enko", re.compile(r"^.{2,}(?:енко|ейко)$")),
    ("ich", re.compile(r"^.{3,}(?:ович|евич)(?:а|у|ем|е)?$")),
    ("yan", re.compile(r"^.{3,}(?:ян|янц|ьянц)(?:а|у|ом|е)?$")),
    ("ih", re.compile(r"^.{3,}(?:ых|их)$")),
    ("uk", re.compile(r"^.{3,}(?:чук|юк)(?:а|у|ом|е)?$")),
    ("geo", re.compile(r"^.{3,}(?:швили|дзе|оглы|заде)$")),
)
_NAME_TAGS = ("Name", "Surn", "Patr")


def _extra_forms() -> dict[str, tuple[Reading, ...]]:
    out: dict[str, list[Reading]] = {}
    for lemma, gender in _EXTRA_FIRST.items():
        forms: dict[str, tuple[str, ...]]
        if lemma.endswith(("а", "я")):
            stem, soft = lemma[:-1], lemma.endswith("я") or lemma[-2] in "гкхжшчщ"
            forms = {lemma: ("nomn",), stem + ("и" if soft else "ы"): ("gent",), stem + "е": ("datv", "loct"),
                     stem + ("ю" if lemma.endswith("я") else "у"): ("accs",),
                     stem + ("ей" if lemma.endswith("я") else "ой"): ("ablt",)}
        elif gender == "masc" and lemma[-1] not in "аеёиоуыэюя":
            stem = lemma[:-1] if lemma[-1] in "ьй" else lemma
            soft = lemma[-1] in "ьй"
            forms = {lemma: ("nomn",), stem + ("я" if soft else "а"): ("gent", "accs"), stem + ("ю" if soft else "у"): ("datv",),
                     stem + ("ем" if soft else "ом"): ("ablt",), stem + "е": ("loct",)}
        else:                                       # несклоняемое: Нелли, Алсу, Николь
            forms = {lemma: (None,)}  # type: ignore[dict-item]
        for form, cases in forms.items():
            for case in cases:
                out.setdefault(form, []).append(Reading(lemma, gender, case, 1.0))
    return {k: tuple(v) for k, v in out.items()}


_EXTRA_FORMS = _extra_forms()


@lru_cache(maxsize=100_000)
def lookup(word: str) -> Lex:
    """Словарные сведения о слове (в нижнем регистре)."""
    low = word.lower()
    if len(low) < 2 or not low.replace("-", "").replace("'", "").replace("’", "").isalpha():
        return Lex()
    if low.isascii():
        return _latin(low)
    if "-" in low:
        return _compound(low)
    firsts: list[Reading] = list(_EXTRA_FORMS.get(low, ()))
    patrs: list[Reading] = []
    surname = known = False
    common = geo = total = 0.0
    if re.search(r"[а-яё]", low):
        for p in morph().parse(low):
            if not p.is_known:
                continue
            known = True
            total += p.score
            tag = p.tag
            gender = tag.gender if tag.gender in ("masc", "femn") else None
            case = _case(tag)
            if "Name" in tag:
                if tag.number != "plur":             # «Светы» — это «у Светы», а не несколько Свет
                    weight = p.score + (1.0 if p.normal_form in _FREQUENT else 0.0)
                    firsts.append(Reading(p.normal_form, gender, None if "Fixd" in tag else case, weight))
            elif "Patr" in tag:
                if tag.number != "plur":
                    form = p.inflect({"nomn", "sing"})     # «Ильдаровна», а не словарное «ильдарович»
                    patrs.append(Reading(form.word if form else p.normal_form, gender, case, p.score))
            elif "Surn" in tag:
                surname = True
            elif "Geox" in tag:
                geo += p.score
            elif "Abbr" not in tag and "Init" not in tag and "Poss" not in tag:   # Poss — «фомин», «ильин»: от имён
                common += p.score
        if not firsts and len(low) >= 3:                 # звательная форма уменьшительного: «Паш», «Тань», «Оль»
            base = low[:-1] + "я" if low.endswith("ь") else low + "а"
            if base in DIMINUTIVES:
                firsts = [Reading(base, None, "nomn", 1.0)]
        if not firsts:
            firsts = _affectionate(low, known)
        if not patrs and not known and _PATR_SHAPE.match(low):
            patrs = _unknown_patr(low)
    shape = None if patrs else next((name for name, rx in _SHAPES if rx.match(low)), None)
    share = lambda value: value / total if total else 0.0  # noqa: E731
    homonym = bool(firsts) and bool({r.lemma for r in firsts} & _HOMONYMS)
    return Lex(tuple(firsts), tuple(patrs), surname, shape, share(common), share(geo) >= 0.2, known, homonym)


_LATIN_LETTERS: dict[str, tuple[str, ...]] = {
    "а": ("a",), "б": ("b",), "в": ("v", "w"), "г": ("g",), "д": ("d",), "е": ("e", "ye"), "ё": ("e", "yo"), "ж": ("zh",),
    "з": ("z",), "и": ("i",), "й": ("y", "i", "j"), "к": ("k", "c"), "л": ("l",), "м": ("m",), "н": ("n",), "о": ("o",),
    "п": ("p",), "р": ("r",), "с": ("s",), "т": ("t",), "у": ("u",), "ф": ("f", "ph"), "х": ("kh", "h"), "ц": ("ts", "c"),
    "ч": ("ch",), "ш": ("sh",), "щ": ("shch", "sch"), "ъ": ("",), "ы": ("y",), "ь": ("",), "э": ("e",),
    "ю": ("yu", "iu", "ju"), "я": ("ya", "ia", "ja"),
}
# Латинские слова, совпадающие с именем в транслитерации, но обычно не имена.
_LATIN_HOMONYMS = frozenset("max mark lada nika mila roman dima lena vera alina dina mira ada eva".split()) - {"dima", "lena", "alina"}


@lru_cache(maxsize=1)
def _latin_names() -> dict[str, tuple[str, str | None]]:
    """Частые имена латиницей во всех обычных написаниях: «ivan», «sergey» / «sergei», «yulia» / «julia»,
    «dmitry» / «dmitriy», «alexander» / «aleksandr». Совпадение точное: «Jira» — не «Ира»."""
    out: dict[str, tuple[str, str | None]] = {}
    for name in sorted(_FREQUENT):
        gender = next((p.tag.gender for p in morph().parse(name)
                       if p.is_known and "Name" in p.tag and p.tag.gender in ("masc", "femn")), None)
        variants = {""}
        for ch in name:
            variants = {v + o for v in variants for o in _LATIN_LETTERS.get(ch, (ch,))}
            if len(variants) > 96:
                variants = set(sorted(variants)[:96])
        extra = set()
        for v in variants:
            if v.endswith(("iy", "ii", "ij")):
                extra |= {v[:-2] + "y", v[:-2] + "i"}             # Dmitriy / Dmitry / Dmitri
            if v.endswith("andr"):
                extra.add(v[:-4] + "ander")                       # Aleksandr / Alexander
        variants |= extra
        variants |= {v.replace("ks", "x") for v in variants}      # Maksim / Maxim
        for v in variants:
            if len(v) >= 3:
                out.setdefault(v, (name, gender))
    return out


def _latin(low: str) -> Lex:
    """Латиница: имя — по списку частых имён в транслитерации, фамилия — по окончанию («Ivanov», «Belaya»)."""
    if "'" in low or "’" in low:
        return Lex()
    if "-" in low:                                       # «KIM-ZAKHAROVA»: фамилия, если на неё похожа хотя бы одна часть
        parts = [_latin(part) for part in low.split("-") if len(part) >= 2]
        return Lex(shape=next((p.shape for p in parts if p.shape), None))
    hit = _latin_names().get(low)
    firsts = (Reading(hit[0], hit[1], None, 1.0),) if hit else ()
    shape = next((name for name, rx in _LATIN_SHAPES if rx.match(low)), None)
    return Lex(firsts=firsts, shape=None if firsts else shape, homonym=low in _LATIN_HOMONYMS)


def _compound(low: str) -> Lex:
    """Слово через дефис: «Санкт-Петербург» словарь знает целиком, «Мирак-Орлова» — фамилия, если на неё похожа
    хотя бы одна часть, а остальные — не обычные слова."""
    parts = [lookup(part) for part in low.split("-") if part]
    whole = [p for p in morph().parse(low) if p.is_known]
    if whole or not parts:
        total = sum(p.score for p in whole) or 1.0
        geo = sum(p.score for p in whole if "Geox" in p.tag) / total
        names = sum(p.score for p in whole if any(t in p.tag for t in _NAME_TAGS)) / total
        return Lex(surname=any("Surn" in p.tag for p in whole), common=max(0.0, 1.0 - geo - names), geo=geo >= 0.2, known=bool(whole))
    if all(p.first for p in parts):                      # «Анна-Мария»
        return Lex(firsts=parts[0].firsts)
    common = max(p.common for p in parts)
    shape = next((p.shape for p in parts if p.shape and p.common < 0.3), None)
    return Lex(surname=common < 0.3 and any(p.surname for p in parts), shape=shape, common=common,
               geo=any(p.geo for p in parts), known=False)


def _case(tag) -> str | None:
    case = tag.case
    if case in ("gen2",):
        return "gent"
    if case in ("loc2",):
        return "loct"
    if case in ("acc2",):
        return "accs"
    return case if case in CASES else None


def _affectionate(low: str, known: bool = False) -> list[Reading]:
    m = _AFFECTIONATE.match(low)
    if not m:
        return []
    stem, suffix, ending = m.group(1), m.group(2), m.group(3) or ""
    if suffix in ("к", "ус") and (known or not ending or len(stem) < (4 if suffix == "к" else 3)):
        return []                                        # «Кристинка», «Викуся» — только слова вне словаря; не «полка», не «фокусе»
    if suffix in ("ик", "чик") and ending not in ("", "а", "у", "ом", "е"):
        return []
    plain = suffix in ("к", "ус")                        # «Кристинка», «Викуся» — только от женских имён на -а/-я
    if plain and suffix == "ус" and ending not in ("я", "и", "е", "ю", "ей"):
        return []
    for base in (stem + "а", stem + "я") + (() if plain else (stem,)):
        for p in morph().parse(base):
            if plain and p.tag.gender != "femn":
                continue
            if p.is_known and "Name" in p.tag and p.tag.case == "nomn" and p.tag.number == "sing":
                gender = p.tag.gender if p.tag.gender in ("masc", "femn") else None
                lemma = stem + suffix + ("" if suffix in ("ик", "чик") else "а")
                if suffix in ("ик", "чик"):
                    cases = {"": ("nomn",), "а": ("gent", "accs"), "у": ("datv",), "ом": ("ablt",), "е": ("loct",)}[ending]
                else:
                    cases = _ENDING_CASES[ending]
                return [Reading(lemma, gender, case, 0.6) for case in cases]
    return []


def _unknown_patr(low: str) -> list[Reading]:
    """Отчество вне словаря — только от известного имени: «Ильназович» — отчество, «Юшкевич» — фамилия."""
    m = re.match(r"^(.+?)(?:(ович|евич)(а|у|ем|е)?|(овн|евн)(а|ы|е|у|ой))$", low)
    if not m:
        return []
    stem = m.group(1)
    if not any(lookup(base).first for base in (stem, stem + "й", stem + "ь")):
        return []
    if m.group(2):
        cases = {None: ("nomn",), "а": ("gent", "accs"), "у": ("datv",), "ем": ("ablt",), "е": ("loct",)}[m.group(3)]
        return [Reading(stem + m.group(2), "masc", case, 0.5) for case in cases]
    cases = {"а": ("nomn",), "ы": ("gent",), "е": ("datv", "loct"), "у": ("accs",), "ой": ("ablt",)}[m.group(5)]
    return [Reading(stem + m.group(4) + "а", "femn", case, 0.5) for case in cases]


def patr_key(lemma: str) -> str:
    """Один ключ на «Ильдарович» и «Ильдаровна»."""
    low = lemma.lower().replace("ё", "е")
    for femn, masc in (("овна", "ович"), ("евна", "евич"), ("инична", "ич"), ("ична", "ич")):
        if low.endswith(femn):
            return low[:-len(femn)] + masc
    return low


# Уменьшительное → полные имена. Нужно только для склейки упоминаний: «Оля Орлова» и «Ольга Орлова» — один человек.
DIMINUTIVES: dict[str, tuple[str, ...]] = {
    "саша": ("александр", "александра"), "саня": ("александр", "александра"), "шура": ("александр", "александра"),
    "лёша": ("алексей",), "леша": ("алексей",), "лёха": ("алексей",), "леха": ("алексей",), "алёша": ("алексей",),
    "толя": ("анатолий",), "андрюша": ("андрей",), "андрюха": ("андрей",), "антоша": ("антон",), "тоша": ("антон",),
    "тёма": ("артём",), "тема": ("артём",), "боря": ("борис",), "вадик": ("вадим",), "валера": ("валерий",),
    "вася": ("василий",), "витя": ("виктор",), "виталик": ("виталий",), "вова": ("владимир",), "володя": ("владимир",),
    "влад": ("владислав", "владимир"), "слава": ("вячеслав", "владислав", "станислав", "ярослав"),
    "гена": ("геннадий",), "гоша": ("георгий", "игорь"), "жора": ("георгий",), "гриша": ("григорий",),
    "даня": ("даниил", "данил", "данила"), "дима": ("дмитрий",), "митя": ("дмитрий",), "димон": ("дмитрий",),
    "женя": ("евгений", "евгения"), "ваня": ("иван",), "игорёк": ("игорь",), "илюша": ("илья",), "костя": ("константин",),
    "лёня": ("леонид",), "леня": ("леонид",), "лёва": ("лев",), "макс": ("максим",), "миша": ("михаил",),
    "коля": ("николай",), "олежка": ("олег",), "паша": ("павел",), "петя": ("пётр",), "рома": ("роман",),
    "серёжа": ("сергей",), "сережа": ("сергей",), "серёга": ("сергей",), "серега": ("сергей",), "стас": ("станислав",),
    "стёпа": ("степан",), "степа": ("степан",), "сёма": ("семён",), "сема": ("семён",), "тима": ("тимофей", "тимур"),
    "федя": ("фёдор",), "юра": ("юрий",), "яша": ("яков",), "эдик": ("эдуард",), "рустик": ("рустам", "рустем"),
    "аня": ("анна",), "анюта": ("анна",), "алёна": ("елена", "алёна"), "настя": ("анастасия",), "ася": ("анастасия", "ася"),
    "варя": ("варвара",), "вика": ("виктория",), "галя": ("галина",), "даша": ("дарья",), "катя": ("екатерина",),
    "лена": ("елена",), "лиза": ("елизавета",), "зина": ("зинаида",), "ира": ("ирина",), "ириша": ("ирина",),
    "ксюша": ("ксения", "оксана"), "ксеня": ("ксения",), "лара": ("лариса",), "лида": ("лидия",), "люба": ("любовь",),
    "люда": ("людмила",), "мила": ("людмила", "милана", "мила"), "рита": ("маргарита",), "марго": ("маргарита",),
    "маша": ("мария",), "маня": ("мария",), "надя": ("надежда",), "наташа": ("наталья", "наталия"),
    "ната": ("наталья", "наталия"), "оля": ("ольга",), "поля": ("полина",), "рая": ("раиса",), "света": ("светлана",),
    "соня": ("софья", "софия"), "тома": ("тамара",), "таня": ("татьяна",), "юля": ("юлия",), "лера": ("валерия",),
    "вера": ("вера",), "тоня": ("антонина",), "нина": ("нина",), "лёля": ("ольга", "елена"), "гуля": ("гульнара", "гульшат", "гульназ"),
    "наталия": ("наталья",), "наталья": ("наталия",), "софия": ("софья",), "софья": ("софия",), "данил": ("даниил",),
    "даниил": ("данил",), "алена": ("алёна",), "артем": ("артём",), "семен": ("семён",), "федор": ("фёдор",), "петр": ("пётр",),
}


def full_names(lemma: str) -> frozenset[str]:
    """Все имена, которыми может быть это: само имя и полные формы уменьшительного. Ласкательные — через основу."""
    low = lemma.lower().replace("ё", "е")
    out = {low}
    for key in (lemma.lower(), low):
        out.update(n.replace("ё", "е") for n in DIMINUTIVES.get(key, ()))
    m = _AFFECTIONATE.match(lemma.lower())
    if m and len(out) == 1:
        for base in (m.group(1) + "а", m.group(1) + "я", m.group(1)):
            if base in DIMINUTIVES or lookup(base).first:
                out.add(base.replace("ё", "е"))
                out.update(n.replace("ё", "е") for n in DIMINUTIVES.get(base, ()))
                break
    return frozenset(out)

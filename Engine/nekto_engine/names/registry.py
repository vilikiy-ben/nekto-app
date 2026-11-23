"""Кто есть кто: упоминания одного человека получают одну метку.

«Ахмерова Гульнара Ильдаровна», «Ахмеровой Г. И.», «Гульнара Ахмерова», «NURIEVA GUZEL» / «Нуриева Гузель» — один
человек. Но склейка — это утверждение о мире, и ошибка в ней портит данные сильнее пропуска: метка возвращается
в ответ нейросети начальной формой человека, и «курьер Марат» может вернуться чужой фамилией. Поэтому правила
осторожные:

- фамилия с именем или инициалами — по фамилии, если имя не противоречит;
- одна фамилия — к единственному человеку с такой фамилией; если их несколько — отдельная метка;
- одно имя — только к человеку, названному полностью в той же области (`scope`): в том же абзаце, документе
  сплошного текста или в той же строке таблицы. «Спасибо Ксении» в одной строке таблицы и «Ксения Зуева»
  в другой — разные записи, и связывать их нечем;
- имена без фамилии с одним написанием («Ксении», «Ксению») — одна метка «Ксения»: это одно значение, а не
  утверждение, что человек один.
"""
from __future__ import annotations

from typing import Iterable, Protocol

from .mention import Mention, Person


class HasPerson(Protocol):
    person: Person | None


def rank(person: Person) -> int:
    """Насколько упоминание полное: полные разбираются первыми, чтобы короткие нашли, к кому примкнуть."""
    given = bool(person.firsts or person.patrs or person.initials)
    if person.surnames or (person.latin and person.words > 1):
        return 3 if given or person.words > 1 else 2
    return 1 if person.patrs else 0


def choose(mention: Mention, people: Iterable[HasPerson], scope: Iterable[HasPerson]):
    """Запись, к которой относится упоминание, или None — это новый человек."""
    p = mention.person
    known = [e for e in people if e.person is not None]
    if not (p.surnames or p.firsts):                          # латиница, одни инициалы
        if p.latin:
            return _unique([e for e in known if _latin_match(p, e.person)])
        return None
    if p.surnames:
        same = [e for e in known if _same_surname(p, e.person) and compatible(p, e.person)]
        if not same and p.latin:
            same = [e for e in known if e.person.latin and not e.person.surnames and _latin_match(p, e.person)]
        if not same:
            return None
        if p.firsts or p.patrs or p.initials:
            return _strongest(p, same)
        if len(same) == 1:                                    # «Шубина» при единственном Шубине
            return same[0]
        return _unique([e for e in same if not (e.person.firsts or e.person.patrs or e.person.initials)])
    # только имя (и, возможно, отчество)
    if p.patrs:
        full = [e for e in known if e.person.firsts & p.firsts and e.person.patrs & p.patrs and compatible(p, e.person)]
        if len(full) == 1:
            return full[0]
    near = [e for e in scope if e.person is not None and (e.person.surnames or e.person.patrs)
            and e.person.firsts & p.firsts and compatible(p, e.person)]
    if len(near) == 1:                                        # «Петей Зуевым … Петя молодец»
        return near[0]
    return next((e for e in known if e.person.bare_first and e.person.first_lemmas & p.first_lemmas
                 and e.person.patrs == p.patrs), None)


def compatible(a: Person, b: Person) -> bool:
    """Ничто не мешает считать это одним человеком."""
    if a.gender and b.gender and a.gender != b.gender:
        return False
    if a.firsts and b.firsts:
        if not a.firsts & b.firsts:
            return False
    else:
        for named, short in ((a, b), (b, a)):
            if named.firsts and short.initials and not any(n.startswith(short.initials[0]) for n in named.firsts):
                return False
        if a.initials and b.initials and not (a.firsts or b.firsts) and a.initials[0] != b.initials[0]:
            return False
    if a.patrs and b.patrs and not a.patrs & b.patrs:
        return False
    for named, short in ((a, b), (b, a)):
        if named.patrs and len(short.initials) > 1 and not short.firsts \
                and not any(n.startswith(short.initials[1]) for n in named.patrs):
            return False
    return True


def _same_surname(a: Person, b: Person) -> bool:
    if a.surnames & b.surname_alts or a.surname_alts & b.surnames:
        return True
    return bool(_surname_latin(a) & _surname_latin(b)) and (_is_latin(a) != _is_latin(b))


def _is_latin(p: Person) -> bool:
    return bool(p.latin) and not (p.surnames or p.firsts)


def _surname_latin(p: Person) -> set[str]:
    from .mention import latin_key
    keys = set(p.latin) if _is_latin(p) else {latin_key(s) for s in p.surnames}
    return keys | {k[:-1] for k in keys if k.endswith("a") and len(k) > 4}     # NURIEVA ~ нуриев


def _latin_match(a: Person, b: Person) -> bool:
    """Латиница ↔ любая запись: все слова более короткого упоминания есть в более длинном (минимум одно)."""
    ka, kb = _all_latin(a), _all_latin(b)
    small, big = (ka, kb) if len(ka) <= len(kb) else (kb, ka)
    if not small:
        return False
    loose = big | {k[:-1] for k in big if k.endswith("a")} | {k + "a" for k in big}
    return all(k in loose or (k.endswith("a") and k[:-1] in loose) for k in small)


def _all_latin(p: Person) -> set[str]:
    from .mention import latin_key
    return set(p.latin) | {latin_key(s) for s in p.surnames} | {latin_key(f) for f in p.first_lemmas}


def _strength(a: Person, b: Person) -> int:
    return (bool(a.firsts & b.firsts) * 2 + bool(a.patrs & b.patrs) * 2
            + bool(a.initials and b.initials and a.initials[0] == b.initials[0])
            + bool((a.firsts and b.initials) or (b.firsts and a.initials)))


def _strongest(p: Person, candidates: list):
    if len(candidates) == 1:
        return candidates[0]
    ranked = sorted(candidates, key=lambda e: _strength(p, e.person), reverse=True)
    if _strength(p, ranked[0].person) > _strength(p, ranked[1].person):
        return ranked[0]
    return None        # неоднозначно («Иванов И.», когда Ивановых на «И» двое) — новый человек безопаснее склейки


def _unique(candidates: list):
    return candidates[0] if len(candidates) == 1 else None

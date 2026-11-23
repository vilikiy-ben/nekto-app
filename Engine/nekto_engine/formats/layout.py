"""Вид документа для редактора: блоки, а не одна строка.

Раньше движок отдавал приложению одну строку `preview`, и каждый формат сплющивал себя по-своему: CSV — как есть,
с точками с запятой, XLSX — Markdown-таблицей с `|`, ячейки DOCX — по строке на ячейку, слайды — «— Слайд 1 —».
Редактор показывал любую такую строку одинаково: абзацами пропорционального шрифта. Таблица превращалась в стену
текста, а колонтитулы, сноски, примечания и заметки докладчика (они обезличиваются и уходят вместе с файлом)
не попадали в строку вовсе — проверить их было нельзя.

Теперь у результата два представления с разными задачами:

- `layout` — что видит человек: блоки с формой документа (заголовки, списки, таблицы, слайды, листы, поля письма,
  код) и всё, что лежит в файле, включая служебные части (`aside`) и свойства файла (`meta`);
- `preview` — что уходит в буфер по «Скопировать»: текст для чата с нейросетью. У текстовых форматов это сам файл,
  у остальных — Markdown из тех же блоков (`to_markdown`), без свойств файла.

Блок — словарь с полем `type` (JSON как есть уходит в приложение, `App/Sources/Document/DocumentLayout.swift`):

    heading   {text, level 1–3}
    paragraph {text, style?: "quote" | "muted"}
    item      {text, marker: "•" | "1." | …, level}
    table     {rows: [[ячейка]], header: bool, title?, row_labels?: [str], more?: int}
              ячейка — строка или {text, span} для объединённых по горизонтали
    fields    {rows: [[подпись, значение]]}
    code      {text, lang?}
    section   {kind: "slide" | "sheet" | "page" | "aside" | "meta", title, blocks}
    note      {text}

Тексты блоков — уже обезличенные: метки `[ФИО_1]` стоят в них так же, как в файле.
"""
from __future__ import annotations

import re
import sys
from typing import Any, Callable, Iterable, Sequence

VERSION = 1
# Сколько показывать. Редактор раскладывает вид в фоне и рисует только видимое:
# 62 тыс. ячеек и 3,4 млн символов — разбор 0,13 с и сборка 0,34 с на M-серии, кадр прокрутки от размера не зависит.
# Потолок — с запасом под медленный Mac и память; остальное есть в файле и в буфере обмена, в редакторе — пометка.
# Символы таблиц входят в бюджет вместе с абзацами: лист с длинными отзывами тяжелее, чем говорит число ячеек.
MAX_CELLS = 100_000
MAX_TEXT = 2_000_000

Block = dict[str, Any]


# MARK: Конструкторы

def heading(text: str, level: int = 1) -> Block:
    return {"type": "heading", "text": text, "level": max(1, min(int(level), 3))}


def paragraph(text: str, style: str | None = None) -> Block:
    block: Block = {"type": "paragraph", "text": text}
    if style:
        block["style"] = style
    return block


def item(text: str, marker: str = "•", level: int = 0) -> Block:
    return {"type": "item", "text": text, "marker": marker, "level": max(0, min(int(level), 6))}


def table(rows: Sequence[Sequence[Any]], header: bool = False, title: str | None = None,
          row_labels: Sequence[str] | None = None) -> Block | None:
    rows = [list(r) for r in rows if any(cell_text(c).strip() for c in r)] if row_labels is None else [list(r) for r in rows]
    if not rows:
        return None
    block: Block = {"type": "table", "rows": rows, "header": bool(header and len(rows) > 1)}
    if title:
        block["title"] = title
    if row_labels is not None:
        block["row_labels"] = list(row_labels)
    return block


def fields(rows: Iterable[tuple[str, str]]) -> Block | None:
    rows = [[k, v] for k, v in rows if v is not None and str(v).strip()]
    return {"type": "fields", "rows": rows} if rows else None


def code(text: str, lang: str | None = None) -> Block:
    block: Block = {"type": "code", "text": text.rstrip("\n")}
    if lang:
        block["lang"] = lang
    return block


def section(kind: str, title: str, blocks: Iterable[Block | None], copy: bool = True) -> Block | None:
    """`copy=False` — часть видна в редакторе, но не идёт в «Скопировать» (колонтитулы, исправления, свойства файла):
    в чате с нейросетью она только шум."""
    inner = [b for b in blocks if b]
    if not inner and kind in ("aside", "meta"):
        return None
    block: Block = {"type": "section", "kind": kind, "title": title, "blocks": inner}
    if not copy or kind == "meta":
        block["copy"] = False
    return block


def note(text: str) -> Block:
    return {"type": "note", "text": text}


def looks_like_header(rows: Sequence[Sequence[Any]]) -> bool:
    """Первая строка таблицы в тексте документа — шапка? Строже, чем при поиске ПДн (tabular.looks_like_header):
    там ошибка стоит только контекста, а здесь неверная шапка выделит обычную строку. Шапка — короткие подписи
    без цифр во всех ячейках. Таблица «подпись — значение» в два столбца (реквизиты сторон в договоре) шапки не имеет:
    у неё подписи стоят в первом столбце каждой строки."""
    if len(rows) < 2:
        return False
    first = [cell_text(c).strip() for c in rows[0]]
    if not first or not all(first) or any(len(c) > 40 or re.search(r"\d", c) for c in first):
        return False
    if len(first) == 2:
        labels = [cell_text(r[0]).strip() for r in rows[1:] if r]
        if labels and all(l and len(l) <= 40 and not re.search(r"\d", l) for l in labels):
            return False
    return True


def safely(build: Callable[..., list[Block]], *args: Any) -> list[Block] | None:
    """Вид не должен ломать обезличивание: если разобрать форму не вышло, редактор покажет `preview` текстом.
    В журнал — только тип ошибки: текст документа туда не пишется никогда."""
    try:
        return build(*args)
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"layout: {type(e).__name__} в {getattr(build, '__module__', '?')}\n")
        return None


def cell_text(cell: Any) -> str:
    if isinstance(cell, dict):
        return str(cell.get("text", ""))
    return "" if cell is None else str(cell)


def compact(blocks: Iterable[Block | None]) -> list[Block]:
    return [b for b in blocks if b]


# MARK: Готовый вид

def finish(blocks: Iterable[Block | None]) -> dict[str, Any]:
    """Вид для приложения: пустые блоки убраны, большие документы обрезаны по бюджету с пометкой в конце."""
    budget = _Budget()
    fitted = budget.fit(compact(blocks))
    if budget.rest:
        fitted.append(note(_rest_note(budget.rest)))
    return {"version": VERSION, "blocks": fitted}


class _Budget:
    """Сколько ещё можно показать. Служебные части (колонтитулы, примечания, свойства) показываются всегда:
    они короткие, а проверить их важнее всего — в самом файле их не видно."""

    def __init__(self) -> None:
        self.cells = MAX_CELLS
        self.chars = MAX_TEXT
        self.cut = False
        self.rest = 0

    def fit(self, blocks: list[Block]) -> list[Block]:
        out: list[Block] = []
        for b in blocks:
            if self.cut and not (b["type"] == "section" and b["kind"] in ("aside", "meta")):
                self.rest += _count_rows([b])
                continue
            out.append(self._fit_block(b))
        return out

    def _fit_block(self, b: Block) -> Block:
        kind = b["type"]
        if kind == "section":
            if b["kind"] in ("aside", "meta"):
                return b
            return {**b, "blocks": self.fit(b["blocks"])}
        if kind == "table":
            rows = b["rows"]
            width = max((len(r) for r in rows), default=1) or 1
            keep = 0
            for row in rows:
                size = sum(len(cell_text(c)) for c in row)
                if self.cells < width or self.chars < size:
                    break
                self.cells -= width
                self.chars -= size
                keep += 1
            if keep >= len(rows):
                return b
            self.cut = True
            fitted = {**b, "rows": rows[:max(keep, 1)], "more": len(rows) - max(keep, 1)}
            if "row_labels" in b:
                fitted["row_labels"] = b["row_labels"][:max(keep, 1)]
            return fitted
        text = b.get("text")
        if isinstance(text, str):
            if len(text) > self.chars:
                self.cut = True
                return {**b, "text": text[:max(self.chars, 0)].rsplit("\n", 1)[0] + "\n…"}
            self.chars -= len(text)
        elif kind == "fields":
            self.chars -= sum(len(k) + len(v) for k, v in b["rows"])
        return b


def _count_rows(blocks: list[Block]) -> int:
    n = 0
    for b in blocks:
        if b["type"] == "table":
            n += len(b["rows"])
        elif b["type"] == "section":
            n += _count_rows(b["blocks"])
        else:
            n += 1
    return n


def _rest_note(n: int) -> str:
    return f"Показано начало документа. Не показано строк и абзацев: {n}. Они в файле и обезличены так же."


# MARK: Markdown для «Скопировать»

def to_markdown(blocks: Iterable[Block]) -> str:
    """Текст для чата с нейросетью: Markdown читают все модели. Части с `copy: false` не копируются.
    Пункты списка подряд — без пустой строки между ними, как пишут списки в Markdown."""
    out = ""
    previous = None
    for b in blocks:
        md = _md(b)
        if not md:
            continue
        if out:
            out += "\n" if previous == "item" and b["type"] == "item" else "\n\n"
        out += md
        previous = b["type"]
    return out


def _md(b: Block, depth: int = 0) -> str:
    kind = b["type"]
    if kind == "heading":
        return "#" * min(b["level"], 6) + " " + _one_line(b["text"])
    if kind == "paragraph":
        return ("> " + b["text"].replace("\n", "\n> ")) if b.get("style") == "quote" else b["text"]
    if kind == "item":
        marker = "-" if b["marker"] in ("•", "◦", "▪", "–", "-", "*") else b["marker"]
        return "  " * b["level"] + f"{marker} " + b["text"].replace("\n", "\n" + "  " * (b["level"] + 1))
    if kind == "table":
        return _md_table(b)
    if kind == "fields":
        return "\n".join(f"{k}: {v}" for k, v in b["rows"])
    if kind == "code":
        return f"```{b.get('lang', '')}\n{b['text']}\n```"
    if kind == "note":
        return f"_{b['text']}_"
    if kind == "section":
        if b.get("copy") is False:
            return ""
        inner = to_markdown(_nested(x, depth + 1) for x in b["blocks"])
        title = b.get("title")
        head = f"{'#' * min(depth + 2, 6)} {title}" if b["kind"] in ("slide", "sheet", "page") else f"**{title}**"
        return "\n\n".join(p for p in (head if title else "", inner) if p)
    return ""


def _nested(b: Block, depth: int) -> Block:
    """Заголовки внутри слайда или листа — на уровень ниже заголовка самого слайда."""
    if b["type"] == "heading":
        return {**b, "level": min(b["level"] + depth, 6)}
    return b


def _md_table(b: Block) -> str:
    rows = [[_md_cell(c) for c in r] for r in b["rows"]]
    width = max(len(r) for r in rows)
    rows = [r + [""] * (width - len(r)) for r in rows]
    head, body = (rows[0], rows[1:]) if b.get("header") else ([""] * width, rows)
    lines = ["| " + " | ".join(head) + " |", "|" + "|".join(" --- " for _ in range(width)) + "|"]
    lines += ["| " + " | ".join(r) + " |" for r in body]
    if b.get("title"):
        lines.insert(0, f"**{b['title']}**\n")
    return "\n".join(lines)


def _md_cell(c: Any) -> str:
    return _one_line(cell_text(c)).replace("|", "\\|")


def _one_line(s: str) -> str:
    return re.sub(r"\s*\n\s*", " ", s).strip()

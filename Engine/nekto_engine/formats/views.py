"""Вид текстовых документов для редактора (layout.py): из уже обезличенного текста, после обработки.

Вид строится по готовому результату, а не во время поиска: форма текста (строки, табуляции, разметка) при
обезличивании не меняется, а метки уже стоят на местах. Поэтому обработка и вид не зависят друг от друга.
"""
from __future__ import annotations

import re
from html.parser import HTMLParser
from pathlib import Path

from . import layout as L
from .layout import Block

# Что показывать как код (моноширинным, без разбора разметки): исходники, конфиги, журналы, данные.
CODE_EXTENSIONS = {
    ".log", ".ini", ".cfg", ".conf", ".env", ".yaml", ".yml", ".toml", ".sql", ".py", ".js", ".ts", ".tsx", ".jsx",
    ".swift", ".kt", ".java", ".go", ".rb", ".php", ".cs", ".cpp", ".c", ".h", ".hpp", ".rs", ".sh", ".bat", ".ps1",
    ".properties", ".json", ".jsonl", ".ndjson", ".geojson", ".xml", ".svg", ".plist", ".xliff", ".resx",
}
MARKDOWN_EXTENSIONS = {".md", ".markdown"}

_HEADING = re.compile(r"^(#{1,6})\s+(\S.*?)\s*#*\s*$")
_BULLET = re.compile(r"^(\s*)([-*•–·▪◦])\s+(\S.*)$")
_NUMBERED = re.compile(r"^(\s*)(\d{1,3}(?:\.\d{1,3})*[.)]|[a-zа-я][.)])\s+(\S.*)$")
_FENCE = re.compile(r"^\s*(```|~~~)\s*([\w+-]*)\s*$")
_QUOTE = re.compile(r"^\s*>\s?(.*)$")


def for_file(path: Path, text: str) -> list[Block]:
    """Вид файла по расширению: код — кодом, остальное — текстом."""
    ext = path.suffix.lower()
    if ext in CODE_EXTENSIONS:
        return [L.code(text, ext.lstrip("."))]
    return text_blocks(text, markdown=ext in MARKDOWN_EXTENSIONS)


def text_blocks(text: str, markdown: bool | None = None) -> list[Block]:
    """Абзацы, списки, таблицы (вставка из Excel через табуляцию и Markdown) и — в Markdown — заголовки, цитаты, код.

    `markdown=None` — решить по тексту: заголовки `#` распознаются, если в тексте есть хотя бы два
    Markdown-признака (заголовок, блок кода, таблица с разделителем), чтобы строка «# 5 в списке» не стала заголовком."""
    from .plaintext import _table_blocks

    lines = text.split("\n")
    if markdown is None:
        markdown = _looks_like_markdown(lines)
    tables = {b.lines.start: b for b in _table_blocks(lines)}
    out: list[Block] = []
    run: list[str] = []          # строки одного абзаца: подряд, без пустой строки между ними

    def flush() -> None:
        if run:
            out.append(L.paragraph("\n".join(run)))
            run.clear()

    i, n = 0, len(lines)
    while i < n:
        if i in tables:
            flush()
            out.append(_text_table(tables[i], lines))
            i = tables[i].lines.stop
            continue
        line = lines[i]
        if markdown and (m := _FENCE.match(line)):
            flush()
            j = i + 1
            while j < n and not (lines[j].strip().startswith(m.group(1))):
                j += 1
            out.append(L.code("\n".join(lines[i + 1:j]), m.group(2) or None))
            i = j + 1
            continue
        block = _line_block(line, markdown)
        if block and block["type"] == "paragraph" and "style" not in block:
            run.append(block["text"])     # перевод строки внутри абзаца сохраняется: письмо, подпись, чат, PDF
        else:
            flush()
            if block:
                out.append(block)
        i += 1
    flush()
    return L.compact(out)


def _line_block(line: str, markdown: bool) -> Block | None:
    if not line.strip():
        return None
    if markdown and (m := _HEADING.match(line)):
        return L.heading(m.group(2), len(m.group(1)))
    if markdown and (m := _QUOTE.match(line)):
        return L.paragraph(m.group(1), "quote")
    if m := _BULLET.match(line):
        return L.item(m.group(3), "•", _indent(m.group(1)))
    if m := _NUMBERED.match(line):
        return L.item(m.group(3), m.group(2), _indent(m.group(1)))
    return L.paragraph(line.rstrip())


def _indent(spaces: str) -> int:
    return len(spaces.replace("\t", "    ")) // 2


def _looks_like_markdown(lines: list[str]) -> bool:
    signs = 0
    for line in lines[:2000]:
        if _HEADING.match(line) or _FENCE.match(line) or re.match(r"^\s*\|?\s*:?-{3,}:?\s*\|", line):
            signs += 1
            if signs >= 2:
                return True
    return False


def _text_table(block, lines: list[str]) -> Block | None:
    from .plaintext import _MD_RULE

    rows = []
    for k in block.lines:
        if _MD_RULE.match(lines[k]):
            continue
        cells = block.cells(lines[k])
        rows.append([lines[k][a:b].strip() for a, b in cells])
    ruled = len(block.lines) > 1 and bool(_MD_RULE.match(lines[block.lines.start + 1]))   # | a | b |\n|---|---|
    return L.table(rows, header=ruled or L.looks_like_header(rows))


# MARK: HTML

def html_blocks(markup: str) -> list[Block]:
    """Видимый текст HTML по блокам: заголовки, абзацы, списки, таблицы. Скрипты и стили не показываются."""
    parser = _HTMLBlocks()
    try:
        parser.feed(markup)
        parser.close()
    except Exception:  # noqa: BLE001 — кривой HTML: показываем то, что успели разобрать
        pass
    parser.flush()
    return L.compact(parser.blocks)


class _HTMLBlocks(HTMLParser):
    _BLOCK = {"p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "blockquote", "pre",
              "address", "figure", "figcaption", "form", "fieldset", "dl", "dt", "dd", "hr", "body", "html", "center"}
    _SKIP = {"script", "style", "head", "template", "noscript", "svg"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.blocks: list[Block] = []
        self.buf: list[str] = []
        self.kind: tuple[str, object] = ("p", None)
        self.skip = 0
        self.lists: list[list] = []          # [тег, счётчик] вложенных списков
        self.tables: list[dict] = []         # {"rows": [...], "header": bool}
        self.title = ""
        self.in_title = False

    def handle_starttag(self, tag, attrs):
        if tag in self._SKIP:
            self.skip += 1
            return
        if tag == "title":
            self.in_title = True
            return
        if self.skip:
            return
        if tag == "br":
            self.buf.append("\n")
        elif re.fullmatch(r"h[1-6]", tag):
            self.flush(); self.kind = ("h", int(tag[1]))
        elif tag in ("ul", "ol"):
            self.flush(); self.lists.append([tag, 0])
        elif tag == "li":
            self.flush()
            marker = "•"
            if self.lists:
                self.lists[-1][1] += 1
                if self.lists[-1][0] == "ol":
                    marker = f"{self.lists[-1][1]}."
            self.kind = ("li", (marker, max(0, len(self.lists) - 1)))
        elif tag == "table":
            self.flush(); self.tables.append({"rows": [], "header": False})
        elif tag == "tr" and self.tables:
            self.tables[-1]["rows"].append([])
        elif tag in ("td", "th") and self.tables:
            self.buf = []
            if tag == "th" and len(self.tables[-1]["rows"]) == 1:
                self.tables[-1]["header"] = True
        elif tag in self._BLOCK:
            self.flush()
            if tag == "blockquote":
                self.kind = ("q", None)

    def handle_endtag(self, tag):
        if tag in self._SKIP:
            self.skip = max(0, self.skip - 1)
            return
        if tag == "title":
            self.in_title = False
            return
        if self.skip:
            return
        if tag in ("td", "th") and self.tables:
            rows = self.tables[-1]["rows"]
            if not rows:
                rows.append([])
            rows[-1].append(_squash("".join(self.buf)))
            self.buf = []
        elif tag == "table" and self.tables:
            t = self.tables.pop()
            if self.tables:          # вложенная таблица — текстом в ячейку внешней
                self.buf.append(" ".join(" ".join(r) for r in t["rows"]))
            else:
                self.blocks.append(L.table(t["rows"], header=t["header"]))
        elif tag in ("ul", "ol"):
            self.flush()
            if self.lists:
                self.lists.pop()
        elif re.fullmatch(r"h[1-6]", tag) or tag == "li" or tag in self._BLOCK:
            self.flush()

    def handle_data(self, data):
        if self.in_title:
            self.title += data
            return
        if not self.skip:
            self.buf.append(data.replace("\n", " "))  # перевод строки в разметке — пробел; строку переносит <br>

    def flush(self) -> None:
        if self.tables:
            return
        text = _squash("".join(self.buf))
        self.buf = []
        kind, arg = self.kind
        self.kind = ("p", None)
        if not text:
            return
        if kind == "h":
            self.blocks.append(L.heading(text, int(arg)))  # type: ignore[arg-type]
        elif kind == "li":
            marker, level = arg  # type: ignore[misc]
            self.blocks.append(L.item(text, marker, level))
        elif kind == "q":
            self.blocks.append(L.paragraph(text, "quote"))
        else:
            for part in text.split("\n"):
                if part.strip():
                    self.blocks.append(L.paragraph(part.strip()))


def _squash(s: str) -> str:
    """Пробелы HTML схлопываются, переводы строки от <br> остаются."""
    return "\n".join(re.sub(r"[ \t\r\f\v\u00a0]+", " ", part).strip() for part in s.split("\n")).strip()

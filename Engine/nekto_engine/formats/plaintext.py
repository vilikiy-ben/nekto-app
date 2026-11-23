"""Простой текст: .txt, .md, .log, исходный код и всё текстовое без структуры."""
from __future__ import annotations

import re
import unicodedata
from pathlib import Path

from charset_normalizer import from_bytes

from . import views
from .base import Context, Result, UnreadableFile, clip, output_path

EXTENSIONS = {
    ".txt", ".text", ".md", ".markdown", ".log", ".rst", ".tex", ".ini", ".cfg", ".conf", ".env", ".yaml", ".yml",
    ".toml", ".sql", ".py", ".js", ".ts", ".tsx", ".jsx", ".swift", ".kt", ".java", ".go", ".rb", ".php", ".cs",
    ".cpp", ".c", ".h", ".hpp", ".rs", ".sh", ".bat", ".ps1", ".vtt", ".srt", ".properties",
}


def read_text(path: Path) -> str:
    return unicodedata.normalize("NFC", _decode(path))


def _decode(path: Path) -> str:
    raw = path.read_bytes()
    if not raw:
        return ""
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw[3:].decode("utf-8", errors="replace")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        best = from_bytes(raw).best()
        if best is None:
            raise UnreadableFile("не удалось определить кодировку") from None
        return str(best)


def process(src: Path, out_dir: Path, ctx: Context) -> Result:
    text = read_text(src)
    cleaned = clean_lines(text, ctx)
    dst = output_path(src, out_dir)
    dst.write_text(cleaned, encoding="utf-8")
    return Result(dst, clip(cleaned), ctx.replaced, layout=views.for_file(src, cleaned))


def clean_lines(text: str, ctx: Context, lo: float = 0.0, hi: float = 1.0) -> str:
    """Режем по абзацам: детектор упакует их в окна и не будет резать посреди сущности.
    Таблицы внутри текста (вставка из Excel через табуляцию, Markdown) — строками с заголовками (rows.py)."""
    lines = text.split("\n")
    blocks = list(_table_blocks(lines))
    in_table = {i for b in blocks for i in b.data}
    plain = [i for i in range(len(lines)) if i not in in_table]
    mid = lo + (hi - lo) * (0.5 if blocks else 1.0)
    for i, cleaned in zip(plain, ctx.clean_segments([lines[i] for i in plain], lo, mid)):
        lines[i] = cleaned
    for b in blocks:
        b.clean(lines, ctx, mid, hi)
    return "\n".join(lines)


class _Block:
    """Таблица в тексте: строки данных и границы ячеек в каждой строке."""

    def __init__(self, header: list[str], data: dict[int, list[tuple[int, int]]], source: list[str]) -> None:
        from .. import labels as columns
        from .tabular import looks_like_header
        self.data = data
        self.headers = header if header and looks_like_header(header) else []
        self.lines = range(0)                # все строки таблицы в тексте (для вида в редакторе, layout)
        self.cells = _cells_tsv              # как строка делится на ячейки
        self.header_line: int | None = None
        self.kinds = [columns.classify(h) for h in self.headers]
        self.source = source

    def clean(self, lines: list[str], ctx: Context, lo: float, hi: float) -> None:
        from .. import labels as columns
        from . import rows as rows_mod
        line_spans: dict[int, list] = {i: [] for i in self.data}
        pending = []
        for i, cells in self.data.items():
            items = []
            for c, (a, b) in enumerate(cells):
                value = self.source[i][a:b]
                kind = self.kinds[c] if c < len(self.kinds) else None
                if kind is not None and columns.accept(kind, value):
                    sp = rows_mod.whole(value, kind)
                    if sp:
                        line_spans[i].append(sp.shifted(a))
                elif rows_mod.worth_in_row(value):
                    items.append((a, rows_mod.Item(value, self.headers[c] if c < len(self.headers) else None)))
            if items:
                pending.append((i, items))
        found = rows_mod.find_rows(ctx, [[it for _a, it in items] for _i, items in pending], lo, hi)
        for (i, items), cells in zip(pending, found):
            for (a, _it), spans in zip(items, cells):
                line_spans[i] += [sp.shifted(a) for sp in spans]
        from ..spans import merge
        for i, spans in line_spans.items():
            spans = merge(spans)
            if spans:
                ctx.replaced += len(spans)
                lines[i] = ctx.session.apply(self.source[i], spans)


_TSV_ROW = re.compile(r"^[^\t\s][^\t]*\t")
_MD_ROW = re.compile(r"^\s*\|.*\|\s*$")
_PSQL_RULE = re.compile(r"^\s*-{2,}(?:\+-{2,})+\s*$")
_MD_RULE = re.compile(r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$")


def _cells_tsv(line: str) -> list[tuple[int, int]]:
    out, pos = [], 0
    for part in line.split("\t"):
        out.append((pos, pos + len(part)))
        pos += len(part) + 1
    return out


def _cells_md(line: str) -> list[tuple[int, int]]:
    bars = [m.start() for m in re.finditer(r"(?<!\\)\|", line)]
    out = []
    for a, b in zip(bars, bars[1:]):
        inner = line[a + 1:b]
        lead = len(inner) - len(inner.lstrip())
        out.append((a + 1 + lead, a + 1 + len(inner.rstrip())))
    return out


def _cells_sep(line: str, sep: str) -> list[tuple[int, int]]:
    out, pos = [], 0
    for part in line.split(sep):
        lead = len(part) - len(part.lstrip())
        out.append((pos + lead, pos + len(part.rstrip()) if part.strip() else pos + lead))
        pos += len(part) + len(sep)
    return out


def _separator(line: str) -> str | None:
    """Разделитель выгрузки, вставленной в текст: «;» (не меньше четырёх столбцов) или « | » без рамки."""
    if line.count(" | ") >= 2 and not line.lstrip().startswith("|"):
        return " | "
    if line.count(";") >= 3 and not line.rstrip().endswith(("{", "}", ")")):
        return ";"
    return None


def _table_blocks(lines: list[str]):
    """Подряд идущие строки с одинаковым числом табуляций (≥ 2 строки), строки Markdown-таблицы или выгрузка
    с разделителем (≥ 3 строки с одним и тем же числом столбцов)."""
    i, n = 0, len(lines)
    while i < n:
        if _TSV_ROW.search(lines[i]):   # табуляция между текстом, а не отступ кода
            tabs, j = lines[i].count("\t"), i
            while j < n and lines[j].count("\t") == tabs and _TSV_ROW.search(lines[j]) and not lines[j].startswith("\t"):
                j += 1
            if j - i >= 2:
                header = [lines[i][a:b].strip() for a, b in _cells_tsv(lines[i])]
                block = _Block(header, {}, lines)
                start = i + 1 if block.headers else i
                block.data = {k: _cells_tsv(lines[k]) for k in range(start, j)}
                block.lines, block.header_line = range(i, j), (i if block.headers else None)
                block.cells = _cells_tsv
                yield block
                i = j
                continue
        sep = _separator(lines[i])
        if sep:
            count, j = lines[i].count(sep), i
            while j < n and lines[j].count(sep) == count and _separator(lines[j]) == sep:
                j += 1
            ruled = j == i + 1 and j + 1 < n and bool(_PSQL_RULE.match(lines[j]))      # вывод psql: шапка, черта, строки
            if ruled:
                j += 1
                while j < n and lines[j].count(sep) == count and _separator(lines[j]) == sep:
                    j += 1
            if j - i >= 3:
                cells = (lambda line, sep=sep: _cells_sep(line, sep))
                header = [lines[i][a:b].strip() for a, b in cells(lines[i])]
                if any(re.search(r"\d{2}", c) for c in header):          # строка данных, а не шапка
                    header = []
                block = _Block(header, {}, lines)
                start = (i + 2 if ruled else i + 1) if (block.headers or ruled) else i
                block.data = {k: cells(lines[k]) for k in range(start, j)}
                block.lines, block.header_line = range(i, j), (i if block.headers else None)
                block.cells = cells
                yield block
                i = j
                continue
        if _MD_ROW.match(lines[i]):
            j = i
            while j < n and _MD_ROW.match(lines[j]):
                j += 1
            if j - i >= 2:
                rows = [k for k in range(i, j) if not _MD_RULE.match(lines[k])]
                header_line = i if i + 1 < j and _MD_RULE.match(lines[i + 1]) else None
                header = [lines[header_line][a:b] for a, b in _cells_md(lines[header_line])] if header_line is not None else []
                block = _Block(header, {}, lines)
                block.data = {k: _cells_md(lines[k]) for k in rows if not (block.headers and k == header_line)}
                block.lines, block.header_line = range(i, j), (header_line if block.headers else None)
                block.cells = _cells_md
                yield block
                i = j
                continue
        i += 1

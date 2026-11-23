"""Таблицы: общий алгоритм + CSV/TSV.

Столбцы с понятным заголовком («ФИО», «Телефон», «Паспорт») заменяются целиком,
остальные ячейки строки проходят через модель вместе, каждая со своим заголовком (rows.py).
"""
from __future__ import annotations

import csv
import io
from pathlib import Path

from ..kinds import Kind
from .. import labels as columns
from . import layout
from . import rows as rows_mod
from .base import Context, Result, clip, output_path
from .plaintext import read_text

EXTENSIONS = {".csv", ".tsv", ".tab"}


def looks_like_header(row: list[str]) -> bool:
    cells = [c.strip() for c in row if c and c.strip()]
    if not cells:
        return False
    if any(columns.classify(c) for c in cells):
        return True
    textual = sum(1 for c in cells if not any(ch.isdigit() for ch in c) and len(c) <= 40)
    return textual >= max(1, int(len(cells) * 0.8))


def clean_rows(rows: list[list[str]], ctx: Context, lo: float = 0.0, hi: float = 1.0) -> list[list[str]]:
    """Столбцы известного типа заменяются целиком, остальные ячейки строки уходят в модель вместе,
    каждая со своим заголовком (rows.py)."""
    if not rows:
        return rows
    has_header = looks_like_header(rows[0])
    headers = [str(h) for h in rows[0]] if has_header else []
    kinds: list[Kind | None] = [columns.classify(h) for h in headers]
    out = [list(r) for r in rows]
    pending: list[list[tuple[int, rows_mod.Item]]] = []
    for r, row in enumerate(rows):
        if has_header and r == 0:
            continue
        items = []
        for c, value in enumerate(row):
            if not isinstance(value, str):
                continue
            kind = kinds[c] if c < len(kinds) else None
            if kind is not None and columns.accept(kind, value):
                out[r][c] = value.replace(value.strip(), ctx.whole(kind, value.strip()), 1)
            elif rows_mod.worth_in_row(value):
                items.append((c, rows_mod.Item(value, headers[c] if c < len(headers) else None)))
        if items:
            pending.append([(r, c, it) for c, it in items])
        ctx.progress(lo + (hi - lo) * 0.1 * (r + 1) / len(rows))
    found = rows_mod.find_rows(ctx, [[it for _r, _c, it in row] for row in pending], lo + (hi - lo) * 0.1, hi)
    for row, cells in zip(pending, found):
        for (r, c, it), spans in zip(row, cells):
            if spans:
                ctx.replaced += len(spans)
                out[r][c] = ctx.session.apply(it.text, spans)
    return out


def _dialect(sample: str, ext: str) -> type[csv.Dialect] | csv.Dialect:
    if ext in (".tsv", ".tab"):
        return csv.excel_tab
    try:
        return csv.Sniffer().sniff(sample, delimiters=";,\t|")
    except csv.Error:
        return csv.excel


def process(src: Path, out_dir: Path, ctx: Context) -> Result:
    text = read_text(src)
    dialect = _dialect(text[:20000], src.suffix.lower())
    rows = list(csv.reader(io.StringIO(text, newline=""), dialect))
    cleaned = clean_rows(rows, ctx)
    buf = io.StringIO(newline="")
    terminator = "\r\n" if "\r\n" in text[:5000] else "\n"
    writer = csv.writer(buf, delimiter=dialect.delimiter, quotechar=dialect.quotechar or '"',
                        quoting=csv.QUOTE_MINIMAL, lineterminator=terminator)
    writer.writerows(cleaned)
    result = buf.getvalue()
    dst = output_path(src, out_dir)
    dst.write_text(result, encoding="utf-8")
    # номера строк файла слева, как у листа Excel: «строка 37» в редакторе — та же строка в файле
    view = layout.table(cleaned, header=bool(rows) and looks_like_header(rows[0]),
                        row_labels=[str(i) for i in range(1, len(cleaned) + 1)])
    return Result(dst, clip(result), ctx.replaced, layout=layout.compact([view]))

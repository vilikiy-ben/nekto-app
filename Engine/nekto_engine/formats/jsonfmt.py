"""JSON и JSON Lines: значения обезличиваются, ключи и структура сохраняются."""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from ..kinds import Kind
from .. import labels as columns
from . import layout
from . import rows as rows_mod
from .base import Context, Result, UnreadableFile, clip, output_path
from .plaintext import read_text

EXTENSIONS = {".json", ".jsonl", ".ndjson", ".geojson"}
_NUMERIC_KINDS = {Kind.PHONE, Kind.INN, Kind.SNILS, Kind.PASSPORT, Kind.CARD, Kind.ACCOUNT, Kind.ID, Kind.BIRTHDATE}


class _Walker:
    """Два одинаковых обхода. Сначала каждое значение-лист получает решение: целиком по ключу известного типа,
    в модель или как есть. Листья одного объекта уходят в модель одной строкой, ключи — заголовками (rows.py):
    `{"кто": "Иванов И. И.", "связь": 89161234567}` модель видит как «кто: Иванов И. И.; связь: 89161234567».
    Затем второй обход в том же порядке подставляет результат."""

    def __init__(self, ctx: Context) -> None:
        self.ctx = ctx
        self.leaves: list[Any] = []                       # результат для каждого листа по порядку обхода
        self.rows: list[list[tuple[int, rows_mod.Item]]] = []
        self.cursor = 0

    def collect(self, node: Any, key: str | None = None, row: list | None = None) -> None:
        if isinstance(node, dict):
            mine: list[tuple[int, rows_mod.Item]] = []
            for k, v in node.items():
                self.collect(v, k, mine)
            if mine:
                self.rows.append(mine)
        elif isinstance(node, list):
            for v in node:
                if isinstance(v, (dict, list)):
                    self.collect(v, key, None)
                else:
                    self.collect(v, key, row)
        else:
            self._leaf(node, key, row)

    def _leaf(self, node: Any, key: str | None, row: list | None) -> None:
        index = len(self.leaves)
        self.leaves.append(node)
        kind = columns.classify(key)
        if isinstance(node, bool) or node is None:
            return
        if isinstance(node, str):
            if kind and columns.accept(kind, node):
                self.leaves[index] = self.ctx.whole(kind, node.strip())
                return
            text = node
        elif isinstance(node, (int, float)):
            text = str(node)
            if kind in _NUMERIC_KINDS:
                if columns.accept(kind, text):
                    self.leaves[index] = self.ctx.whole(kind, text)
                return
            if len(re.sub(r"\D", "", text)) < 10:   # суммы, количества, id записей — не трогаем
                return
        else:
            return
        if not rows_mod.worth_in_row(text):
            return
        item = (index, rows_mod.Item(text, key))
        if row is None:
            self.rows.append([item])
        else:
            row.append(item)

    def scan(self) -> None:
        found = rows_mod.find_rows(self.ctx, [[it for _i, it in row] for row in self.rows])
        for row, cells in zip(self.rows, found):
            for (index, item), spans in zip(row, cells):
                if spans:
                    self.ctx.replaced += len(spans)
                    self.leaves[index] = self.ctx.session.apply(item.text, spans)

    def rebuild(self, node: Any) -> Any:
        if isinstance(node, dict):
            return {k: self.rebuild(v) for k, v in node.items()}
        if isinstance(node, list):
            return [self.rebuild(v) for v in node]
        value = self.leaves[self.cursor]
        self.cursor += 1
        return value


def _indent(text: str) -> int | None:
    for line in text.splitlines()[1:6]:
        stripped = len(line) - len(line.lstrip(" "))
        if stripped:
            return stripped
    return None


def process(src: Path, out_dir: Path, ctx: Context) -> Result:
    text = read_text(src)
    walker = _Walker(ctx)
    lines_mode = src.suffix.lower() in (".jsonl", ".ndjson")
    try:
        docs = [json.loads(l) for l in text.splitlines() if l.strip()] if lines_mode else [json.loads(text)]
    except json.JSONDecodeError as e:
        raise UnreadableFile(f"JSON повреждён: {e}") from e
    for d in docs:
        walker.collect(d)
    walker.scan()
    rebuilt = [walker.rebuild(d) for d in docs]
    if lines_mode:
        out = "\n".join(json.dumps(d, ensure_ascii=False) for d in rebuilt) + "\n"
    else:
        out = json.dumps(rebuilt[0], ensure_ascii=False, indent=_indent(text)) + ("\n" if text.endswith("\n") else "")
    dst = output_path(src, out_dir)
    dst.write_text(out, encoding="utf-8")
    return Result(dst, clip(out), ctx.replaced, layout=[layout.code(out, "json")])

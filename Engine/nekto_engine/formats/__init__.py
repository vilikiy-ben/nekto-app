"""Реестр форматов: расширение → обработчик."""
from __future__ import annotations

from pathlib import Path
from types import ModuleType

from . import docx, email_fmt, jsonfmt, markup, plaintext, pptx, tabular, xlsx
from .base import Context, Result, UnreadableFile, UnsupportedFormat

_HANDLERS: list[ModuleType] = [tabular, xlsx, docx, pptx, jsonfmt, markup, email_fmt, plaintext]


def handler_for(path: Path) -> ModuleType:
    ext = path.suffix.lower()
    for h in _HANDLERS:
        if ext in h.EXTENSIONS:
            return h
    if _looks_textual(path):
        return plaintext
    raise UnsupportedFormat(ext or path.name)


def supported_extensions() -> list[str]:
    return sorted({e for h in _HANDLERS for e in h.EXTENSIONS})


def _looks_textual(path: Path) -> bool:
    try:
        head = path.read_bytes()[:8192]
    except OSError:
        return False
    if not head or b"\x00" in head:
        return False
    try:
        head.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return sum(b < 9 or 13 < b < 32 for b in head) == 0


def process(path: Path, out_dir: Path, ctx: Context) -> Result:
    return handler_for(path).process(path, out_dir, ctx)


__all__ = ["Context", "Result", "UnreadableFile", "UnsupportedFormat", "handler_for", "process", "supported_extensions"]

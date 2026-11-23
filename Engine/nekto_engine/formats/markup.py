"""HTML / XML / SVG: текст между тегами + почта и телефоны в атрибутах (mailto:, tel:)."""
from __future__ import annotations

import html
import re
from pathlib import Path

from ..kinds import Kind
from ..rules import RULES
from . import layout, views
from .base import Context, Result, clip, output_path
from .plaintext import read_text

EXTENSIONS = {".html", ".htm", ".xhtml", ".xml", ".svg", ".plist", ".xliff", ".resx", ".fb2"}
_HTML = {".html", ".htm", ".xhtml", ".fb2"}   # показываются текстом по блокам; остальная разметка — кодом
_TOKEN = re.compile(r"(<!--.*?-->|<!\[CDATA\[.*?\]\]>|<[^>]+>)", re.S)
_RAW = re.compile(r"<(script|style)\b", re.I)
_ATTR_RULES = [r for r in RULES if r.kind in (Kind.EMAIL, Kind.PHONE, Kind.URL)]


def clean_markup(text: str, ctx: Context, lo: float = 0.0, hi: float = 1.0) -> tuple[str, str]:
    """Возвращает (обезличенная разметка, видимый текст для предпросмотра)."""
    parts = _TOKEN.split(text)
    idx: list[int] = []
    raw_until: str | None = None
    for i, part in enumerate(parts):
        if i % 2 == 1:  # тег
            if raw_until and part.lower().startswith(f"</{raw_until}"):
                raw_until = None
            elif (m := _RAW.match(part)) and not part.endswith("/>"):
                raw_until = m.group(1).lower()
            parts[i] = _clean_tag(part, ctx)
        elif raw_until is None and part.strip():
            idx.append(i)
    texts = [html.unescape(parts[i]) for i in idx]
    cleaned = ctx.clean_segments(texts, lo, hi)
    for i, original, new in zip(idx, texts, cleaned):
        if new != original:
            parts[i] = html.escape(new, quote=False)
    visible = "\n".join(t.strip() for t in cleaned if t.strip())
    return "".join(parts), visible


def _clean_tag(tag: str, ctx: Context) -> str:
    if tag.startswith("<!--"):
        inner = tag[4:-3]
        return "<!--" + ctx.clean_text(inner) + "-->" if inner.strip() else tag
    spans = []
    for rule in _ATTR_RULES:
        spans.extend(sp for sp in rule.find(tag) if sp.kind not in ctx.session.keep)
    if not spans:
        return tag
    from ..spans import merge
    return ctx.session.apply(tag, merge(spans))


def process(src: Path, out_dir: Path, ctx: Context) -> Result:
    text = read_text(src)
    out, visible = clean_markup(text, ctx)
    dst = output_path(src, out_dir)
    dst.write_text(out, encoding="utf-8")
    ext = src.suffix.lower()
    view = views.html_blocks(out) if ext in _HTML else [layout.code(out, ext.lstrip("."))]
    return Result(dst, clip(layout.to_markdown(view) if ext in _HTML else visible), ctx.replaced, layout=view)

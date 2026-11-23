"""Word (.docx, .docm, .dotx): основной текст, таблицы, надписи, колонтитулы, сноски,
примечания, исправления (в т.ч. удалённый текст) и метаданные.
Таблицы — строками с заголовками, столбец «Паспорт» или «ФИО» заменяется целиком (ooxml.clean_tables)."""
from __future__ import annotations

import re
from pathlib import Path

from . import docx_view, layout, ooxml
from .base import Context, Result, UnreadableFile, clip, output_path

EXTENSIONS = {".docx", ".docm", ".dotx"}
_W = "{%s}" % ooxml.NS["w"]
_TABLE = ooxml.TableTags(tbl=_W + "tbl", tr=_W + "tr", tc=_W + "tc", p=_W + "p", span=_W + "gridSpan")
_PARTS = re.compile(r"^word/(document|header\d*|footer\d*|footnotes|endnotes|comments\w*)\.xml$")


def process(src: Path, out_dir: Path, ctx: Context) -> Result:
    dst = output_path(src, out_dir)
    parts: dict = {}                      # обезличенные корни частей — для вида в редакторе (docx_view)
    support: dict[str, bytes] = {}         # стили и нумерация: заголовки и номера пунктов в редакторе
    try:
        import zipfile
        with zipfile.ZipFile(src) as z:
            targets = [n for n in z.namelist() if _PARTS.match(n)]
    except Exception as e:  # noqa: BLE001
        raise UnreadableFile(str(e)) from e
    order = {n: i for i, n in enumerate(sorted(targets, key=lambda n: (not n.startswith("word/document"), n)))}
    step = 1.0 / max(1, len(order))

    def handle(name: str, data: bytes) -> bytes | None:
        if name in order:
            i = order[name]
            root = ooxml.parse(data)
            paragraphs = ooxml.collect(root, _W + "p", _W + "t")
            in_tables = ooxml.clean_tables(root, paragraphs, _TABLE, ctx, i * step, (i + 0.5) * step)
            ooxml.clean_paragraphs([p for p in paragraphs if id(p) not in in_tables], ctx, (i + 0.5) * step, (i + 0.9) * step)
            # удалённый при рецензировании текст и коды полей (HYPERLINK "mailto:…") — отдельными сегментами
            extra = [ooxml.Paragraph([n]) for tag in ("delText", "instrText") for n in root.iter(_W + tag) if n.text]
            ooxml.clean_paragraphs(extra, ctx, (i + 0.9) * step, (i + 1) * step)
            ooxml.anonymize_attributes(root, [_W + "author"], ctx, blank=[_W + "initials"])
            parts[name] = root
            return ooxml.serialize(root)
        if name == "docProps/core.xml":
            root = ooxml.parse(data)
            ooxml.clean_core_properties(root, ctx)
            parts[name] = root
            return ooxml.serialize(root)
        if name in ("word/styles.xml", "word/numbering.xml"):
            support[name] = data
        return None

    ooxml.rewrite_zip(src, dst, handle)
    view = layout.safely(docx_view.build, parts, support.get("word/styles.xml"), support.get("word/numbering.xml"))
    preview = layout.to_markdown(view) if view is not None else "\n".join(
        p.text for p in ooxml.collect(parts["word/document.xml"], _W + "p", _W + "t")) if "word/document.xml" in parts else ""
    return Result(dst, clip(preview), ctx.replaced, layout=view)

"""PowerPoint (.pptx): слайды, заметки докладчика, комментарии и их авторы, метаданные."""
from __future__ import annotations

import re
import zipfile
from pathlib import Path

from . import layout, ooxml, pptx_view
from .base import Context, Result, UnreadableFile, clip, output_path

EXTENSIONS = {".pptx", ".pptm", ".potx"}
_A = "{%s}" % ooxml.NS["a"]
_P = "{%s}" % ooxml.NS["p"]
_TABLE = ooxml.TableTags(tbl=_A + "tbl", tr=_A + "tr", tc=_A + "tc", p=_A + "p", span="gridSpan")
_PARTS = re.compile(r"^ppt/(slides/slide\d+|notesSlides/notesSlide\d+|comments/\w+|diagrams/data\d+|charts/chart\d+)\.xml$")


def _slide_no(name: str) -> int:
    m = re.search(r"(\d+)\.xml$", name)
    return int(m.group(1)) if m else 0


def process(src: Path, out_dir: Path, ctx: Context) -> Result:
    dst = output_path(src, out_dir)
    try:
        with zipfile.ZipFile(src) as z:
            targets = sorted((n for n in z.namelist() if _PARTS.match(n)), key=lambda n: (not n.startswith("ppt/slides/"), _slide_no(n)))
    except Exception as e:  # noqa: BLE001
        raise UnreadableFile(str(e)) from e
    order = {n: i for i, n in enumerate(targets)}
    step = 1.0 / max(1, len(order))
    slides: dict[int, list[str]] = {}
    parts: dict = {}                      # обезличенные корни — для вида в редакторе (pptx_view)
    raw: dict[str, bytes] = {}            # связи и presentation.xml — порядок слайдов и заметки

    def handle(name: str, data: bytes) -> bytes | None:
        if name in order:
            i = order[name]
            root = ooxml.parse(data)
            paragraphs = ooxml.collect(root, _A + "p", _A + "t")
            comments = [ooxml.Paragraph([t]) for t in root.iter(_P + "text") if t.text]
            in_tables = ooxml.clean_tables(root, paragraphs, _TABLE, ctx, i * step, (i + 0.5) * step)
            rest = [p for p in paragraphs if id(p) not in in_tables] + comments
            ooxml.clean_paragraphs(rest, ctx, (i + 0.5) * step, (i + 1) * step)
            if name.startswith("ppt/slides/"):
                slides[_slide_no(name)] = [p.text for p in paragraphs if p.text.strip()]
            parts[name] = root
            return ooxml.serialize(root)
        if name in ("ppt/commentAuthors.xml", "ppt/authors.xml"):
            root = ooxml.parse(data)
            ooxml.anonymize_attributes(root, ["name"], ctx, blank=["initials"])
            parts[name] = root
            return ooxml.serialize(root)
        if name == "docProps/core.xml":
            root = ooxml.parse(data)
            ooxml.clean_core_properties(root, ctx)
            parts[name] = root
            return ooxml.serialize(root)
        if name == "ppt/presentation.xml" or name.endswith(".rels"):
            raw[name] = data
        return None

    ooxml.rewrite_zip(src, dst, handle)
    view = layout.safely(pptx_view.build, parts, raw)
    preview = layout.to_markdown(view) if view is not None else "\n\n".join(
        f"— Слайд {n} —\n" + "\n".join(lines) for n, lines in sorted(slides.items()))
    return Result(dst, clip(preview), ctx.replaced, layout=view)

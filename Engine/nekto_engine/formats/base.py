"""Общий контекст обработки файла."""
from __future__ import annotations

import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Sequence

from .. import orgs, recall
from ..detector import Detector
from ..kinds import Kind
from ..names.finder import Vocabulary
from ..session import Session
from ..spans import merge

ProgressFn = Callable[[float], None]
PREVIEW_LIMIT = 400_000


class UnsupportedFormat(Exception):
    pass


class UnreadableFile(Exception):
    pass


@dataclass
class Result:
    output: Path | None          # обезличенный файл (None — только текст)
    preview: str                 # текст для предпросмотра и копирования
    replaced: int = 0            # сколько фрагментов заменено в этом файле
    notes: list[str] = field(default_factory=list)
    layout: list[dict] | None = None  # вид для редактора (layout.py); None — показать preview как текст


@dataclass
class Context:
    detector: Detector
    session: Session
    cancel: threading.Event
    progress: ProgressFn
    replaced: int = 0
    # строчные слова документа: что документ считает обычными словами (names.finder); копится по мере чтения файла
    vocabulary: Vocabulary = field(default_factory=Vocabulary)

    def clean_segments(self, segments: Sequence[str], lo: float = 0.0, hi: float = 1.0,
                       scopes: Sequence | None = None) -> list[str]:
        """Обезличивает список строк, сохраняя их число и порядок."""
        found = self.find(segments, lo, hi, scopes)
        out = []
        for seg, spans in zip(segments, found):
            self.replaced += len(spans)
            out.append(self.session.apply(seg, spans) if spans else seg)
        return out

    def clean_text(self, text: str, lo: float = 0.0, hi: float = 1.0) -> str:
        return self.clean_segments([text], lo, hi)[0]

    def find(self, segments: Sequence[str], lo: float = 0.0, hi: float = 1.0, scopes: Sequence | None = None,
             context: bool = True):
        """Спаны (с учётом ручных правок пользователя) без замены — для форматов с текстом в XML-узлах.

        `scopes` — область каждого сегмента для склейки людей (`names.registry`): строка таблицы — своя область,
        сплошной текст — одна на все сегменты (по умолчанию). `context=False` — сегменты независимы (ячейки
        таблицы), и соседи модели не показываются (`Detector.detect_segments`)."""
        for seg in segments:
            self.vocabulary.add(seg)
        found = self.detector.detect_segments(segments, self.cancel, lambda f: self.progress(lo + (hi - lo) * f),
                                              self.vocabulary, context)
        if Kind.ORG in self.session.hide:  # режим «Скрывать организации»: правила orgs.py, без него — ни символа
            found = [merge(spans + orgs.find(seg)) for seg, spans in zip(segments, found)]
        # найденное однажды — везде: в остальных сегментах и в документах, обработанных раньше (recall.py)
        found = recall.speakers(segments, found)
        found = recall.extend(segments, found, recall.known_values(self.session, zip(segments, found)), self.vocabulary)
        found = [self.session.adjust(seg, spans) for seg, spans in zip(segments, found)]
        return self.session.bind(list(segments), found, list(scopes) if scopes is not None else None)

    def tag(self, kind: Kind, value: str, ref: str | None = None) -> str:
        """Метка для значения. `ref` — метка, уже выбранная для него поиском (`Span.ref`)."""
        if kind in self.session.keep or self.session.is_allowed(value):
            return value
        self.replaced += 1
        return self.session.placeholder(kind, value, ref)

    def whole(self, kind: Kind, value: str) -> str:
        """Значение целиком — ПДн известного типа (например, ячейка в столбце «Телефон»)."""
        return self.tag(kind, value)


def output_path(src: Path, out_dir: Path, suffix: str | None = None) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    return out_dir / f"{src.stem} (обезличено){suffix or src.suffix}"


def clip(preview: str) -> str:
    return preview if len(preview) <= PREVIEW_LIMIT else preview[:PREVIEW_LIMIT] + "\n…"

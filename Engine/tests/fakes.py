"""Подмена модели в тестах: «размечает» заданные слова и считает обращения."""
from __future__ import annotations

import re
from pathlib import Path

from nekto_engine.detector import Detector, DetectorConfig
from nekto_engine.model import Tag


class CountingTagger:
    """Вместо `model.Tagger`: каждому слову заданных фраз даёт их метку с уверенностью 0,9."""

    loaded = True

    def __init__(self, phrases: dict[str, str]) -> None:
        self.phrases = phrases
        self.calls = 0
        self.seen: list[list[str]] = []          # что показывали модели, по вызовам

    def load(self) -> None:
        pass

    def tag(self, texts, progress=None, cancelled=None):
        self.calls += 1
        self.seen.append(list(texts))
        out = []
        for text in texts:
            tags = []
            for phrase, label in self.phrases.items():
                for m in re.finditer(re.escape(phrase), text):
                    tags += [Tag(m.start() + w.start(), m.start() + w.end(), label, 0.9) for w in re.finditer(r"\w+", phrase)]
            out.append(sorted(tags, key=lambda t: t.start))
        return out


class CountingDetector(Detector):
    """Детектор без модели: `model_calls` — сколько раз понадобилась бы модель."""

    def __init__(self, phrases: dict[str, str] | None = None) -> None:
        super().__init__(DetectorConfig(model_dir=Path("/nonexistent")))
        self.tagger = CountingTagger(phrases or {})

    @property
    def model_calls(self) -> int:
        return self.tagger.calls

"""Модель ПДн: токен-классификатор на ONNX Runtime.

Модель — redmadrobot-rnd/rubert-base-pii-ner (ruBERT-base, 43 метки BIO: имя / фамилия / отчество, части адреса,
контакты, номера документов) в ONNX-экспорте lockR/rubert-base-pii-ner-onnx. Она видит регистр букв, а прежняя (gliner2) приводила текст к строчным и путала фамилии с обычными словами.

Что делает этот модуль и чего не делает:
- режет длинный текст на окна по токенам с перекрытием, собирает пакеты из окон близкой длины (короткие строки
  не дополняются до длинных) и держит пакет в бюджете токенов — от него зависит пик памяти;
- поднимает ответ с кусочков слов до слов: слово получает метку, если её получил хотя бы один его кусочек
  (модель нередко размечает «Сагде» и пропускает «евой»);
- ничего не решает: отдаёт слова с метками и уверенностью. Что из этого ПДн — решает `detector` вместе со словарём
  имён и правилами.
"""
from __future__ import annotations

import json
import re
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

from . import mapped

MODEL_FILE = "model.optimized.fp32.onnx"
# Слово для модели: буквы и цифры, внутри — дефис или апостроф («Ершовой-Ширшиной», «О'Нил»); знак — отдельно.
_WORD = re.compile(r"[^\W_]+(?:[-'’][^\W_]+)*|[^\w\s]")


@dataclass(frozen=True, slots=True)
class Tag:
    """Слово, которому модель дала метку: координаты в тексте, метка без B-/I-, уверенность."""
    start: int
    end: int
    label: str
    score: float


class Tagger:
    def __init__(self, model_dir: Path, threads: int = 4, max_tokens: int = 320, stride: int = 48,
                 batch_tokens: int = 4096, floor: float = 0.25) -> None:
        self.model_dir = Path(model_dir)
        self.threads = threads
        self.max_tokens = max_tokens      # окно: длиннее — квадратично дороже, а метке хватает соседних предложений
        self.stride = stride              # перекрытие окон, чтобы сущность не оказалась на шве
        self.batch_tokens = batch_tokens  # пакет × длина: потолок памяти на один вызов модели
        self.floor = floor                # ниже — метка не отдаётся вовсе
        self._session = None
        self._tokenizer = None
        self._labels: list[str] = []
        self._lock = threading.Lock()

    @property
    def loaded(self) -> bool:
        return self._session is not None

    def load(self) -> None:
        with self._lock:
            if self._session is not None:
                return
            import onnxruntime as ort
            from tokenizers import Tokenizer

            config = json.loads((self.model_dir / "config.json").read_text())
            self._labels = [config["id2label"][str(i)] for i in range(len(config["id2label"]))]
            self._outside = self._labels.index("O")
            tokenizer = Tokenizer.from_file(str(self.model_dir / "tokenizer.json"))
            tokenizer.no_padding()
            tokenizer.no_truncation()
            self._cls, self._sep = tokenizer.token_to_id("[CLS]"), tokenizer.token_to_id("[SEP]")
            options = ort.SessionOptions()
            options.intra_op_num_threads = self.threads
            options.inter_op_num_threads = 1
            options.log_severity_level = 3
            path = mapped.ensure(self.model_dir / MODEL_FILE, self.model_dir / "mapped")
            self._session = ort.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])
            self._inputs = {i.name for i in self._session.get_inputs()}
            self._tokenizer = tokenizer

    # ---------- публичное ----------

    def tag(self, texts: Sequence[str], progress: Callable[[float], None] | None = None,
            cancelled: Callable[[], bool] | None = None) -> list[list[Tag]]:
        """Слова с метками для каждого текста, в его координатах, по порядку."""
        if self._session is None:
            raise RuntimeError("model is not loaded")
        import numpy as np

        encoded = self._tokenizer.encode_batch(list(texts), add_special_tokens=False) if texts else []
        pieces: list[tuple[int, int, int]] = []            # (текст, первый токен, за последним)
        for index, enc in enumerate(encoded):
            n = len(enc.ids)
            start = 0
            while start < n:
                end = min(n, start + self.max_tokens)
                pieces.append((index, start, end))
                if end == n:
                    break
                start = end - self.stride
        pieces.sort(key=lambda p: p[2] - p[1])
        # лучший ответ на токен: при перекрытии окон берём тот, где токен дальше от края окна
        best: list[dict[int, tuple[int, int, float]]] = [{} for _ in texts]   # токен → (запас до края, метка, уверенность)
        done, total = 0, max(1, len(pieces))
        pos = 0
        while pos < len(pieces):
            if cancelled is not None and cancelled():
                raise InterruptedError
            batch = [pieces[pos]]
            pos += 1
            while pos < len(pieces) and (len(batch) + 1) * (pieces[pos][2] - pieces[pos][1] + 2) <= self.batch_tokens:
                batch.append(pieces[pos])
                pos += 1
            width = max(e - s for _i, s, e in batch) + 2
            ids = np.zeros((len(batch), width), dtype=np.int64)
            mask = np.zeros((len(batch), width), dtype=np.int64)
            for row, (index, s, e) in enumerate(batch):
                ids[row, 0] = self._cls
                ids[row, 1:e - s + 1] = encoded[index].ids[s:e]
                ids[row, e - s + 1] = self._sep
                mask[row, :e - s + 2] = 1
            feed = {"input_ids": ids, "attention_mask": mask}
            if "token_type_ids" in self._inputs:
                feed["token_type_ids"] = np.zeros_like(ids)
            logits = self._session.run(None, feed)[0]
            for row, (index, s, e) in enumerate(batch):
                lg = logits[row, 1:e - s + 1].astype(np.float64)
                lg -= lg.max(axis=-1, keepdims=True)
                probs = np.exp(lg)
                probs /= probs.sum(axis=-1, keepdims=True)
                probs[:, self._outside] = 0.0             # «O» — не ответ: нужна лучшая метка и её вероятность
                label = probs.argmax(axis=-1)
                score = probs.max(axis=-1)
                slot = best[index]
                for k in np.nonzero(score >= self.floor)[0]:
                    token = s + int(k)
                    margin = min(int(k), e - s - 1 - int(k)) if (s > 0 or e < len(encoded[index].ids)) else 1 << 30
                    if token not in slot or margin > slot[token][0]:
                        slot[token] = (margin, int(label[k]), float(score[k]))
                # токен, который в лучшем для него окне метки не получил, не должен получить её из худшего
                if s > 0 or e < len(encoded[index].ids):
                    for k in np.nonzero(score < self.floor)[0]:
                        token = s + int(k)
                        margin = min(int(k), e - s - 1 - int(k))
                        if token in slot and margin > slot[token][0]:
                            del slot[token]
                        elif token not in slot:
                            slot[token] = (margin, 0, 0.0)
            done += len(batch)
            if progress:
                progress(done / total)
        return [self._words(text, enc.offsets, slot) for text, enc, slot in zip(texts, encoded, best)]

    # ---------- внутреннее ----------

    def _words(self, text: str, offsets, slot: dict[int, tuple[int, int, float]]) -> list[Tag]:
        """Метки кусочков → метки слов. У слова — метка самого уверенного кусочка."""
        labelled = sorted((offsets[t][0], offsets[t][1], self._labels[lab].split("-", 1)[-1], score)
                          for t, (_m, lab, score) in slot.items() if score > 0.0)
        if not labelled:
            return []
        out: list[Tag] = []
        k = 0
        for m in _WORD.finditer(text):
            while k < len(labelled) and labelled[k][1] <= m.start():
                k += 1
            j, top = k, None
            while j < len(labelled) and labelled[j][0] < m.end():
                if top is None or labelled[j][3] > top[3]:
                    top = labelled[j]
                j += 1
            if top is not None:
                out.append(Tag(m.start(), m.end(), top[2], top[3]))
        return out

"""Модель на диске и в памяти: перекладка весов во внешний файл и подъём меток с кусочков слов до слов."""
import struct

import pytest

from nekto_engine.model import mapped
from nekto_engine.model.mapped import _fields, _key, _string, _varint


def _tensor(name: str, raw: bytes) -> bytes:
    body = _key(1, 0) + _varint(len(raw) // 4) + _key(2, 0) + _varint(1) + _string(8, name) + _key(9, 2) + _varint(len(raw)) + raw
    return body


def _model(tensors: list[bytes], tail: bytes = b"") -> bytes:
    graph = b"".join(_key(5, 2) + _varint(len(t)) + t for t in tensors) + _string(2, "graph")
    return _key(1, 0) + _varint(8) + _key(7, 2) + _varint(len(graph)) + graph + tail


def test_split_moves_big_tensors_and_keeps_the_rest(tmp_path):
    big = struct.pack("<600f", *range(600))            # 2400 байт — уходит во внешний файл
    small = struct.pack("<4f", 1, 2, 3, 4)             # 16 байт — остаётся в графе
    src = tmp_path / "model.onnx"
    src.write_bytes(_model([_tensor("big", big), _tensor("small", small), _tensor("big2", big[::-1])], _string(8, "producer")))
    moved = mapped.split(src, tmp_path / "out.onnx", tmp_path / "out.data", "out.data")
    assert moved == 2
    data = (tmp_path / "out.data").read_bytes()
    out = (tmp_path / "out.onnx").read_bytes()
    assert len(out) < 600 and small in out and big not in out
    # каждая ссылка указывает ровно на свои байты
    seen = []
    for number, _w, _s, _e, body in _fields(out, 0, len(out)):
        if number != 7:
            continue
        for n2, _w2, _s2, _e2, b2 in _fields(out, *body):
            if n2 != 5:
                continue
            entry, location = {}, None
            for n3, _w3, _s3, _e3, b3 in _fields(out, *b2):
                if n3 == 13:
                    kv = [out[b[0]:b[1]].decode() for _n, _w4, _s4, _e4, b in _fields(out, *b3)]
                    entry[kv[0]] = kv[1]
                if n3 == 14:
                    location = out[b3[0] - 1]
            if entry:
                assert location == 1 and entry["location"] == "out.data"
                seen.append(data[int(entry["offset"]):int(entry["offset"]) + int(entry["length"])])
                assert int(entry["offset"]) % 16 == 0
    assert seen == [big, big[::-1]]


def test_ensure_is_idempotent_and_falls_back(tmp_path):
    src = tmp_path / "model.onnx"
    src.write_bytes(_model([_tensor("w", b"\x01" * 4096)]))
    first = mapped.ensure(src, tmp_path / "mapped")
    stamp = (tmp_path / "mapped" / "model.data").stat().st_mtime_ns
    assert first == tmp_path / "mapped" / "model.onnx"
    assert mapped.ensure(src, tmp_path / "mapped") == first
    assert (tmp_path / "mapped" / "model.data").stat().st_mtime_ns == stamp, "второй раз не перекладывает"
    blocked = tmp_path / "file"
    blocked.write_text("не папка")
    assert mapped.ensure(src, blocked / "mapped") == src, "нельзя записать — работаем с исходным файлом"


def test_mapped_model_answers_like_the_original(detector, tmp_path):
    """Перекладка весов не меняет ответ модели ни в одной метке."""
    import onnxruntime as ort

    from nekto_engine.model.tagger import MODEL_FILE
    source = detector.tagger.model_dir / MODEL_FILE
    text = "Договор с Ахмеровой Гульнарой Ильдаровной, тел. +7 900 555-01-48, паспорт 45 11 123456."
    mapped_tags = detector.tagger.tag([text])[0]
    plain = type(detector.tagger)(detector.tagger.model_dir, threads=2)
    original_ensure = mapped.ensure
    try:
        mapped.ensure = lambda src, _dir: src            # грузим цельный файл
        plain.load()
    finally:
        mapped.ensure = original_ensure
    assert ort.get_device() == "CPU"
    assert [(t.start, t.end, t.label) for t in plain.tag([text])[0]] == [(t.start, t.end, t.label) for t in mapped_tags]
    assert source.exists() and (detector.tagger.model_dir / "mapped" / "model.data").exists()


def test_word_gets_label_if_any_piece_has_it(detector):
    """Редкая фамилия режется на кусочки, и модель метит не все: метку получает слово целиком."""
    text = "Спасибо Ахметзяновой-Ширшиной Гульфие за помощь."
    words = {text[t.start:t.end]: t.label for t in detector.tagger.tag([text])[0]}
    assert "Ахметзяновой-Ширшиной" in words and words["Ахметзяновой-Ширшиной"] in ("LAST_NAME", "FIRST_NAME")


def test_long_text_is_windowed_and_offsets_hold(detector):
    filler = "Отчёт о работе отдела за квартал без замечаний. " * 60
    text = filler + "Ответственный — Гиниятуллин Ильдар Маратович." + filler
    tags = detector.tagger.tag([text])[0]
    names = [text[t.start:t.end] for t in tags if t.label.endswith("NAME")]
    assert names == ["Гиниятуллин", "Ильдар", "Маратович"]


def test_cancel_stops_between_batches(detector):
    with pytest.raises(InterruptedError):
        detector.tagger.tag(["Иванов Иван"] * 4, cancelled=lambda: True)

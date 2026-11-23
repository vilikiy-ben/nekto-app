"""Веса модели — отдельным файлом, чтобы система отображала их в память, а не копировала.

ONNX-файл модели цельный: 711 МБ весов внутри protobuf. ONNX Runtime читает такой файл в память и затем копирует
веса к себе — 1,5 ГБ на процесс. Если же веса лежат «внешними данными» (маленький `model.onnx` со ссылками и
`model.data` рядом), Runtime отображает `model.data` в память: страницы принадлежат файлу, система выгружает их
без подкачки, а второй копии нет. На том же документе: 1 656 МБ → 741 МБ.

Перекладка — потоковая, без библиотеки `onnx`: файл проходится по полям protobuf, сырые данные тензоров
(`TensorProto.raw_data`) уходят в `model.data`, в граф вместо них пишется ссылка. Числа не меняются ни на бит,
`tests/test_model.py` сверяет выдачу модели до и после.
"""
from __future__ import annotations

import mmap
import os
from pathlib import Path

# Номера полей ONNX (onnx.proto3)
_MODEL_GRAPH = 7
_GRAPH_INITIALIZER = 5
_TENSOR_RAW_DATA = 9
_TENSOR_EXTERNAL_DATA = 13
_TENSOR_DATA_LOCATION = 14
_EXTERNAL = 1
_MIN_BYTES = 1024            # мелкие тензоры остаются в графе
_ALIGN = 16
_VERSION = "1"               # меняется вместе с форматом перекладки


def ensure(source: Path, target_dir: Path) -> Path:
    """Путь к модели с внешними весами; перекладывает, если ещё не сделано. Не получилось — исходный файл:
    модель работает и так, просто занимает больше памяти."""
    model, data, stamp = target_dir / "model.onnx", target_dir / "model.data", target_dir / "source.txt"
    want = f"{_VERSION}:{source.stat().st_size}:{int(source.stat().st_mtime)}"
    try:
        if model.exists() and data.exists() and stamp.read_text() == want:
            return model
    except OSError:
        pass
    try:
        target_dir.mkdir(parents=True, exist_ok=True)
        tmp_model, tmp_data = target_dir / "model.onnx.tmp", target_dir / "model.data.tmp"
        split(source, tmp_model, tmp_data, "model.data")
        os.replace(tmp_data, data)
        os.replace(tmp_model, model)
        stamp.write_text(want)
        return model
    except OSError:
        return source


def split(source: Path, model_out: Path, data_out: Path, location: str) -> int:
    """Переписывает ONNX-файл: крупные `raw_data` — в `data_out`, в графе — ссылки на `location`.
    Возвращает число вынесенных тензоров."""
    moved = 0
    with open(source, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as buf, \
            open(data_out, "wb") as data:
        out = bytearray()
        for number, wire, start, end, body in _fields(buf, 0, len(buf)):
            if number != _MODEL_GRAPH or wire != 2:
                out += buf[start:end]
                continue
            graph = bytearray()
            for n2, w2, s2, e2, b2 in _fields(buf, body[0], body[1]):
                if n2 == _GRAPH_INITIALIZER and w2 == 2:
                    tensor, was_moved = _tensor(buf, b2[0], b2[1], data, location)
                    moved += was_moved
                    graph += _key(n2, 2) + _varint(len(tensor)) + tensor
                else:
                    graph += buf[s2:e2]
            out += _key(number, 2) + _varint(len(graph)) + graph
        model_out.write_bytes(bytes(out))
    return moved


def _tensor(buf, start: int, end: int, data, location: str) -> tuple[bytes, int]:
    raw = None
    kept = bytearray()
    for number, wire, s, e, body in _fields(buf, start, end):
        if number == _TENSOR_RAW_DATA and wire == 2 and body[1] - body[0] >= _MIN_BYTES:
            raw = body
        else:
            kept += buf[s:e]
    if raw is None:
        return bytes(buf[start:end]), 0
    pad = -data.tell() % _ALIGN
    data.write(b"\0" * pad)
    offset = data.tell()
    data.write(buf[raw[0]:raw[1]])
    for key, value in (("location", location), ("offset", str(offset)), ("length", str(raw[1] - raw[0]))):
        entry = _string(1, key) + _string(2, value)
        kept += _key(_TENSOR_EXTERNAL_DATA, 2) + _varint(len(entry)) + entry
    kept += _key(_TENSOR_DATA_LOCATION, 0) + _varint(_EXTERNAL)
    return bytes(kept), 1


# ---------- protobuf: ровно столько, сколько нужно ----------

def _fields(buf, pos: int, end: int):
    """(номер поля, тип, начало записи, конец записи, (начало, конец) содержимого) для каждого поля сообщения."""
    while pos < end:
        start = pos
        key, pos = _read_varint(buf, pos)
        number, wire = key >> 3, key & 7
        if wire == 0:
            _, pos = _read_varint(buf, pos)
            body = (pos, pos)
        elif wire == 1:
            body = (pos, pos + 8)
            pos += 8
        elif wire == 2:
            size, pos = _read_varint(buf, pos)
            body = (pos, pos + size)
            pos += size
        elif wire == 5:
            body = (pos, pos + 4)
            pos += 4
        else:
            raise ValueError(f"protobuf: неизвестный тип поля {wire}")
        yield number, wire, start, pos, body


def _read_varint(buf, pos: int) -> tuple[int, int]:
    value, shift = 0, 0
    while True:
        byte = buf[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, pos
        shift += 7


def _varint(value: int) -> bytes:
    out = bytearray()
    while value >= 0x80:
        out.append(value & 0x7F | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def _key(number: int, wire: int) -> bytes:
    return _varint(number << 3 | wire)


def _string(number: int, text: str) -> bytes:
    raw = text.encode()
    return _key(number, 2) + _varint(len(raw)) + raw

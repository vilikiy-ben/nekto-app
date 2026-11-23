import os
import re
import sys
import threading
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))   # tests/fakes.py

from nekto_engine.detector import Detector, DetectorConfig
from nekto_engine.formats import Context
from nekto_engine.session import Session

ROOT = Path(__file__).resolve().parents[2]


def _model_dir() -> Path:
    """Тот же порядок, что у scripts/model.sh: $NEKTO_MODEL_DIR, установленная приложением, scripts/fetch-model.sh.
    Ревизия — из App/Sources/Setup/Manifest.swift, как у приложения."""
    if env := os.environ.get("NEKTO_MODEL_DIR"):
        return Path(env).expanduser()
    manifest = (ROOT / "App/Sources/Setup/Manifest.swift").read_text()
    folder = re.search(r'static let modelFolder = "([^"]+)"', manifest).group(1)
    installed = Path.home() / "Library/Application Support/Nekto/model" / folder
    return installed if installed.is_dir() else ROOT / "build/devruntime/model" / folder


MODEL_DIR = _model_dir()


@pytest.fixture(scope="session")
def detector():
    if not (MODEL_DIR / "model.optimized.fp32.onnx").exists():
        pytest.skip(f"нет модели в {MODEL_DIR}")
    d = Detector(DetectorConfig(model_dir=MODEL_DIR))
    d.load()
    return d


@pytest.fixture
def ctx(detector):
    return Context(detector, Session(), threading.Event(), lambda _: None)


@pytest.fixture
def out_dir(tmp_path):
    return tmp_path / "out"

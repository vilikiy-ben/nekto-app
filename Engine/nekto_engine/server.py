"""Процесс-движок: JSON-строки через stdin/stdout.

Запрос:  {"id": "…", "op": "…", "session": "…", …}
События: {"id": "…", "event": "progress", "value": 0.42}
         {"id": "…", "event": "result", …}
         {"id": "…", "event": "error", "code": "…", "message": "…"}

Операции без сессии: load, selftest, ping, cancel.
Операции обработки (поле "session" — идентификатор обработки в приложении; нет поля — "default"):
  clean_text {text, name?}      → {text, name, replaced, layout, mapping, state}
  clean_file {path, out_dir}    → {output, preview, replaced, notes, layout, mapping, state}
                                  layout — вид для редактора: {version, blocks} (formats/layout.py) или null
  force {text, kind} / unforce {text}           — скрыть пропущенное моделью
  allow {placeholder} / unallow {placeholder}   — не скрывать ложное срабатывание
  configure {keep: ["ДАТА", …], hide: ["ОРГ"]}  — типы, которые в этой обработке не скрываются / скрываются
                                                  дополнительно (по умолчанию видны: kinds.OPT_IN)
  restore {state}               — поднять сохранённую обработку (state из прошлых ответов)
  drop                          — забыть обработку
  mapping / reset
Тексты документов в stderr/логи не пишутся никогда.
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import sys
import threading
import time
import traceback
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

from . import __version__  # noqa: E402
from .detector import Cancelled, Detector, DetectorConfig  # noqa: E402
from .formats import Context, UnreadableFile, UnsupportedFormat, process, supported_extensions  # noqa: E402
from .session import Session  # noqa: E402

SELFTEST_TEXT = ("Договор с Ахмеровой Гульнарой Ильдаровной, тел. +7 900 555-01-48, "
                 "e-mail g.akhmerova@example.com. Contact: John Smith, +1 415 555 0199.")


class Server:
    def __init__(self, model_dir: Path, threads: int) -> None:
        self.detector = Detector(DetectorConfig(model_dir=model_dir, threads=threads))
        self.sessions: dict[str, Session] = {}
        self.jobs: "queue.Queue[dict]" = queue.Queue()
        self.cancels: dict[str, threading.Event] = {}
        self._out = threading.Lock()

    # ---------- ввод/вывод ----------

    def emit(self, payload: dict) -> None:
        line = json.dumps(payload, ensure_ascii=False)
        with self._out:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()

    def reader(self) -> None:
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            try:
                req = json.loads(raw)
            except json.JSONDecodeError:
                self.emit({"event": "error", "code": "bad_request", "message": "invalid json"})
                continue
            op = req.get("op")
            if op == "cancel":
                ev = self.cancels.get(str(req.get("target")))
                if ev:
                    ev.set()
                continue
            if op == "ping":
                self.emit({"id": req.get("id"), "event": "result", "pong": True})
                continue
            self.cancels[str(req.get("id"))] = threading.Event()
            self.jobs.put(req)
        self.jobs.put({"op": "shutdown"})

    # ---------- обработка ----------

    def worker(self) -> None:
        while True:
            req = self.jobs.get()
            op, rid = req.get("op"), req.get("id")
            if op == "shutdown":
                return
            cancel = self.cancels.get(str(rid), threading.Event())
            try:
                handler = getattr(self, f"op_{op}", None)
                if handler is None:
                    raise ValueError(f"unknown op {op}")
                result = handler(req, cancel)
                self.emit({"id": rid, "event": "result", **result})
            except Cancelled:
                self.emit({"id": rid, "event": "error", "code": "cancelled", "message": "Отменено"})
            except UnsupportedFormat as e:
                self.emit({"id": rid, "event": "error", "code": "unsupported", "message": str(e)})
            except UnreadableFile as e:
                self.emit({"id": rid, "event": "error", "code": "unreadable", "message": str(e)})
            except Exception as e:  # noqa: BLE001
                traceback.print_exc(file=sys.stderr)
                self.emit({"id": rid, "event": "error", "code": "internal", "message": type(e).__name__})
            finally:
                self.cancels.pop(str(rid), None)

    def session(self, req: dict) -> Session:
        sid = str(req.get("session") or "default")
        if sid not in self.sessions:
            self.sessions[sid] = Session()
        return self.sessions[sid]

    def _ctx(self, rid: str, cancel: threading.Event, session: Session) -> Context:
        last = [0.0]

        def progress(v: float) -> None:
            now = time.monotonic()
            if v >= 1.0 or now - last[0] > 0.08:
                last[0] = now
                self.emit({"id": rid, "event": "progress", "value": round(max(0.0, min(1.0, v)), 4)})

        return Context(self.detector, session, cancel, progress)

    def op_load(self, req: dict, cancel: threading.Event) -> dict:
        t = time.monotonic()
        self.detector.load()
        return {"loaded": True, "seconds": round(time.monotonic() - t, 2), "version": __version__,
                "extensions": supported_extensions()}

    def op_selftest(self, req: dict, cancel: threading.Event) -> dict:
        self.detector.load()
        probe = Session()
        t = time.monotonic()
        spans = self.detector.detect(SELFTEST_TEXT)
        cleaned = probe.apply(SELFTEST_TEXT, spans)
        kinds = sorted({s.kind.value for s in spans})
        ok = {"ФИО", "ТЕЛЕФОН", "EMAIL"} <= set(kinds) and "Ахмеров" not in cleaned and "Smith" not in cleaned
        return {"ok": ok, "kinds": kinds, "ms": round((time.monotonic() - t) * 1000)}

    def op_clean_text(self, req: dict, cancel: threading.Event) -> dict:
        self.detector.load()
        session = self.session(req)
        ctx = self._ctx(req["id"], cancel, session)
        from .formats.plaintext import clean_lines
        import unicodedata
        from .formats import layout, views
        text = clean_lines(unicodedata.normalize("NFC", req.get("text", "")), ctx)
        name = req.get("name")
        safe_name = self._safe_name(name, ctx) if name else None
        view = layout.safely(views.text_blocks, text)
        return {"text": text, "name": safe_name, "replaced": ctx.replaced,
                "layout": layout.finish(view) if view is not None else None, **self._snapshot(session)}

    def op_clean_file(self, req: dict, cancel: threading.Event) -> dict:
        self.detector.load()
        session = self.session(req)
        ctx = self._ctx(req["id"], cancel, session)
        src, out_dir = Path(req["path"]), Path(req["out_dir"])
        res = process(src, out_dir, ctx)
        output = res.output
        if output is not None:  # имя файла тоже может содержать ФИО: «Договор Мансуровой.docx»
            safe = self._safe_name(src.stem, ctx)
            import unicodedata
            if safe != unicodedata.normalize("NFC", src.stem):
                target = output.with_name(unicodedata.normalize("NFC", output.name).replace(
                    unicodedata.normalize("NFC", src.stem), safe, 1))
                output.rename(target)
                output = target
        from .formats import layout
        return {"output": str(output) if output else None, "preview": res.preview,
                "replaced": res.replaced, "notes": res.notes,
                "layout": layout.finish(res.layout) if res.layout is not None else None, **self._snapshot(session)}

    @staticmethod
    def _snapshot(session: Session) -> dict:
        return {"mapping": session.mapping(), "state": session.to_state()}

    @staticmethod
    def _safe_name(name: str, ctx: Context) -> str:
        import unicodedata
        name = unicodedata.normalize("NFC", name)  # пути из Finder приходят в NFD
        replaced = ctx.replaced
        cleaned = ctx.clean_text(name)
        ctx.replaced = replaced  # замены в имени файла не считаем в статистике документа
        return "".join("_" if ch in '/:\0' else ch for ch in cleaned)

    def op_force(self, req: dict, cancel: threading.Event) -> dict:
        from .kinds import Kind
        session = self.session(req)
        kind = next((k for k in Kind if k.value == req.get("kind")), Kind.OTHER)
        session.force(req["text"], kind)
        return self._snapshot(session)

    def op_unforce(self, req: dict, cancel: threading.Event) -> dict:
        session = self.session(req)
        session.unforce(req["text"])
        return self._snapshot(session)

    def op_allow(self, req: dict, cancel: threading.Event) -> dict:
        session = self.session(req)
        session.allow(req["placeholder"])
        return self._snapshot(session)

    def op_unallow(self, req: dict, cancel: threading.Event) -> dict:
        session = self.session(req)
        session.unallow(req["placeholder"])
        return self._snapshot(session)

    def op_configure(self, req: dict, cancel: threading.Event) -> dict:
        from .kinds import Kind
        session = self.session(req)
        wanted = set(req.get("keep") or [])
        session.set_keep({k for k in Kind if k.value in wanted})
        extra = set(req.get("hide") or [])
        session.set_hide({k for k in Kind if k.value in extra})
        return self._snapshot(session)

    def op_restore(self, req: dict, cancel: threading.Event) -> dict:
        sid = str(req.get("session") or "default")
        self.sessions[sid] = Session.from_state(req.get("state") or {})
        return self._snapshot(self.sessions[sid])

    def op_drop(self, req: dict, cancel: threading.Event) -> dict:
        self.sessions.pop(str(req.get("session") or "default"), None)
        return {"dropped": True}

    def op_reset(self, req: dict, cancel: threading.Event) -> dict:
        self.session(req).reset()
        return {"reset": True}

    def op_mapping(self, req: dict, cancel: threading.Event) -> dict:
        return self._snapshot(self.session(req))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True, type=Path)
    ap.add_argument("--threads", type=int, default=min(4, os.cpu_count() or 4))
    args = ap.parse_args()
    srv = Server(args.model_dir, args.threads)
    threading.Thread(target=srv.reader, daemon=True).start()
    srv.emit({"event": "hello", "version": __version__, "pid": os.getpid()})
    srv.worker()


if __name__ == "__main__":
    main()

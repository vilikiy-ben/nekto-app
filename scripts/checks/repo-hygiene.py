#!/usr/bin/env python3
"""В репозитории только продукт. Проверяет то, что уходит в git (файлы в индексе), а не рабочую папку:

1. Каждый файл — внутри белого списка из .gitignore (строки `!/…`). Добавленный в обход (`git add -f`) — ошибка.
2. Картинки, видео и PDF — только там, где они часть продукта: ресурсы приложения, образ, картинки README.
3. Markdown — только README и docs/ARCHITECTURE.md: разборы, журналы и заметки в репозиторий не попадают.
4. Ни одного файла больше 2 МБ.
5. Ни одного пути домашней папки (/Users/<имя>): он выдаёт имя пользователя и не работает на чужом Mac.

    python3 scripts/checks/repo-hygiene.py

Запускается перед каждым коммитом (.githooks/pre-commit) и в CI. Код возврата 1, если что-то не так.
"""
from __future__ import annotations

import fnmatch
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEDIA = re.compile(r"\.(png|jpe?g|gif|heic|webp|tiff?|mov|mp4|m4v|pdf|psd|sketch|fig)$", re.I)
MEDIA_PLACES = ("App/Resources/*", "packaging/dmg/*", "docs/assets/readme/*")
MARKDOWN = {"README.md", "README.en.md", "docs/ARCHITECTURE.md"}
MAX_BYTES = 2 * 1024 * 1024
HOME_PATH = re.compile(rb"/Users/(?!Shared\b)[A-Za-z][\w.-]*")


def whitelist() -> list[str]:
    """Корневые записи белого списка: `!/App/` → `App/`, `!/README.md` → `README.md`."""
    out = []
    for line in (ROOT / ".gitignore").read_text().splitlines():
        rest = line[2:]
        if line.startswith("!/") and "/" not in rest.rstrip("/"):
            out.append(rest)
    return out


def git(*args: str, stdin: bytes | None = None) -> bytes:
    return subprocess.run(["git", *args], cwd=ROOT, input=stdin, capture_output=True, check=True).stdout


def staged() -> dict[str, bytes]:
    """Файлы, которые войдут в следующий коммит, с содержимым из индекса — не из рабочей папки: после `git add`
    файл можно поправить или удалить с диска, а в коммит уйдёт то, что лежит в индексе."""
    entries: list[tuple[str, str]] = []
    for record in git("ls-files", "-z", "--stage").split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        mode, sha, _stage = meta.split()
        if mode != b"160000":                     # подмодуль — не файл
            entries.append((path.decode(), sha.decode()))
    blobs = read_blobs(sorted({sha for _, sha in entries}))
    return {path: blobs[sha] for path, sha in entries}


def read_blobs(shas: list[str]) -> dict[str, bytes]:
    """Содержимое объектов одним вызовом `git cat-file --batch`: «<sha> <тип> <размер>\\n<данные>\\n» на каждый."""
    out, pos, blobs = git("cat-file", "--batch", stdin="".join(f"{s}\n" for s in shas).encode()), 0, {}
    for sha in shas:
        end = out.index(b"\n", pos)
        _sha, _kind, size = out[pos:end].split()
        start = end + 1
        blobs[sha] = out[start:start + int(size)]
        pos = start + int(size) + 1
    return blobs


def main() -> int:
    allowed = whitelist()
    files = staged()
    errors: list[str] = []
    for name, data in files.items():
        if not any(name == a or (a.endswith("/") and name.startswith(a)) for a in allowed):
            errors.append(f"{name}: вне белого списка .gitignore")
        elif name.startswith("docs/") and name != "docs/ARCHITECTURE.md" and not name.startswith("docs/assets/"):
            errors.append(f"{name}: в docs/ — только ARCHITECTURE.md и картинки README")
        if MEDIA.search(name) and not any(fnmatch.fnmatch(name, p) or name.startswith(p.rstrip("*")) for p in MEDIA_PLACES):
            errors.append(f"{name}: картинки и видео — только ресурсы приложения, образ и картинки README")
        if name.endswith(".md") and name not in MARKDOWN:
            errors.append(f"{name}: лишний Markdown — документация продукта это README и docs/ARCHITECTURE.md")
        if len(data) > MAX_BYTES:
            errors.append(f"{name}: {len(data) // 1024} КБ — больше 2 МБ")
        if not MEDIA.search(name) and (home := HOME_PATH.search(data)):
            errors.append(f"{name}: путь домашней папки ({home.group().decode(errors='replace')})")
    for e in errors:
        print(f"✗ {e}")
    if errors:
        print(f"\nНарушений: {len(errors)}. Что можно — в начале этого файла и в .gitignore.")
        return 1
    print(f"Репозиторий чистый: {len(files)} файлов, всё внутри белого списка.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

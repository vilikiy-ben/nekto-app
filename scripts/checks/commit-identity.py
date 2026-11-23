#!/usr/bin/env python3
"""Автор коммита назван явно, а не собран git из учётной записи Mac; соавторов-ассистентов в коммитах нет.

Если `user.email` нигде не задан, git подставляет «<имя пользователя>@<имя компьютера>»
(`anna@Annas-MacBook.local`) и полное имя из учётной записи — так в публичную историю уходят имя и имя машины. Проверка:

    python3 scripts/checks/commit-identity.py                      перед коммитом: кто будет автором и коммиттером
    python3 scripts/checks/commit-identity.py <old> <new>          перед пушем: все коммиты, которых нет на сервере
    python3 scripts/checks/commit-identity.py --message <файл>      сообщение коммита (commit-msg)

Перед коммитом — точно: личность задана в настройках или в окружении (GIT_AUTHOR_EMAIL, EMAIL). Перед пушем
настроек того времени уже не видно, поэтому — по виду адреса: домен без точки или локальный (.local, .lan, …).
Ловит то, что pre-commit не видит: rebase, cherry-pick, `--no-verify`. Своя почта с настоящим доменом проходит —
форкам ничего не навязывается; адрес GitHub без почты — `<id>+<логин>@users.noreply.github.com`.

Соавторы: в этом репозитории коммиты пишет человек, строки `Co-authored-by:` с ИИ-ассистентом (Claude, адреса
anthropic.com) и подписи «Generated with Claude Code» не принимаются — ни при коммите, ни при пуше.

Запускают .githooks/pre-commit, .githooks/commit-msg и .githooks/pre-push. Чтобы git сам не придумывал автора ни в одном клоне:
    git config --global user.useConfigOnly true
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

ZERO = "0" * 40
# Домен, который сочинил git, а не человек: без точки, служебный или из локальной сети.
MACHINE_DOMAIN = re.compile(r"@(\(none\)|[^.@>]+|[^@>]*\.(local|lan|home|localdomain|internal|arpa))>?$", re.I)
# Соавтор-ассистент в сообщении коммита: трейлер с Claude или адресом Anthropic, подпись Claude Code.
ASSISTANT = re.compile(r"^\s*co-authored-by:.*(claude|anthropic\.com)|generated with \[?claude code", re.I | re.M)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout.strip()


def configured(role: str) -> bool:
    """Задан ли адрес явно: окружение для роли (GIT_AUTHOR_EMAIL / GIT_COMMITTER_EMAIL), EMAIL или user.email."""
    if os.environ.get(f"GIT_{role}_EMAIL") or os.environ.get("EMAIL"):
        return True
    return subprocess.run(["git", "config", "user.email"], capture_output=True).returncode == 0


def check_next_commit() -> list[str]:
    errors = []
    for role in ("AUTHOR", "COMMITTER"):
        if not configured(role):
            errors.append(f"{role.lower()}: user.email не задан — git подставит имя пользователя и имя компьютера")
            continue
        # С user.useConfigOnly git отказывается собирать личность сам — например, если не задано имя.
        var = subprocess.run(["git", "var", f"GIT_{role}_IDENT"], capture_output=True, text=True)
        if var.returncode != 0:
            reason = next((line for line in var.stderr.splitlines() if line.startswith("fatal:")), var.stderr.strip())
            errors.append(f"{role.lower()}: git не знает, кто автор ({reason.removeprefix('fatal: ')})")
            continue
        ident = var.stdout.strip().rsplit(" ", 2)[0]   # без времени и пояса
        if MACHINE_DOMAIN.search(ident):
            errors.append(f"{role.lower()}: {ident} — адрес на имени компьютера")
    return errors


def check_message(text: str, where: str = "сообщение") -> list[str]:
    body = "\n".join(line for line in text.splitlines() if not line.startswith("#"))   # без комментариев git
    return [f"{where}: «{m.group().strip()}» — соавторство ИИ-ассистента в этом репозитории запрещено"
            for m in ASSISTANT.finditer(body)]


def check_range(old: str, new: str) -> list[str]:
    if new == ZERO:                                   # удаление ветки: отправлять нечего
        return []
    # Новая ветка — всё, чего нет ни в одной ветке сервера; иначе — от старой вершины.
    revs = [new, "--not", "--remotes"] if old == ZERO else [f"{old}..{new}"]
    errors = []
    for record in git("log", "--format=%h%x00%an <%ae>%x00%cn <%ce>%x00%B%x1e", *revs).split("\x1e"):
        if not record.strip():
            continue
        sha, author, committer, message = record.strip("\n").split("\0", 3)
        for role, ident in (("автор", author), ("коммиттер", committer)):
            if MACHINE_DOMAIN.search(ident):
                errors.append(f"{sha} {role}: {ident} — адрес на имени компьютера")
        errors += check_message(message, sha)
    return errors


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "--message":
        with open(argv[1], encoding="utf-8") as f:
            errors = check_message(f.read())
        for e in errors:
            print(f"✗ {e}")
        if errors:
            print("\nУберите эту строку из сообщения. Уже записанный коммит: git commit --amend")
        return 1 if errors else 0
    errors = check_range(*argv) if len(argv) == 2 else check_next_commit()
    for e in errors:
        print(f"✗ {e}")
    if any("соавторство" in e for e in errors):
        print("\nУберите строку из сообщений: git rebase -i <база> → reword")
    if any("соавторство" not in e for e in errors):
        print("\nЗадайте имя и адрес: git config user.name '<логин>'"
              "\n                     git config user.email '<id>+<логин>@users.noreply.github.com'"
              "\nУже записанные коммиты: git rebase <база> --exec 'git commit --amend --no-edit --reset-author'")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

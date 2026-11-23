#!/usr/bin/env python3
"""Имя приложения записано согласованно.

    python3 scripts/checks/name-audit.py

Имя записано трижды: `App/Sources/App/Brand.swift` (интерфейс, пути, ключи), `App/project.yml` (цель, продукт,
идентификатор бандла) и `scripts/brand.sh` (сборка, образ диска). К ним привязаны пакет движка `Engine/<имя>_engine`
и собранное приложение, если оно есть.
"""
from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def one(pattern: str, text: str, what: str, errors: list[str]) -> str:
    match = re.search(pattern, text, flags=re.M)
    if not match:
        fail(errors, f"не найдено: {what}")
        return ""
    return match.group(1)


def check_agreement(errors: list[str]) -> dict[str, str]:
    swift = (ROOT / "App/Sources/App/Brand.swift").read_text()
    name = one(r'static let name = "([^"]+)"', swift, "Brand.name", errors)
    bundle = one(r'static let bundleID = "([^"]+)"', swift, "Brand.bundleID", errors)
    history = one(r'static let historyFolder = "([^"]+)"', swift, "Brand.historyFolder", errors)

    project = (ROOT / "App/project.yml").read_text()
    pairs = {
        "project.yml: name": one(r"^name: (\S+)$", project, "name", errors),
        "project.yml: цель": one(r"^targets:\n  (\S+):$", project, "цель", errors),
        "project.yml: PRODUCT_NAME": one(r"PRODUCT_NAME: (\S+)$", project, "PRODUCT_NAME", errors),
        "project.yml: entitlements": one(r"CODE_SIGN_ENTITLEMENTS: (\S+)\.entitlements$", project, "entitlements", errors),
    }
    shell = (ROOT / "scripts/brand.sh").read_text()
    pairs["brand.sh: APP_NAME"] = one(r'^APP_NAME="([^"]*)"$', shell, "APP_NAME", errors)
    for where, value in pairs.items():
        if value and value != name:
            fail(errors, f"{where} = {value}, а Brand.name = {name}")

    for where, value in {
        "project.yml: PRODUCT_BUNDLE_IDENTIFIER": one(r"PRODUCT_BUNDLE_IDENTIFIER: (\S+)$", project, "идентификатор", errors),
        "brand.sh: APP_BUNDLE_ID": one(r'^APP_BUNDLE_ID="([^"]*)"$', shell, "APP_BUNDLE_ID", errors),
    }.items():
        if value and value != bundle:
            fail(errors, f"{where} = {value}, а Brand.bundleID = {bundle}")

    lower = name.lower()
    if history != f".{lower}":
        fail(errors, f"Brand.historyFolder = {history}, ожидалось .{lower}")
    if not (ROOT / "App" / f"{name}.entitlements").is_file():
        fail(errors, f"нет App/{name}.entitlements")
    plist = (ROOT / "App/Info.plist").read_text()
    for key in ("CFBundleName", "CFBundleDisplayName"):
        if f"<key>{key}</key><string>$(PRODUCT_NAME)</string>" not in plist:
            fail(errors, f"Info.plist: {key} должен быть $(PRODUCT_NAME)")

    package = f"{lower}_engine"
    if not (ROOT / "Engine" / package / "__init__.py").is_file():
        fail(errors, f"нет пакета движка Engine/{package}")
    for path in ("Engine/run_engine.py", "scripts/embed-engine.sh"):
        if package not in (ROOT / path).read_text():
            fail(errors, f"{path} не упоминает {package}")
    return {"name": name, "bundle": bundle}


def check_built_app(brand: dict[str, str], errors: list[str]) -> str:
    app = ROOT / "build/share/app.noindex" / f"{brand['name']}.app"
    if not app.is_dir():
        return "собранного приложения нет — не проверялось"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    for key, expected in (("CFBundleName", brand["name"]), ("CFBundleDisplayName", brand["name"]),
                          ("CFBundleExecutable", brand["name"]), ("CFBundleIdentifier", brand["bundle"])):
        if info.get(key) != expected:
            fail(errors, f"{app.name}: {key} = {info.get(key)}, ожидалось {expected}")
    if not (app / "Contents/Resources/engine" / f"{brand['name'].lower()}_engine").is_dir():
        fail(errors, f"{app.name}: в бандле нет пакета движка")
    return f"{app.relative_to(ROOT)} — имя и идентификатор на месте"


def main() -> None:
    errors: list[str] = []
    brand = check_agreement(errors)
    built = check_built_app(brand, errors) if brand.get("name") else ""
    if errors:
        print("\n".join(f"✗ {e}" for e in errors))
        sys.exit(1)
    print(f"имя: {brand['name']} ({brand['bundle']}) — Brand.swift, project.yml и brand.sh согласны")
    print(f"сборка: {built}")


if __name__ == "__main__":
    main()

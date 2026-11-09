#!/usr/bin/env python3
"""Builds build-ja/ (Burrow JA) from this repository's untouched Burrow sources.

Run: python3 ja/apply_ja.py    then: cd build-ja && scripts/bundle.sh
Exit 1 when a translation no longer matches the source, as after merging a Burrow update.
"""
from pathlib import Path
import html
import importlib.util
import json
import re
import shutil
import sys

KIT = Path(__file__).resolve().parent
ROOT = KIT.parent
OUT = ROOT / "build-ja"
NAME = "Burrow JA"
BUNDLE_ID = "io.github.xenolucus.burrow-ja"
REPO = "xenolucus/burrow-ja"


# A fixed certificate keeps the app's identity across updates, so macOS keeps its Full Disk Access.
# Sparkle's nested code is signed first: --deep leaves its XPC services invalid.
STABLE_SIGNING = f'''if [ -n "${{SIGN_IDENTITY:-}}" ]; then
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
    sign() {{ codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" --timestamp=none "$@"; }}
    for code in "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \\
                "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
        sign --preserve-metadata=entitlements "$code"
    done
    sign "-r=designated => identifier \\"{BUNDLE_ID}\\" and certificate leaf = H\\"$SIGN_IDENTITY\\"" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi
'''


def load_pairs():
    spec = importlib.util.spec_from_file_location("pairs", KIT / "pairs.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def swift_table(table):
    rows = "\n".join(f"        {json.dumps(k, ensure_ascii=False)}: {json.dumps(v, ensure_ascii=False)},"
                     for k, v in sorted(table.items()))
    return f"enum JAGenerated {{\n    static let table: [String: String] = [\n{rows}\n    ]\n}}\n"


def replace_once(text, old, new):
    assert old in text, f"not found: {old}"
    return text.replace(old, new)


def patch_bundle(text, public_key):
    text = replace_once(text, "<string>uz.khan.burrow</string>", f"<string>{BUNDLE_ID}</string>")
    text = replace_once(text, "<key>CFBundleName</key><string>Burrow</string>", f"<key>CFBundleName</key><string>{NAME}</string>")
    text = replace_once(text, "<key>CFBundleDisplayName</key><string>Burrow</string>", f"<key>CFBundleDisplayName</key><string>{NAME}</string>")
    text = replace_once(text, "khan-umirzakoff/Mole-GUI", REPO)
    if public_key:
        text, count = re.subn(r"(<key>SUPublicEDKey</key><string>)[^<]*", r"\g<1>" + public_key, text)
        assert count == 1
    else:
        # shortcut: no key yet means no updater; add ja/sparkle_public_key.txt before a release.
        text, count = re.subn(r"\s*<key>SU[A-Za-z]+</key>.*", "", text)
        assert count == 4, f"expected 4 Sparkle keys, found {count}"
    text = text.replace("<key>SUAutomaticallyUpdate</key><true/>", "<key>SUAutomaticallyUpdate</key><false/>")
    base = (ROOT / "VERSION").read_text().strip()
    region = f"    <key>BurrowBaseVersion</key><string>{base}</string>\n" \
             "    <key>CFBundleDevelopmentRegion</key><string>ja</string>\n" \
             "    <key>CFBundleLocalizations</key><array><string>ja</string></array>\n" \
             "    <key>NSAppleEventsUsageDescription</key><string>Finder ですべてのゴミ箱を空にするために使います。</string>\n"
    text = replace_once(text, "    <key>CFBundleName</key>", region + "    <key>CFBundleName</key>")
    text = replace_once(text, 'codesign --force --deep --sign - "$APP"\n', STABLE_SIGNING)
    text = replace_once(text, 'cp LICENSE "$APP/Contents/Resources/LICENSE"\n',
                        'cp LICENSE LICENSE-Ellipsis.txt "$APP/Contents/Resources/"\n')
    marker = 'cat > "$APP/Contents/Info.plist" <<PLIST'
    return replace_once(text, marker, 'mkdir -p "$APP/Contents/Resources/ja.lproj"\n' + marker)


def rename_outputs(text, appcast=False):
    # In appcast.sh each must match: a missed one ships the wrong file or an unsigned update.
    for needle in ("      <title>Burrow $VERSION</title>\n", '"$SIGN" "$ZIP"', "Burrow.zip") if appcast else ():
        assert needle in text, f"appcast.sh changed upstream: {needle!r} not found"
    text = text.replace("      <title>Burrow $VERSION</title>\n",
                        "      <title>Burrow $VERSION</title>\n      <description><![CDATA[$(cat \"$OUT/notes.html\")]]></description>\n")
    text = text.replace('"$SIGN" "$ZIP"', '"$SIGN" ${SPARKLE_KEY_FILE:+--ed-key-file "$SPARKLE_KEY_FILE"} "$ZIP"')
    return (text.replace("Burrow.app", f"{NAME}.app").replace("Burrow.zip", "BurrowJA.zip")
            .replace("Burrow.dmg", "BurrowJA.dmg").replace("khan-umirzakoff/Mole-GUI", REPO))


def write_notes():
    """ja/NOTES.txt, one change per line, becomes the text in Sparkle's update window."""
    lines = [html.escape(line) for line in (KIT / "NOTES.txt").read_text(encoding="utf-8").splitlines() if line.strip()]
    (OUT / "build").mkdir(exist_ok=True)
    body = "".join(f"<li>{line}</li>" for line in lines) or "<li>細かな修正</li>"
    (OUT / "build/notes.html").write_text(f"<ul>{body}</ul>", encoding="utf-8")


def main():
    pairs = load_pairs()
    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(ROOT, OUT, ignore=shutil.ignore_patterns(".git", ".github", ".build", "build", "build-ja", "ja", "promo", "docs"))
    sources = OUT / "Sources/Burrow"
    missing = []
    for name, rows in pairs.T.items():
        path = sources / name
        text = path.read_text(encoding="utf-8")
        for en, ja in rows:
            if en not in text:
                missing.append((name, en))
            text = text.replace(en, ja)
        for literal in pairs.KEEP.get(name, []):
            assert literal in text, f"{name}: parser string lost: {literal}"
        path.write_text(text, encoding="utf-8")
    tests = OUT / "Tests/BurrowTests/ParserTests.swift"
    text = tests.read_text(encoding="utf-8")
    for en, ja in pairs.TESTS:
        if en not in text:
            missing.append(("Tests", en))
        text = text.replace(en, ja)
    tests.write_text(text, encoding="utf-8")
    shutil.copy2(KIT / "JA.swift", sources / "JA.swift")
    shutil.copy2(KIT / "MenuMetrics.swift", sources / "MenuMetrics.swift")
    shutil.copy2(KIT / "Updates.swift", sources / "Updates.swift")
    shutil.copy2(KIT / "ExternalClean.swift", sources / "ExternalClean.swift")
    shutil.copy2(KIT / "TotalsPage.swift", sources / "TotalsPage.swift")
    shutil.copy2(KIT / "DrivesPage.swift", sources / "DrivesPage.swift")
    shutil.copy2(KIT / "MenuSpacing.swift", sources / "MenuSpacing.swift")
    shutil.copy2(KIT / "MenuHide.swift", sources / "MenuHide.swift")
    shutil.copy2(KIT / "MenuBarPage.swift", sources / "MenuBarPage.swift")
    shutil.copy2(KIT / "Sidebar.swift", sources / "Sidebar.swift")
    shutil.copy2(KIT / "MaxClean.swift", sources / "MaxClean.swift")
    shutil.copy2(KIT / "Remaining.swift", sources / "Remaining.swift")
    shutil.copy2(KIT / "Alerts.swift", sources / "Alerts.swift")
    shutil.copy2(KIT / "Tools.swift", sources / "Tools.swift")
    shutil.copy2(KIT / "MenuTweaks.swift", sources / "MenuTweaks.swift")
    shutil.copy2(KIT / "HeavyApps.swift", sources / "HeavyApps.swift")
    shutil.copy2(KIT / "ManualGuide.swift", sources / "ManualGuide.swift")
    shutil.copy2(KIT / "Duplicates.swift", sources / "Duplicates.swift")
    shutil.copy2(KIT / "LICENSE-Ellipsis.txt", OUT / "LICENSE-Ellipsis.txt")
    shutil.copy2(KIT / "MenuMetricsTests.swift", OUT / "Tests/BurrowTests/MenuMetricsTests.swift")
    write_notes()
    table = json.loads((KIT / "mole_strings.json").read_text(encoding="utf-8"))
    (sources / "JAGenerated.swift").write_text(swift_table(table), encoding="utf-8")
    shutil.copy2(KIT / "VERSION", OUT / "VERSION")
    public_key = (KIT / "sparkle_public_key.txt").read_text().strip()
    bundle = OUT / "scripts/bundle.sh"
    bundle.write_text(patch_bundle(bundle.read_text(encoding="utf-8"), public_key), encoding="utf-8")
    for script in ("bundle.sh", "dmg.sh", "appcast.sh"):
        path = OUT / "scripts" / script
        path.write_text(rename_outputs(path.read_text(encoding="utf-8"), script == "appcast.sh"), encoding="utf-8")
    print(f"pairs: {sum(map(len, pairs.T.values()))}, Mole strings: {len(table)}, missing: {len(missing)}, updater: {'on' if public_key else 'off'}")
    for name, en in missing:
        print(f"MISSING {name}: {en[:110]}")
    sys.exit(1 if missing and "--allow-missing" not in sys.argv else 0)


if __name__ == "__main__":
    main()

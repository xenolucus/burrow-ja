#!/usr/bin/env python3
"""Merges new Burrow and Mole releases, then lists text that has no Japanese yet.

  python3 ja/auto_update.py          update the working tree (used by the workflow)
  python3 ja/auto_update.py --baseline   record today's strings as already reviewed
  python3 ja/auto_update.py --selftest   check the string extractors

Writes build-ja/report.md. Exit 2 means a parser's Mole text vanished: do not ship.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

KIT = Path(__file__).resolve().parent
ROOT = KIT.parent
VENDOR = ROOT / "Vendor/mole"
KNOWN = KIT / "known_strings.json"
REPORT = ROOT / "build-ja/report.md"
MOLE_REPO = "tw93/Mole"
THIS_REPO = "xenolucus/burrow-ja"
# Burrow reads these from Mole's output; a new Mole without them breaks the parsers.
PARSER_TEXT = ["Potential space", "Would remove", "Files to be removed:", "Personal data to remove:",
               "Dry run complete", "Select Artifacts to Purge", "Select apps to slim", "System caches need sudo"]


def run(*cmd, **kw):
    return subprocess.run(cmd, cwd=ROOT, check=True, text=True, capture_output=True, **kw).stdout.strip()


def merge_burrow():
    run("git", "fetch", "-q", "upstream", "main", "--tags")
    ahead = subprocess.run(["git", "merge-base", "--is-ancestor", "upstream/main", "HEAD"], cwd=ROOT).returncode
    if ahead == 0:
        return False
    run("git", "merge", "--no-edit", "-X", "ours", "upstream/main")
    return True


def version_key(text):
    return [int(n) for n in re.findall(r"\d+", text)]


def update_mole():
    """Replaces Vendor/mole as a whole, from the release's source and verified binaries."""
    tag = run("gh", "api", f"repos/{MOLE_REPO}/releases/latest", "-q", ".tag_name")
    version = tag.lstrip("Vv")
    if version_key(version) <= version_key((VENDOR / "VERSION").read_text()):
        return False
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        run("gh", "release", "download", tag, "-R", MOLE_REPO, "-D", str(tmp), "-p", "SHA256SUMS",
            "-p", "status-darwin-arm64", "-p", "analyze-darwin-arm64")
        sums = dict(reversed(line.split()) for line in (tmp / "SHA256SUMS").read_text().splitlines() if line.strip())
        for name in ("status-darwin-arm64", "analyze-darwin-arm64"):
            digest = hashlib.sha256((tmp / name).read_bytes()).hexdigest()
            assert sums.get(name) == digest, f"checksum mismatch: {name}"
        archive = tmp / "source.tgz"
        with archive.open("wb") as out:
            subprocess.run(["gh", "api", f"repos/{MOLE_REPO}/tarball/{tag}"], cwd=ROOT, check=True, stdout=out)
        src = tmp / "src"
        src.mkdir()
        with tarfile.open(archive) as tar:
            tar.extractall(src, filter="data")
        top = next(src.iterdir())
        for name in ("bin", "lib"):
            shutil.rmtree(VENDOR / name)
            shutil.copytree(top / name, VENDOR / name)
        shutil.copy2(top / "mole", VENDOR / "mole")
        shutil.copy2(top / "LICENSE", VENDOR / "LICENSE")
        (VENDOR / "VERSION").write_text(version + "\n")
        for name, target in (("status-darwin-arm64", "status-go"), ("analyze-darwin-arm64", "analyze-go")):
            shutil.copy2(tmp / name, VENDOR / "bin" / target)
            (VENDOR / "bin" / target).chmod(0o755)
    return True


def parser_text_missing():
    text = "\n".join(p.read_text(errors="ignore") for p in VENDOR.rglob("*.sh"))
    return [needle for needle in PARSER_TEXT if needle not in text]


def ui_strings(text):
    found = set()
    for line in text.splitlines():
        if re.match(r"\s*(///?|import )", line):
            continue
        for value in re.findall(r'"((?:[^"\\]|\\.)*)"', re.sub(r"//[^\"]*$", "", line)):
            if re.search(r"[A-Z][a-z]+|[a-z]+ [a-z]+", value) and not re.fullmatch(r"[\w.\-/~$]+", value):
                found.add(value)
    return found


def mole_strings(text):
    found = set()
    for line in text.splitlines():
        if not re.search(r"\b(echo|printf|log_\w+|start_\w*spinner|start_section\w*|note_activity|print_\w+)\b", line):
            continue
        for value in re.findall(r'"([^"]*)"', line):
            value = re.sub(r"\$\{?[A-Za-z_][A-Za-z_0-9]*\}?", "", value).strip(" :,")
            if re.fullmatch(r"[A-Z][A-Za-z0-9 ,.'()/&+-]{5,90}", value) and " " in value:
                found.add(value)
    return found


def current_strings():
    sources = ROOT / "Sources/Burrow"
    ui = set()
    for path in sources.rglob("*.swift"):
        if "Engine" not in path.parts:
            ui |= ui_strings(path.read_text())
    mole = set()
    for path in VENDOR.rglob("*.sh"):
        mole |= mole_strings(path.read_text(errors="ignore"))
    table = json.loads((KIT / "mole_strings.json").read_text(encoding="utf-8"))
    return {"ui": sorted(ui), "mole": sorted(mole - set(table))}


def next_version():
    base = (ROOT / "VERSION").read_text().strip()
    current = (KIT / "VERSION").read_text().strip()
    if current.startswith(base + "."):
        return f"{base}.{int(current.rsplit('.', 1)[1]) + 1}"
    return f"{base}.1"


def released(version):
    """False when an earlier run saved this version but stopped before its release."""
    return subprocess.run(["gh", "release", "view", f"v{version}", "-R", THIS_REPO], cwd=ROOT, capture_output=True).returncode == 0


def output(**values):
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a") as out:
            out.writelines(f"{key}={value}\n" for key, value in values.items())


def apply_ja():
    result = subprocess.run([sys.executable, str(KIT / "apply_ja.py"), "--allow-missing"], cwd=ROOT, text=True, capture_output=True)
    print(result.stdout, result.stderr)
    assert result.returncode == 0, "apply_ja failed"
    return [line.removeprefix("MISSING ") for line in result.stdout.splitlines() if line.startswith("MISSING ")]


def selftest():
    assert ui_strings('Text("Clean now")\n// Text("No")\nlet x = "foo.bar"') == {"Clean now"}
    assert mole_strings('echo -e "${GREEN}Nothing to clean today${NC}"\nFOO="Not a message here"') == {"Nothing to clean today"}
    assert version_key("1.65.0") < version_key("1.69.0") and version_key("1.9.0") < version_key("1.10.0")
    print("PASS")


def main():
    if "--selftest" in sys.argv:
        return selftest()
    if "--baseline" in sys.argv:
        KNOWN.write_text(json.dumps(current_strings(), ensure_ascii=False, indent=0) + "\n", encoding="utf-8")
        return print("baseline written")
    burrow, mole = merge_burrow(), update_mole()
    retry = not (burrow or mole)
    if retry and released((KIT / "VERSION").read_text().strip()):
        return output(changed="false")
    lost = parser_text_missing()
    known = json.loads(KNOWN.read_text(encoding="utf-8"))
    now = current_strings()
    version = (KIT / "VERSION").read_text().strip() if retry else next_version()
    (KIT / "VERSION").write_text(version + "\n")
    missing = apply_ja()
    new_ui = sorted(set(now["ui"]) - set(known["ui"]))
    new_mole = sorted(set(now["mole"]) - set(known["mole"]))
    KNOWN.write_text(json.dumps(now, ensure_ascii=False, indent=0) + "\n", encoding="utf-8")
    lines = [f"Burrow {(ROOT / 'VERSION').read_text().strip()} / Mole {(VENDOR / 'VERSION').read_text().strip()}", ""]
    for title, rows in (("当たらなくなった対訳", missing), ("新しいアプリの文字列", new_ui), ("新しい Mole の文字列", new_mole)):
        if rows:
            lines += [f"## {title}（{len(rows)} 件）", "", "```", *rows, "```", ""]
    REPORT.write_text("\n".join(lines), encoding="utf-8")
    output(changed="true", version=version, untranslated=str(len(missing) + len(new_ui) + len(new_mole)))
    if lost:
        print("Parser text gone from Mole:", lost)
        sys.exit(2)


if __name__ == "__main__":
    main()

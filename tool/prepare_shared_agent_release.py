#!/usr/bin/env python3
"""Prepare reviewable pub.dev candidates; never upload or mutate workspace specs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

VERSIONS = {
    "ianvs_agent_core": "0.1.0",
    "ianvs_mermaid": "0.1.0",
    "ianvs_acp_runtime": "0.2.0",
    "ianvs_agent_chat": "0.3.1",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="new directory (default: temporary directory)")
    parser.add_argument("--package", action="append", choices=VERSIONS,
                        help="prepare only selected packages (repeatable; default: all)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if args.output:
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=False)
    else:
        output = Path(tempfile.mkdtemp(prefix="ianvs-shared-release-"))
    manifest = {"sourceIncludesWorkingTree": True, "baseCommit": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(), "packages": {}}
    for name, version in VERSIONS.items():
        if args.package and name not in args.package:
            continue
        prefix = Path("packages") / name
        listed = subprocess.check_output(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", str(prefix)], cwd=root)
        target = output / name
        for raw in listed.decode().split("\0"):
            if not raw:
                continue
            source = root / raw
            if not source.is_file() or source.name == "pubspec.lock":
                continue
            relative = Path(raw).relative_to(prefix)
            if relative.parts[:3] == ("test", "ui", "failures"):
                continue
            destination = target / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        pubspec = target / "pubspec.yaml"
        text = pubspec.read_text()
        text = re.sub(r"^version: .*", f"version: {version}", text, flags=re.M)
        text = text.replace("publish_to: none\n", "")
        text = text.replace("  ianvs_agent_core:\n    path: ../ianvs_agent_core\n",
                            "  ianvs_agent_core: ^0.1.0\n")
        pubspec.write_text(text)
        changelog = target / "CHANGELOG.md"
        if changelog.exists():
            changelog.write_text(changelog.read_text().replace("## Unreleased", f"## {version}", 1))
        # Examples remain local package consumers; no path dependency is retained
        # in the published library's dependency declarations.
        files = {str(p.relative_to(target)): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in sorted(target.rglob("*")) if p.is_file()}
        manifest["packages"][name] = {"version": version, "files": files}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(output)


if __name__ == "__main__":
    main()

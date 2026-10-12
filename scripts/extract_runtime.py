#!/usr/bin/env python3
"""Extract the installer's literal Docker build files without executing it."""

import argparse
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_FILES = {
    ".dockerignore",
    "Dockerfile",
    "healthcheck.sh",
    "monitor.sh",
    "parse-player.py",
}
HEREDOC = re.compile(
    r'^cat > "\$INSTALL_DIR/([^"\n]+)" <<\'EOF\'\n(.*?)^EOF$',
    re.MULTILINE | re.DOTALL,
)


def read_runtime(installer=ROOT / "geogoogle.sh"):
    artifacts = {}
    for match in HEREDOC.finditer(Path(installer).read_text(encoding="utf-8")):
        name, content = match.groups()
        if name not in RUNTIME_FILES or name in artifacts:
            raise ValueError(f"Unexpected or repeated embedded file: {name}")
        artifacts[name] = content
    missing = RUNTIME_FILES - artifacts.keys()
    if missing:
        raise ValueError(f"Missing embedded files: {', '.join(sorted(missing))}")
    return artifacts


def write_runtime(destination, installer=ROOT / "geogoogle.sh"):
    artifacts = read_runtime(installer)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    for name, content in artifacts.items():
        (destination / name).write_text(content, encoding="utf-8")
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--installer", type=Path, default=ROOT / "geogoogle.sh")
    args = parser.parse_args()
    write_runtime(args.destination, args.installer)


if __name__ == "__main__":
    main()

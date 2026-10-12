#!/usr/bin/env python3
"""Run offline syntax, lint and runtime checks. Requires Bash and ShellCheck."""

import shutil
import subprocess
import sys
import tempfile

from extract_runtime import ROOT, write_runtime


def main():
    for command in ("bash", "shellcheck"):
        if shutil.which(command) is None:
            raise SystemExit(f"Required command is missing: {command}")
    with tempfile.TemporaryDirectory(prefix="geogoogle-check-") as directory:
        runtime = write_runtime(directory)
        shell_files = [ROOT / "geogoogle.sh", runtime / "monitor.sh", runtime / "healthcheck.sh"]
        for path in shell_files:
            subprocess.run(["bash", "-n", str(path)], check=True)
        subprocess.run(["shellcheck", "--shell=bash", *map(str, shell_files)], check=True)
        python_files = [runtime / "parse-player.py", *sorted((ROOT / "scripts").glob("*.py")),
                        *sorted((ROOT / "tests").glob("*.py"))]
        for path in python_files:
            compile(path.read_text(encoding="utf-8"), str(path), "exec")
        subprocess.run(
            [sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests", "-v"],
            cwd=ROOT,
            check=True,
        )
    print("Syntax, ShellCheck and offline runtime checks passed.", flush=True)


if __name__ == "__main__":
    main()

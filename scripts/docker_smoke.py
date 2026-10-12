#!/usr/bin/env python3
"""Build the embedded image and test Docker health with all networking disabled."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

from extract_runtime import write_runtime


def docker(*arguments, check=True, timeout=120):
    return subprocess.run(
        ["docker", *map(str, arguments)], check=check, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
    )


def wait_health(container, expected, timeout=60):
    deadline = time.monotonic() + timeout
    state = {}
    while time.monotonic() < deadline:
        state = json.loads(docker("inspect", container).stdout)[0]["State"]
        if not state["Running"]:
            raise RuntimeError(f"Container exited: {state}")
        if state.get("Health", {}).get("Status") == expected:
            return
        time.sleep(1)
    raise RuntimeError(f"Expected health {expected}: {state}")


def main():
    if shutil.which("docker") is None:
        raise SystemExit("Docker is required; this smoke test was not run.")
    docker("info")
    suffix = uuid.uuid4().hex[:12]
    image = f"geogoogle-ci:{suffix}"
    container = f"geogoogle-ci-{suffix}"
    try:
        with tempfile.TemporaryDirectory(prefix="geogoogle-docker-") as directory:
            runtime = write_runtime(directory)
            config = Path(directory) / "config.sh"
            config.write_text("BOT_TOKEN=ci-placeholder\nCHAT_ID=0\nNODE_NAME=ci-offline\n", encoding="utf-8")
            # Only dummy values: container UID 0 has no DAC override after
            # --cap-drop ALL, and the CI runner owns this host file.
            os.chmod(config, 0o644)
            build = docker("build", "--pull", "-t", image, runtime, check=False, timeout=600)
            if build.returncode:
                raise RuntimeError(build.stdout + build.stderr)
            docker(
                "run", "-d", "--name", container, "--init", "--network", "none",
                "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m",
                "--health-interval=1s", "--health-start-period=1s", "--health-retries=1",
                "--mount", f"type=bind,src={config},dst=/run/geogoogle-config.sh,readonly",
                image,
            )
            wait_health(container, "healthy")
            print("Container is healthy with a read-only filesystem and networking disabled.", flush=True)
            # Freeze only the monitored process, so it cannot replace our test heartbeat.
            corruption = docker("exec", container, "/bin/bash", "-c", """
set -euo pipefail
read -r monitor_pid _ < /tmp/geogoogle-health
kill -STOP "$monitor_pid"
read -r uptime _ < /proc/uptime
if [ "${uptime%%.*}" -gt 301 ]; then
    printf '%s %s\n' "$monitor_pid" "$(( ${uptime%%.*} - 301 ))" > /tmp/geogoogle-health
    printf 'stale heartbeat\n'
else
    rm /tmp/geogoogle-health
    printf 'missing heartbeat (host uptime below 302 seconds)\n'
fi
""")
            wait_health(container, "unhealthy", timeout=30)
            print(f"Docker detected {corruption.stdout.strip()} and reported unhealthy.", flush=True)
    except (RuntimeError, subprocess.SubprocessError) as error:
        logs = docker("logs", container, check=False)
        if logs.stdout or logs.stderr:
            print(logs.stdout + logs.stderr, flush=True)
        raise SystemExit(str(error)) from error
    finally:
        docker("rm", "-f", container, check=False)
        docker("image", "rm", image, check=False)


if __name__ == "__main__":
    main()

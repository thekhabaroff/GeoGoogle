"""Offline behavioral tests against code extracted from geogoogle.sh itself."""

import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from extract_runtime import read_runtime  # noqa: E402


RUNTIME = read_runtime()
MONITOR = RUNTIME["monitor.sh"]
FUNCTIONS = MONITOR[MONITOR.index("log() {"):MONITOR.index('log "Мониторинг ноды ')]


def run_shell(code):
    return subprocess.run(["bash", "-c", code], capture_output=True, text=True, timeout=5)


class PlayerTests(unittest.TestCase):
    def parse(self, html):
        result = subprocess.run(
            [sys.executable, "-c", RUNTIME["parse-player.py"]], input=html,
            text=True, capture_output=True, check=True, timeout=5,
        )
        return result.stdout.strip()

    def player(self, status="OK", placements=None, assignment="ytInitialPlayerResponse = "):
        value = {"playabilityStatus": {"status": status}}
        if placements is not None:
            value["adPlacements"] = placements
        closing = "}" if assignment.startswith("var config = {") else ""
        return "<script>" + assignment + json.dumps(value) + closing + ";</script>"

    def test_nonempty_placements_on_playable_video_confirm_ads(self):
        for assignment in ("ytInitialPlayerResponse = ", 'window["ytInitialPlayerResponse"] = ',
                           'var config = {"ytInitialPlayerResponse": '):
            with self.subTest(assignment=assignment):
                self.assertEqual(self.parse(self.player(placements=[{"ad": {}}], assignment=assignment)), "ADS")

    def test_empty_or_absent_placements_on_playable_video_mean_no_ads(self):
        self.assertEqual(self.parse(self.player(placements=[])), "NOADS")
        self.assertEqual(self.parse(self.player()), "NOADS")

    def test_unplayable_or_malformed_responses_are_unknown(self):
        for html in ("", "consent required", "<script>ytInitialPlayerResponse = {broken;</script>",
                     self.player("LOGIN_REQUIRED", [{"ad": {}}]), self.player(placements="invalid")):
            with self.subTest(html=html):
                self.assertEqual(self.parse(html), "UNKNOWN")

    def test_ads_take_priority_over_a_second_playable_response(self):
        self.assertEqual(self.parse(self.player(placements=[]) + self.player(placements=[{}])), "ADS")

    def test_text_outside_script_is_not_treated_as_a_player(self):
        self.assertEqual(self.parse('ytInitialPlayerResponse = {"adPlacements":[{}]}'), "UNKNOWN")


class ScheduleTests(unittest.TestCase):
    def test_next_hour_always_advances_to_the_next_boundary(self):
        result = run_shell(FUNCTIONS + "\nfor now in 0 3599 3600 86399 86400; do next_hour \"$now\"; printf '\\n'; done")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["3600", "3600", "7200", "86400", "90000"])

    def schedule(self, epochs):
        with tempfile.TemporaryDirectory() as directory:
            clock = Path(directory) / "clock"
            sleeps = Path(directory) / "sleeps"
            clock.write_text("".join(f"{epoch}\n" for epoch in epochs), encoding="utf-8")
            result = run_shell(f"""
CLOCK_FILE={shlex.quote(str(clock))}
date() {{
    if [ "$1" = +%s ]; then
        IFS= read -r epoch < "$CLOCK_FILE" || exit 2
        sed '1d' "$CLOCK_FILE" > "$CLOCK_FILE.tmp"
        mv "$CLOCK_FILE.tmp" "$CLOCK_FILE"
        printf '%s\\n' "$epoch"
    else
        printf 'test-time\\n'
    fi
}}
""" + FUNCTIONS + f"""
SLEEPS={shlex.quote(str(sleeps))}
SLEEP_PID=""
update_health() {{ :; }}
sleep() {{ printf '%s\\n' "$1" >> "$SLEEPS"; }}
wait_for_hour
printf '%s\\n' "$NEXT_RUN"
""")
            self.assertEqual(result.returncode, 0, result.stderr)
            delays = [int(value) for value in sleeps.read_text().splitlines()] if sleeps.exists() else []
            self.assertTrue(all(0 < delay <= 30 for delay in delays), delays)
            return result.stdout.splitlines()[-1]

    def test_normal_wait_reaches_boundary_without_drift(self):
        self.assertEqual(self.schedule([3500, 3500, 3530, 3560, 3590, 3600]), "3600")

    def test_resume_during_first_minute_uses_current_hour(self):
        self.assertEqual(self.schedule([3500, 3630, 3630]), "3600")

    def test_late_resume_skips_the_missed_hour(self):
        self.assertEqual(self.schedule([3500, 3720, 3720, 7200]), "7200")

    def test_clock_moving_back_recalculates_the_boundary(self):
        self.assertEqual(self.schedule([3650, 3700, 3500, 3600]), "3600")


class NotificationTests(unittest.TestCase):
    def monitor(self, region, ads, runs=1):
        regions = list(region) if isinstance(region, (list, tuple)) else [region] * runs
        ad_results = list(ads) if isinstance(ads, (list, tuple)) else [ads] * len(regions)
        if len(ad_results) != len(regions):
            raise AssertionError("region and ad result sequences must have equal length")
        region_args = " ".join(shlex.quote(value) for value in regions)
        ad_args = " ".join(shlex.quote(value) for value in ad_results)
        result = run_shell(FUNCTIONS + f"""
NODE_NAME=ci-node
LAST_REGION=""
REGION_STATE_FILE=$(mktemp)
REGIONS=({region_args})
AD_RESULTS=({ad_args})
init_dns() {{ :; }}
get_region() {{ printf '%s' "${{REGIONS[$iteration]}}"; }}
check_ads() {{ printf 'AD_CHECK\\n' >&2; printf '%s' "${{AD_RESULTS[$iteration]}}"; }}
curl_dns() {{ printf '192.0.2.1'; }}
send_telegram() {{ printf 'SENT:%s\\n' "$1"; }}
for (( iteration=0; iteration<${{#REGIONS[@]}}; iteration++ )); do monitor_once; done
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_confirmed_ad_region_notifies_only_when_region_changes(self):
        result = self.monitor(("US", "US", "FI", "FI"), "ADS")
        self.assertEqual(result.stdout.count("SENT:"), 2)
        self.assertEqual(result.stderr.count("AD_CHECK"), 4)
        self.assertIn("ci-node (192.0.2.1)", result.stdout)
        self.assertIn("YouTube определяет регион: US.", result.stdout)
        self.assertIn("YouTube определяет регион: FI.", result.stdout)

    def test_previously_listed_regions_check_ads_and_notify_only_once(self):
        for region in (
            "RU", "BY", "AL", "MD", "AD", "MC", "MN", "KH", "LA", "MM", "MO",
            "MV", "BS", "MG", "CI", "IR", "SY", "CU", "KP", "SD", "AF",
        ):
            with self.subTest(region=region):
                result = self.monitor((region, region), "ADS")
                self.assertEqual(result.stdout.count("SENT:"), 1)
                self.assertEqual(result.stderr.count("AD_CHECK"), 2)

    def test_region_change_notifies_even_without_confirmed_ads(self):
        scenarios = (
            (("FI", "RU"), ("ADS", "NOADS"), "В плеере видео рекламные блоки adPlacements не обнаружены."),
            (("FI", "RU"), ("ADS", "UNKNOWN"), "Проверить рекламные блоки adPlacements не удалось: плеер недоступен."),
            (("RU",), ("NOADS",), "В плеере видео рекламные блоки adPlacements не обнаружены."),
            (("MD",), ("UNKNOWN",), "Проверить рекламные блоки adPlacements не удалось: плеер недоступен."),
        )
        for regions, ad_results, expected_status in scenarios:
            with self.subTest(regions=regions, ads=ad_results):
                result = self.monitor(regions, ad_results)
                self.assertEqual(result.stdout.count("SENT:"), len(regions))
                self.assertIn(expected_status, result.stdout)

    def test_same_region_does_not_notify_again_when_ad_status_changes(self):
        result = self.monitor(("US", "US"), ("NOADS", "ADS"))
        self.assertEqual(result.stdout.count("SENT:"), 1)
        self.assertIn("Регион YouTube: US не изменился; уведомление не отправлено.", result.stdout)

    def test_missing_region_does_not_notify(self):
        result = self.monitor(("",), "ADS")
        self.assertNotIn("SENT:", result.stdout)


class HealthTests(unittest.TestCase):
    def health(self, heartbeat, pid="$$"):
        with tempfile.TemporaryDirectory() as directory:
            health = Path(directory) / "health"
            uptime = Path(directory) / "uptime"
            uptime.write_text("1000.00 0.00\n", encoding="utf-8")
            code = RUNTIME["healthcheck.sh"].replace("/tmp/geogoogle-health", str(health)).replace("/proc/uptime", str(uptime))
            prefix = f"printf '%s %s\\n' {pid} {shlex.quote(heartbeat)} > {shlex.quote(str(health))}\n"
            return run_shell(prefix + code).returncode

    def test_live_process_and_recent_heartbeat_are_healthy(self):
        self.assertEqual(self.health("1000"), 0)
        self.assertEqual(self.health("700"), 0)

    def test_stale_future_or_invalid_heartbeats_are_unhealthy(self):
        for heartbeat in ("699", "1001", "invalid"):
            with self.subTest(heartbeat=heartbeat):
                self.assertNotEqual(self.health(heartbeat), 0)

    def test_missing_process_is_unhealthy(self):
        self.assertNotEqual(self.health("1000", pid="999999999"), 0)


if __name__ == "__main__":
    unittest.main()

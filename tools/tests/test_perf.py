# SPDX-License-Identifier: GPL-3.0-or-later
"""pp perf --analyze on a synthetic run directory: the log lines it parses
(metal-HUD, [xp], [xp-t], [thr-name], [CB_SUMMARY], DXMT's Present), the
budget and thermal syslog files, and the tables it writes. The expected
values are worked out by hand from the lines below."""

import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import perf  # noqa: E402

NONCE = "abcd1234"


def hms(s):
    return "12:00:%06.3f" % s


def counter(k):
    """The HUD's frame counter at second k: 120 fps for 10 s, then 60 fps."""
    return 1000 + 120 * k if k <= 10 else 2200 + 60 * (k - 10)


class Analyze(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.d, "run", "pull"))
        with open(os.path.join(self.d, "run", "events.jsonl"), "w") as f:
            f.write(json.dumps({"event": "lock"}) + "\n")
            f.write(json.dumps({"event": "launched", "pid": 7, "nonce": NONCE}) + "\n")

    def tearDown(self):
        shutil.rmtree(self.d)

    def write(self, name, lines):
        with open(os.path.join(self.d, name), "w") as f:
            f.write("\n".join(lines) + "\n")

    def test_hud_run(self):
        log = ["ui: launch nonce=older",   # an earlier launch: not this run's
               "11:00:00.000 S1Probe[1:2] metal-HUD: 5,1.0,1.0,99.0,99.0",
               f"ui: launch nonce={NONCE}",
               '[thr-name] ml810 tid=0a1c teb=0x1 name="render"']
        for k in range(25):
            pairs = "60.0,5.0,8.3,4.0" if k == 12 else "8.3,4.0,8.3,4.0"
            log.append(f"{hms(k)} S1Probe[1:2] metal-HUD: {counter(k)},512.0,300.0,{pairs}")
            log.append(f"[xp] {hms(k + 0.5)} w dt=1000 cpu=800 (thr 4.0) P=600 E=200 run=5 pgw=1.0 GHz "
                       f"P=3.20 E=2.10 Minst=5000 IPC=1.5 mJ=2000")
            log.append(f"[xp-t] {hms(k + 0.5)} m101:500.0/100.0:3.2/2.1:4000 -0a1c:100.0/100.0:3.2/2.1:1000")
            if k in (2, 3):   # FEX compiled 500 blocks between these two summaries
                log.append(f"E 78 [CB_SUMMARY] total=16384 real_compiles={100 if k == 2 else 600} cache_hits=1")
        self.write("run/pull/s1-host.log", log)
        self.write("budget.txt", ["2026-09-25 12:00:12.000 kernel[0] <Notice>: Budget Trace: clientId 0, "
                                  "Requested Budget 9000, Granted Budget 6000, Thermal Budget 6000"])
        self.write("thermal.txt", ["2026-09-25 12:00:16.000 thermalmonitord[9] <Notice> Thermal pressure level 20"])

        s = perf.analyze(self.d, echo=False)

        # Buckets of 5 s: 120, 120, (2440-2080)/5 = 72, 60, 60 fps; the first is start-up.
        self.assertEqual(s["buckets"], 5)
        self.assertEqual((s["fps_min"], s["fps_median"], s["share_at_120"]), (60.0, 72.0, 0.25))
        self.assertEqual(s["first_drop_s"], 10)
        self.assertEqual((s["budget_start_mw"], s["budget_min_mw"]), (6000, 6000))
        self.assertEqual((s["first_pressure_s"], s["max_pressure"]), (15, 20))
        self.assertEqual(s["hitches"], {25: 1, 50: 1, 100: 0})
        with open(os.path.join(self.d, "summary.json")) as f:
            full = json.load(f)
        rows = full["rows"]
        self.assertEqual([r["fps"] for r in rows], [120.0, 120.0, 72.0, 60.0, 60.0])
        r0, r2 = rows[0], rows[2]
        self.assertEqual((r0["cpu_pct"], r0["p_pct"], r0["e_pct"], r0["mw"]), (80, 60, 20, 2000))
        self.assertEqual((r0["p_ghz"], r0["e_ghz"], r0["app_mib"]), (3.2, 2.1, 300.0))
        self.assertEqual(r0["jit_ps"], 100)
        self.assertEqual((r2["slow_frames"], r2["ft_max"], r2["budget_mw"]), (1, 60.0, 6000))
        self.assertIsNone(rows[2]["tpl"])
        self.assertEqual(rows[3]["tpl"], 20)
        # The 60 ms frame ends 8.3 ms before its line at 12 s.
        self.assertEqual([(h["t"], h["ms"]) for h in full["hitches"]], [(11.99, 60.0)])
        # Threads, per 15 s: m101 did 60000 Mi over 1440 frames, 60% of a core.
        top = full["threads"][0]["top"]
        self.assertEqual((top[0]["thread"], top[0]["cpu_pct"], top[0]["minst_per_frame"]), ("m101", 60, 41.67))
        self.assertEqual((top[1]["thread"], top[1]["name"]), ("0a1c", "render"))
        for f in ("summary.txt", "threads.txt", "hitches.txt", "this-launch.log"):
            self.assertTrue(os.path.exists(os.path.join(self.d, f)), f)
        with open(os.path.join(self.d, "this-launch.log")) as f:
            self.assertNotIn("nonce=older", f.read())

    def test_server_census(self):
        """madeira-unix 0037's [srv] and [srv-t] lines: requests per frame by kind
        and type over the played buckets, and the busiest thread's share."""
        log = [f"ui: launch nonce={NONCE}", '[thr-name] ml810 tid=0024 teb=0x1 name="main"']
        for k in range(21):   # 60 fps
            log.append(f"{hms(k)} S1Probe[1:2] metal-HUD: {1000 + 60 * k},512.0,300.0,16.6,4.0")
            # m101 (no Windows TID) retires the most, then 0024: the busiest Windows thread
            log.append(f"[xp-t] {hms(k + 0.5)} m101:500.0/0.0:3.2/0.0:9000 -0024:400.0/0.0:3.2/0.0:4000 "
                       f"-0030:10.0/0.0:3.2/0.0:10")
            log.append(f"[srv] {hms(k + 0.5)} dt=1000 req=120 sel=60 ev=30 mtx=0 sem=12 hdl=6 msg=0 oth=12 "
                       f"rt=6.0 blk=100.0 nblk=30 | select=60 event_op=30 release_semaphore=12 close_handle=6 req77=12")
            log.append(f"[srv-t] {hms(k + 0.5)} -0030:30/15/0/6/6/0/3:4.00/90.0/24 -0024:30/15/0/6/0/0/9:3.00/10.0/6")
        self.write("run/pull/s1-host.log", log)

        s = perf.analyze(self.d, echo=False)

        # Played buckets (5-10, 10-15, 15-20 and the 1 s from 19 to 20): 960
        # frames and 16 [srv] lines of 120 requests, 6 ms round trip, 100 ms blocked.
        srv = s["server"]
        self.assertEqual((srv["frames"], srv["secs"], srv["req_per_frame"]), (960, 16.0, 2.0))
        self.assertEqual(srv["by_kind"], {"sel": 1.0, "ev": 0.5, "mtx": 0.0, "sem": 0.2, "hdl": 0.1,
                                          "msg": 0.0, "oth": 0.2})
        self.assertEqual((srv["rt_ms_per_frame"], srv["blk_ms_per_frame"]), (0.1, 1.667))
        self.assertEqual(list(srv["types_per_frame"].items())[:3],
                         [("select", 1.0), ("event_op", 0.5), ("release_semaphore", 0.2)])
        self.assertEqual(srv["blocked_per_frame"], 0.5)
        main = srv["busiest"]
        self.assertEqual((main["thread"], main["name"], main["req_per_frame"]), ("0024", "main", 1.0))
        self.assertEqual((main["rt_ms_per_frame"], main["rt_pct"], main["blk_pct"]), (0.05, 0.3, 1.0))
        self.assertEqual(main["blocked_per_frame"], 0.1)
        with open(os.path.join(self.d, "summary.json")) as f:
            full = json.load(f)
        self.assertEqual([r["srv_pf"] for r in full["rows"]][1:4], [2.0, 2.0, 2.0])
        with open(os.path.join(self.d, "server.txt")) as f:
            text = f.read()
        self.assertIn("types/f: select", text)
        # by round-trip time, 0030 first; 0024 retired the most instructions (*)
        self.assertEqual([x["thread"] for x in full["server"][0]["top"]], ["0030", "0024"])
        self.assertEqual(full["server"][0]["busiest"], "0024")
        self.assertIn("*     0024 main", text)

    def test_cpms_budgets_and_system_power(self):
        """iOS 27's per-client CPMS budget lines and the battery gauge's
        power telemetry (power.txt)."""
        log = [f"ui: launch nonce={NONCE}"]
        for k in range(11):
            log.append(f"{hms(k)} S1Probe[1:2] metal-HUD: {1000 + 120 * k},512.0,300.0,8.3,4.0")
        self.write("run/pull/s1-host.log", log)
        cpms = "kernel{ApplePPMCPMS}[0] <NOTICE>: ApplePPMPolicyCPMS::setDetailedThermalPowerBudget:" \
               "setDetailedThermalPowerBudget: clientId %d, details %d, Thermal Budget %d"
        self.write("budget.txt", [f"2026-09-26 {hms(6)} " + cpms % (7, 1, 3400),
                                  f"2026-09-26 {hms(6.1)} " + cpms % (7, 2, 3300),
                                  f"2026-09-26 {hms(6.2)} " + cpms % (9, 0, 1900),
                                  f"2026-09-26 {hms(7)} " + cpms % (9, 0, 1800)])
        self.write("power.txt", [f"{hms(1)} " + json.dumps({"SystemLoad": 4000, "InstantAmperage": 1,
                                                             "CurrentCapacity": 64, "ExternalConnected": False}),
                                 f"{hms(3)} " + json.dumps({"SystemLoad": 5000, "InstantAmperage": -3}),
                                 f"{hms(6)} " + json.dumps({"SystemLoad": 6000, "InstantAmperage": 0,
                                                             "CurrentCapacity": 61, "ExternalConnected": False})])

        s = perf.analyze(self.d, echo=False)

        self.assertEqual((s["budget_start_mw"], s["budget_min_mw"], s["budget_first_s"]), (3400, 1800, 6))
        self.assertEqual(s["budget_clients"], {"7": 3300, "9": 1800})
        self.assertEqual((s["battery_start_pct"], s["battery_end_pct"], s["charger"]), (64, 61, False))
        with open(os.path.join(self.d, "summary.json")) as f:
            rows = json.load(f)["rows"]
        # the last bucket logged no budget line: each client holds its last value
        self.assertEqual([r["budget_mw"] for r in rows], [None, 1800, 1800])
        self.assertEqual(s["budget_clients_end"], {"7": 3300, "9": 1800})
        self.assertEqual([(r["sys_mw"], r["batt_ma"]) for r in rows], [(4500, -1), (6000, 0), (None, None)])

    def test_no_hud_run_counts_dxmt_presents(self):
        log = [f"ui: launch nonce={NONCE}"]
        for k in range(11):
            log.append(f"[xp] {hms(k + 0.5)} w dt=1000 cpu=800 (thr 4.0) P=600 E=200 run=5 pgw=1.0 GHz "
                       f"P=3.20 E=2.10 Minst=5000 IPC=1.5 mJ=2000")
            # one line per 16 presents, t= on the host's monotonic clock
            log.append(f"[iOS DXMT] Present #{16 * (k + 1)} t={100 + k + 0.5:.3f} after=0.0 (machexc_delta=10)")
        self.write("run/pull/s1-host.log", log)
        perf.analyze(self.d, echo=False)
        with open(os.path.join(self.d, "summary.json")) as f:
            rows = json.load(f)["rows"]
        # 16 presents a second; 10 mach exceptions a second; no frame times without the HUD.
        self.assertEqual(rows[0]["fps"], 16.0)
        self.assertEqual(rows[0]["mexc_ps"], 10)
        self.assertIsNone(rows[0]["ft_avg"])

    def gap_run(self, rate):
        """One HUD line a second, at rate(k) fps for second k (None: no line, a load)."""
        log = [f"ui: launch nonce={NONCE}"]
        n = 1000
        for k in range(40):
            if rate(k) is None:
                continue
            n += rate(k)
            log.append(f"{hms(k)} S1Probe[1:2] metal-HUD: {n},512.0,300.0,{1000 / rate(k):.2f},4.0")
        return self.analyzed(log)

    def analyzed(self, log):
        self.write("run/pull/s1-host.log", log)
        s = perf.analyze(self.d, echo=False)
        with open(os.path.join(self.d, "summary.json")) as f:
            return s, json.load(f)["rows"]

    def test_load_gap_does_not_end_the_table(self):
        # 120 fps for 0-9 s, nothing presented 10-19 s (a scene load), 120 fps again 20-29 s
        s, rows = self.gap_run(lambda k: None if 10 <= k < 20 or k >= 30 else 120)
        self.assertEqual([r["fps"] for r in rows], [120.0, 120.0, 0.0, 0.0, 120.0, 120.0])
        self.assertIsNone(rows[2]["app_mib"])
        # the load is not play: the bucket after it counts only its own frames
        self.assertIsNone(s["first_drop_s"])
        self.assertEqual((s["fps_min"], s["share_at_120"]), (120.0, 1.0))

    def test_load_gap_inside_buckets(self):
        # a load from 11 to 18 s leaves no bucket frameless
        s, rows = self.gap_run(lambda k: None if 11 < k < 18 or k >= 30 else 120)
        self.assertEqual([r["fps"] for r in rows], [120.0] * 6)
        self.assertIsNone(s["first_drop_s"])
        self.assertEqual((s["fps_min"], s["share_at_120"]), (120.0, 1.0))

    def test_drop_after_load(self):
        # 120 fps, a load at 10-19 s, 120 fps again, then 60 fps from 25 s on
        s, rows = self.gap_run(lambda k: None if 10 <= k < 20 else 120 if k < 25 else 60)
        self.assertEqual([r["fps"] for r in rows], [120.0, 120.0, 0.0, 0.0, 120.0, 60.0, 60.0, 60.0])
        self.assertEqual(s["first_drop_s"], 25)
        self.assertEqual((s["fps_min"], s["share_at_120"]), (60.0, 0.4))

    def test_slow_play_is_not_a_load(self):
        # below 100 fps the HUD's 100-frame lines come more than LOAD_GAP_S apart:
        # 120 fps for 60 s, 45 fps for 60 s, 120 fps for 60 s
        log, t, n = [f"ui: launch nonce={NONCE}"], 0.0, 1000
        for fps, secs in ((120, 60), (45, 60), (120, 60)):
            for _ in range(round(secs * fps / 100)):
                t += 100 / fps
                n += 100
                log.append(f"{hms(t)} S1Probe[1:2] metal-HUD: {n},512.0,300.0,{1000 / fps:.2f},4.0")
        s, rows = self.analyzed(log)
        self.assertEqual(s["first_drop_s"], 60)
        self.assertEqual(s["fps_min"], 45.0)
        self.assertLess(s["share_at_120"], 0.7)

    def test_when_of(self):
        self.assertEqual(perf.when_of("25"), (False, 25))
        self.assertEqual(perf.when_of("first-frame+25"), (True, 25))
        self.assertIsNone(perf.when_of("soon"))



class Compare(unittest.TestCase):
    """pp perf --compare on two finished runs: summary.json rows, run.json or the
    play's launched event, and the result line's timeline."""

    def run_dir(self, name, fps, settings, run_json=True):
        d = os.path.join(self.root, name)
        os.makedirs(os.path.join(d, "run"))
        rows = [{"t": 5 * i, "fps": f, "live_s": 5.0, "ft_avg": round(1000 / f, 2), "gpu_avg": 4.0}
                for i, f in enumerate(fps)]
        with open(os.path.join(d, "summary.json"), "w") as f:
            json.dump({"summary": {"fps_median": 0, "thermal_start": "nominal", "battery_start_pct": 80,
                                   "battery_end_pct": 78, "charger": False}, "rows": rows}, f)
        with open(os.path.join(d, "events.jsonl"), "w") as f:
            f.write(json.dumps({"event": "result", "timeline": ["title: +9.50 s first frame"]}) + "\n")
        if run_json:
            with open(os.path.join(d, "run.json"), "w") as f:
                json.dump({"title": "app-1", "settings": json.dumps(settings)}, f)
        else:
            with open(os.path.join(d, "run", "events.jsonl"), "w") as f:
                f.write(json.dumps({"event": "launched", "env": ["UI_ACTIONS=settings:app-1,play:app-1",
                                                                  "UI_SETTINGS=" + json.dumps(settings)]}) + "\n")
        return d

    def setUp(self):
        self.root = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.root)

    def compared(self, dirs, **kw):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            perf.compare(dirs, **kw)
        return out.getvalue()

    def test_steady_means(self):
        rows = [{"fps": 120, "live_s": 5, "ft_avg": 8.33, "gpu_avg": 4.0},
                {"fps": 60, "live_s": 5, "ft_avg": 16.67, "gpu_avg": 8.0}]
        m = perf.steady_means(rows)
        self.assertEqual(m["fps_mean"], 90.0)
        # frame time weighted by frames: 600 frames at 8.33 ms, 300 at 16.67 ms
        self.assertAlmostEqual(m["ft_avg_ms"], 11.11, places=2)
        self.assertEqual(m["fps_p10"], 60)

    def test_compare_table_and_json(self):
        a = self.run_dir("a", [100, 120, 120, 120, 120, 120, 120, 60],
                         {"screen": "720", "environment": [{"name": "X", "value": "1"}]})
        b = self.run_dir("b", [100, 60, 60, 60, 60, 60, 60, 60], {"screen": "720"}, run_json=False)
        j = json.loads(self.compared([a, b], as_json=True))
        ra, rb = j["runs"]
        self.assertEqual((ra["title"], rb["title"]), ("app-1", "app-1"))
        self.assertEqual(ra["differs"], {"env.X": "1"})
        self.assertEqual(rb["differs"], {"env.X": None})
        self.assertEqual(ra["first_frame_s"], 9.5)
        self.assertEqual(ra["fps_mean"], 111.4)      # the first bucket is left out: 780 / 7
        self.assertEqual(j["windows"][0]["fps"], [116.7, 66.7])   # t 0-29: buckets 0-5
        self.assertIn("settings that differ", self.compared([a, b]))


if __name__ == "__main__":
    unittest.main()


class CoolState(unittest.TestCase):
    """--cool's pressure level: the follower's last one, unless it is older than the follower's hour."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.follow, perf.FOLLOW = perf.FOLLOW, os.path.join(self.d, "follow.log")
        with open(perf.FOLLOW, "w") as f:
            f.write("2026-09-29 23:44:00.000000 thermalmonitord{thermalmonitord}[71] <Notice> Thermal pressure level 10\n")

    def tearDown(self):
        perf.FOLLOW = self.follow
        shutil.rmtree(self.d)

    def test_follower_level_within_its_hour(self):
        import time
        self.assertEqual(perf.cool_state({}, time.time() - 600), 10)

    def test_level_older_than_the_follower_is_none(self):
        import time
        self.assertIsNone(perf.cool_state({}, time.time() - perf.FOLLOW_S - 60))

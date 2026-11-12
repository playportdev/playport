# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile the elastic-reservation policy shipped in madeira-unix 0289 (pp_elastic.h, PLA-801, decision
0180) and replay phone traces through it against a model of the guest window.

The model stands in for the Wine glue (PLA-802): it keeps the window's free ranges between the bottom of
the guest window and FEX's band at 0x7c00000000 (the holds and furniture of each run's [va-gaps] walk
outside them), places an ask as today (its logged address, else the lowest gap that fits; a WoW64
window its first free fixed slot from madeira-unix 0146's wow64_slots.h, else the lowest gap), and
performs what the module decides: whole placements, short grants with their guard, lends, growth,
refusals. The fixtures in fixtures/elastic/ name the runs they come from."""
import copy
import ctypes
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0289-ntdll-the-elastic-reservation-policy-pp_elastic.h.patch"
WINDOW_PATCH = ROOT / "patches/madeira-unix/0049-ntdll-reserve-an-owned-i386-address-window.patch"
SLOTS_PATCH = ROOT / "patches/madeira-unix/0146-ntdll-reserve-a-WoW64-window-in-a-fixed-slot-first.patch"
FIXTURES = ROOT / "tools/tests/fixtures/elastic"

MB = 1 << 20
GB = 1 << 30
GRAIN = 0x10000
GUARD = 32 * MB
LO, HI = 0x7000000000, 0x7C00000000   # the guest window; FEX's band above
WINDOW = HI - LO
CEILING = 0x73FFFF0000                 # ios_furniture_ceiling: the WoW64 window's slots count down from it

TODAY, FAIL, PLACE, SHORT, LEND = range(5)
SERVE, GROW, REFUSE = range(3)
FLAG = {"hint": 0x1, "align": 0x2, "placeholder": 0x4, "ex": 0x8, "limit": 0x10, "commit": 0x20,
        "held": 0x40, "layout": 0x80, "wow64": 0x100}
WHOLE = 0x1FF                         # PPE_ASK_WHOLE: never shrunk


def added_file(patch, path):
    """A file the patch creates, as it creates it."""
    section = patch.read_text().split(f"diff --git a/{path}", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


SHIM_C = r'''
#include "pp_elastic.h"
#include "wow64_slots.h"
#include <stdlib.h>
#include <string.h>

struct ppe_state *s_new( uint64_t window )
{ struct ppe_state *s = calloc( 1, sizeof(*s) ); ppe_init( s, window ); return s; }
struct ppe_state *s_clone( const struct ppe_state *o )
{ struct ppe_state *s = malloc( sizeof(*s) ); memcpy( s, o, sizeof(*s) ); return s; }
void s_free( struct ppe_state *s ) { free( s ); }
static int out( struct ppe_decision d, uint64_t *o )
{ o[0] = d.addr; o[1] = d.real; o[2] = d.keep; o[3] = (uint64_t)(int64_t)d.view; return d.kind; }
int s_before( struct ppe_state *s, uint64_t size, unsigned f, uint64_t limit, uint64_t align,
              const struct ppe_gap *g, unsigned n, uint64_t *o )
{ struct ppe_ask a = { size, f, limit, align }; return out( ppe_before( s, &a, g, n ), o ); }
int s_failed( struct ppe_state *s, uint64_t size, unsigned f, uint64_t limit, uint64_t align,
              const struct ppe_gap *g, unsigned n, uint64_t *o )
{ struct ppe_ask a = { size, f, limit, align }; return out( ppe_failed( s, &a, g, n ), o ); }
int s_placed( struct ppe_state *s, uint64_t b, uint64_t c, uint64_t r, unsigned f ) { return ppe_placed( s, b, c, r, f ); }
void s_lent( struct ppe_state *s, int i, uint64_t k ) { ppe_lent( s, i, k ); }
void s_released( struct ppe_state *s, uint64_t b ) { ppe_released( s, b ); }
int s_owner( struct ppe_state *s, uint64_t a, uint64_t vb ) { return ppe_owner( s, a, vb ); }
int s_commit( struct ppe_state *s, int i, uint64_t a, uint64_t n, uint64_t fa, uint64_t no, uint64_t *o )
{ struct ppe_commit_decision c = ppe_commit( s, i, a, n, fa, no ); o[0] = c.real; o[1] = c.blocker; return c.kind; }
void s_grown( struct ppe_state *s, int i, uint64_t r ) { ppe_grown( s, i, r ); }
void s_served( struct ppe_state *s, int i, uint64_t a, uint64_t n ) { ppe_served( s, i, a, n ); }
unsigned s_n( struct ppe_state *s ) { return s->n; }
void s_view( struct ppe_state *s, int i, uint64_t *o )
{ o[0] = s->v[i].base; o[1] = s->v[i].real; o[2] = s->v[i].guard; o[3] = s->v[i].claim; o[4] = s->v[i].high; }
void s_counts( struct ppe_state *s, unsigned *o )
{ o[0] = s->engaged; o[1] = s->lends; o[2] = s->shorts; o[3] = s->grows; o[4] = s->refusals; o[5] = s->shortened; }
uint64_t s_slot( uint64_t ceiling, uint64_t floor, unsigned k ) { return ios_wow64_slot_base( ceiling, floor, k ); }
'''

LIB = None


def lib():
    return LIB


def setUpModule():
    global LIB, _tmp
    cc = shutil.which("cc")
    if cc is None:
        raise unittest.SkipTest("no C compiler")
    scratch = ROOT / ".work" / "tmp"
    scratch.mkdir(parents=True, exist_ok=True)
    _tmp = tempfile.TemporaryDirectory(dir=scratch)
    d = pathlib.Path(_tmp.name)
    (d / "pp_elastic.h").write_text(added_file(PATCH, "build/ntdll-unix/pp_elastic.h"))
    (d / "wow64_window.h").write_text(added_file(WINDOW_PATCH, "build/ntdll-unix/wow64_window.h"))
    (d / "wow64_slots.h").write_text(added_file(SLOTS_PATCH, "build/ntdll-unix/wow64_slots.h"))
    (d / "shim.c").write_text(SHIM_C)
    subprocess.run([cc, "-std=gnu11", "-O1", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
                    "-o", str(d / "libppe.so"), str(d / "shim.c")], check=True)
    LIB = ctypes.CDLL(str(d / "libppe.so"))
    u64, p = ctypes.c_uint64, ctypes.c_void_p
    sig = {"s_new": (p, [u64]), "s_clone": (p, [p]), "s_free": (None, [p]),
           "s_before": (ctypes.c_int, [p, u64, ctypes.c_uint, u64, u64, p, ctypes.c_uint, p]),
           "s_failed": (ctypes.c_int, [p, u64, ctypes.c_uint, u64, u64, p, ctypes.c_uint, p]),
           "s_placed": (ctypes.c_int, [p, u64, u64, u64, ctypes.c_uint]),
           "s_lent": (None, [p, ctypes.c_int, u64]), "s_released": (None, [p, u64]),
           "s_owner": (ctypes.c_int, [p, u64, u64]),
           "s_commit": (ctypes.c_int, [p, ctypes.c_int, u64, u64, u64, u64, p]),
           "s_grown": (None, [p, ctypes.c_int, u64]), "s_served": (None, [p, ctypes.c_int, u64, u64]),
           "s_n": (ctypes.c_uint, [p]), "s_view": (None, [p, ctypes.c_int, p]), "s_counts": (None, [p, p]),
           "s_slot": (u64, [u64, u64, ctypes.c_uint])}
    for name, (res, args) in sig.items():
        fn = getattr(LIB, name)
        fn.restype, fn.argtypes = res, args


def tearDownModule():
    _tmp.cleanup()


def flags_of(names):
    f = 0
    for n in names:
        f |= FLAG[n]
    return f


class Space:
    """The guest window as the glue sees it, with the module's state beside it."""

    def __init__(self, free, elastic=True):
        self.occ = []                       # sorted [base, end, owner]
        cur = LO
        for b, e in sorted((int(b, 16), int(e, 16)) for b, e in free):
            if b > cur:
                self.occ.append([cur, b, "furniture"])
            cur = max(cur, e)
        if cur < HI:
            self.occ.append([cur, HI, "furniture"])
        self.elastic = elastic
        self.st = LIB.s_new(WINDOW) if elastic else None
        self.views = {}                     # id -> dict(base, span, claim, height)
        self.placements = {}                # id -> base or None
        self.landed_in_claim = []           # (id, earlier claim's base) for a view placed inside a claim
        self.wrong_view = []                # a commit served in a view not the pool's own
        self.refused = {}                   # id -> offset of the first refused commit
        self.served = 0

    def __deepcopy__(self, memo):
        new = copy.copy(self)
        new.occ = copy.deepcopy(self.occ)
        new.views = copy.deepcopy(self.views)
        new.placements = dict(self.placements)
        new.landed_in_claim = list(self.landed_in_claim)
        new.wrong_view = list(self.wrong_view)
        new.refused = dict(self.refused)
        new.st = LIB.s_clone(self.st) if self.st else None
        return new

    # -- the window
    def gaps(self):
        out, cur = [], LO
        for b, e, _ in self.occ:
            if b > cur:
                out.append((cur, b))
            cur = max(cur, e)
        if cur < HI:
            out.append((cur, HI))
        return out

    def is_free(self, b, size):
        return LO <= b and b + size <= HI and all(e <= b or s >= b + size for s, e, _ in self.occ)

    def occupy(self, b, size, owner):
        assert self.is_free(b, size), (hex(b), hex(size), owner)
        self.occ.append([b, b + size, owner])
        self.occ.sort()

    def vacate(self, b, e):
        """Return [b, e) of a view to the host."""
        out = []
        for s, t, o in self.occ:
            if t <= b or s >= e:
                out.append([s, t, o])
                continue
            if s < b:
                out.append([s, b, o])
            if t > e:
                out.append([e, t, o])
        self.occ = sorted(out)

    def owner_at(self, a):
        for s, e, o in self.occ:
            if s <= a < e:
                return s, o
        return None, None

    def fill(self):
        for b, e in self.gaps():
            self.occupy(b, e - b, "other")

    def today(self, size, at, limit=0, align=0):
        size = (size + GRAIN - 1) & ~(GRAIN - 1)
        if at is not None and self.is_free(at, size):
            return at
        step = max(align, GRAIN)
        for b, e in self.gaps():
            b = (b + step - 1) & ~(step - 1)
            if limit:
                e = min(e, limit)
            if e > b and e - b >= size:
                return b
        return None

    def window_today(self, size):
        """A WoW64 window placed as today (ios_wow64_reserve_window): its first free fixed slot below
        the furniture ceiling, else a first fit."""
        k = 0
        while base := LIB.s_slot(CEILING, LO, k):
            if self.is_free(base, size):
                return base
            k += 1
        return self.today(size, None)

    # -- the module
    def gap_array(self):
        g = self.gaps()
        arr = (ctypes.c_uint64 * (2 * max(len(g), 1)))()
        for k, (b, e) in enumerate(g):
            arr[2 * k], arr[2 * k + 1] = b, e - b
        return arr, len(g)

    def decide(self, fn, size, flags, limit=0, align=0):
        arr, n = self.gap_array()
        o = (ctypes.c_uint64 * 4)()
        kind = fn(self.st, size, flags, limit, align, arr, n, o)
        return kind, o[0], o[1], o[2], ctypes.c_int64(o[3]).value

    def mviews(self):
        out = []
        o = (ctypes.c_uint64 * 5)()
        for i in range(LIB.s_n(self.st)):
            LIB.s_view(self.st, i, o)
            out.append(dict(base=o[0], real=o[1], guard=o[2], claim=o[3], high=o[4]))
        return out

    def counts(self):
        o = (ctypes.c_uint * 6)()
        LIB.s_counts(self.st, o)
        return dict(zip(("engaged", "lends", "shorts", "grows", "refusals", "shortened"), o))

    def view_by_base(self, base):
        return next(k for k, v in self.views.items() if v["base"] == base)

    def map(self, vid, base, span, claim, flags):
        claims = [(v["base"], v["claim"]) for v in self.mviews() if v["real"] < v["claim"]] if self.st else []
        for cb, cl in claims:
            if base < cb + cl and base + span > cb:
                self.landed_in_claim.append((vid, cb))
        self.occupy(base, span, vid)
        self.views[vid] = dict(base=base, span=span, claim=claim, height=0, flags=flags)
        self.placements[vid] = base
        return base

    # -- the glue
    def reserve(self, vid, size, names, at=None, routed=None, limit=0, align=0):
        flags = flags_of(names)

        def today():
            return self.window_today(size) if flags & FLAG["wow64"] else self.today(size, at, limit, align)

        if names and "layout" in names:
            # The Social Club router decides first; the module, asked anyway, leaves it alone.
            if self.st:
                before = self.counts()["engaged"]
                assert self.decide(LIB.s_failed, size, flags)[0] == FAIL
                assert self.counts()["engaged"] == before
            if routed is None:
                self.placements[vid] = None
                return None
            if self.is_free(routed, size):
                self.occupy(routed, size, vid)
            self.views[vid] = dict(base=routed, span=size, claim=size, height=0, flags=flags)
            self.placements[vid] = routed
            return routed
        if not self.elastic:
            b = today()
            self.placements[vid] = b
            return None if b is None else self.map(vid, b, size, size, flags)
        kind, addr, real, keep, view = self.decide(LIB.s_before, size, flags, limit, align)
        assert kind in (TODAY, PLACE), "ppe_before lent or shortened before today's placement"
        if kind == TODAY:
            b = today()
            if b is not None:
                self.map(vid, b, size, size, flags)
                LIB.s_placed(self.st, b, size, size, flags)
                return b
            kind, addr, real, keep, view = self.decide(LIB.s_failed, size, flags, limit, align)
        for _ in range(4096):
            if kind == PLACE:
                assert not flags & WHOLE, "a never-shrunk ask placed by the module"
                self.map(vid, addr, size, size, flags)
                LIB.s_placed(self.st, addr, size, size, flags)
                return addr
            if kind == SHORT:
                assert not flags & WHOLE, "a never-shrunk ask shortened"
                assert size >= GB and real >= 64 * MB and real % GRAIN == 0
                self.map(vid, addr, real + GUARD, size, flags)
                LIB.s_placed(self.st, addr, size, real, flags)
                return addr
            if kind == LEND:
                lender = self.mviews()[view]
                did = self.view_by_base(lender["base"])
                span = self.views[did]["span"]
                assert keep < span and keep >= GUARD + 64 * MB
                self.vacate(lender["base"] + keep, lender["base"] + span)
                self.views[did]["span"] = keep
                LIB.s_lent(self.st, view, keep)
                if flags & WHOLE:
                    # A never-shrunk ask retries today's placement once, then fails.
                    b = today()
                    if b is not None:
                        self.map(vid, b, size, size, flags)
                        LIB.s_placed(self.st, b, size, size, flags)
                        return b
                    self.placements[vid] = None
                    return None
                kind, addr, real, keep, view = self.decide(LIB.s_failed, size, flags, limit, align)
                continue
            assert kind == FAIL
            self.placements[vid] = None
            return None
        raise AssertionError("the module kept lending")

    def release(self, vid):
        v = self.views.pop(vid)
        self.vacate(v["base"], v["base"] + v["span"])
        if self.st:
            LIB.s_released(self.st, v["base"])

    def commit_one(self, vid, off, size):
        """One commit of [off, off + size) of view vid's claim, as the glue serves it."""
        v = self.views[vid]
        a = v["base"] + off
        _, owner = self.owner_at(a)
        view_base = self.views[owner]["base"] if owner in self.views else 0
        i = LIB.s_owner(self.st, a, view_base) if self.st else -1
        if i < 0:
            if owner == vid and a + size <= v["base"] + v["span"]:
                self.served += 1
                return True
            if owner in self.views:
                self.wrong_view.append((vid, off, owner))
                return True
            return False
        mv = self.mviews()[i]
        mid = self.view_by_base(mv["base"])
        end = mv["base"] + mv["real"] + mv["guard"]
        nb, _ = min(((s, o) for s, e, o in self.occ if s >= end), default=(HI, None))
        free_above = max(0, min(nb, HI) - end)
        o = (ctypes.c_uint64 * 2)()
        kind = LIB.s_commit(self.st, i, a, size, free_above, min(nb, HI), o)
        if kind == REFUSE:
            return False
        if kind == GROW:
            grow = o[0] - mv["real"]
            assert grow <= free_above
            self.occupy(end, grow, mid)
            self.views[mid]["span"] += grow
            LIB.s_grown(self.st, i, o[0])
            mv = self.mviews()[i]
        if mid != vid:
            self.wrong_view.append((vid, off, mid))
        assert mv["base"] <= a and a + size <= mv["base"] + mv["real"], "served past the real view"
        LIB.s_served(self.st, i, a, size)
        self.served += 1
        return True

    def commit(self, vid, to, step=MB):
        v = self.views[vid]
        while v["height"] < to and vid not in self.refused:
            n = min(step, to - v["height"])
            if self.commit_one(vid, v["height"], n):
                v["height"] += n
            else:
                self.refused[vid] = v["height"]

    def depth(self, vid, limit=None):
        """How deep the pool commits before its first refusal, probed on a copy."""
        probe = copy.deepcopy(self)
        v = probe.views[vid]
        limit = min(limit or v["claim"], v["claim"])
        while v["height"] < limit:
            n = min(MB if v["height"] < 256 * MB else 64 * MB, limit - v["height"])
            if not probe.commit_one(vid, v["height"], n):
                break
            v["height"] += n
        if probe.st:
            LIB.s_free(probe.st)
        return v["height"]


def load(name):
    return json.loads((FIXTURES / name).read_text())


def replay(fx, elastic=True):
    sp = Space(fx["free"], elastic)
    for ev in fx["events"]:
        op = ev[0]
        if op == "reserve":
            _, vid, size, names, extra = ev
            at, routed = extra.get("at"), extra.get("routed")
            sp.reserve(vid, int(size, 16), names, int(at, 16) if at else None, int(routed, 16) if routed else None)
        elif op == "commit":
            if sp.placements.get(ev[1]) is not None and sp.elastic:
                sp.commit(ev[1], int(ev[2], 16))
        elif op == "occupy":
            sp.occupy(int(ev[1], 16), int(ev[2], 16), "other")
        elif op == "fill":
            sp.fill()
        elif op == "release":
            if sp.placements.get(ev[1]) is not None:
                sp.release(ev[1])
        else:
            raise AssertionError(op)
    return sp


def asks(fx):
    return [ev for ev in fx["events"] if ev[0] == "reserve"]


class NoPressure(unittest.TestCase):
    """Titles that never fail a placement keep today's placements: the module is never engaged."""

    def check(self, name):
        fx = load(name)
        on, off = replay(fx), replay(fx, elastic=False)
        self.assertEqual(on.placements, off.placements, name)
        c = on.counts()
        self.assertEqual((c["engaged"], c["lends"], c["shorts"], c["grows"], c["refusals"]), (0, 0, 0, 0, 0), name)
        self.assertEqual(on.refused, {}, name)
        self.assertEqual(on.wrong_view, [], name)
        return on, fx

    def test_hollow_knight_and_deaths_door_place_at_their_logged_addresses(self):
        for name in ("hollow-knight.json", "deaths-door.json"):
            sp, fx = self.check(name)
            self.assertGreaterEqual(len(asks(fx)), 17)
            for _, vid, size, names, extra in asks(fx):
                self.assertEqual(int(size, 16), 0x1FFFF000)
                self.assertEqual(sp.placements[vid], int(extra["at"], 16), (name, vid))
                self.assertEqual(sp.views[vid]["span"], 0x1FFFF000)

    def test_rdr2_off_layout(self):
        sp, fx = self.check("rdr2-off-layout.json")
        self.assertTrue(all(sp.placements[ev[1]] is not None for ev in asks(fx)))
        self.assertEqual(sp.views["game8960"]["span"], 8960 * MB)
        self.assertEqual(sp.views["game8960"]["height"], 2357 * MB)

    def test_rdr2_on_layout_is_routed_first(self):
        sp, fx = self.check("rdr2-on-layout.json")
        self.assertEqual(sp.placements["game8960"], 0x75D0000000)
        self.assertEqual(sp.placements["game1175"], 0x726B1E0000)
        # V8's ladder and the helper's 5,119 MB asks fail as today, never shortened.
        for vid in ("v8_512g", "v8_64g", "v8_32g", "v8_16g", "v8_5119_a1", "v8_5119_b2"):
            self.assertIsNone(sp.placements[vid], vid)

    def test_the_witcher_3_132_without_its_keys_places_whole(self):
        sp, fx = self.check("witcher3-132.json")
        self.assertEqual(sp.views["pool32g"]["span"], 32 * GB)
        self.assertEqual(sp.views["pool32g"]["height"], 1600 * MB)
        self.assertEqual(sp.views["pool8g"]["height"], 600 * MB)

    def test_portal_2s_wow64_window_takes_its_first_fixed_slot(self):
        sp, fx = self.check("portal2-wow64.json")
        self.assertEqual(sp.placements["window"], 0x72BFFF0000)   # its [wow64-window] fixed slot line
        self.assertEqual(sp.views["window"]["span"], 4 * GB)
        self.assertEqual(LIB.s_n(sp.st), 0)                       # not the module's to track: never a lender


class Pressure(unittest.TestCase):

    def test_mewgenics_keeps_every_pool_reservable_through_160(self):
        fx = load("mewgenics.json")
        sp = replay(fx)
        pools = [ev[1] for ev in asks(fx) if ev[1].startswith("pool")]
        self.assertGreaterEqual(len(pools), 142)
        for vid in pools + ["ask21"]:
            self.assertIsNotNone(sp.placements[vid], vid)
        # The first 42 are placed as today, at their logged addresses.
        for _, vid, _, _, extra in asks(fx)[:42]:
            self.assertEqual(sp.placements[vid], int(extra["at"], 16), vid)
        # Every measured commit (4 KB to 6.9 MB) is served, in its own pool.
        self.assertEqual(sp.refused, {})
        self.assertEqual(sp.wrong_view, [])
        c = sp.counts()
        self.assertEqual(c["engaged"], 1)
        self.assertGreater(c["lends"], 0)
        self.assertGreater(c["shorts"], 0)
        # How deep each pool commits before a refusal: a lent pool keeps its height plus at least
        # 64 MiB, a short grant has at least 64 MiB, a whole one its gigabyte.
        heights = {ev[1]: int(ev[2], 16) for ev in fx["events"] if ev[0] == "commit"}
        for vid in pools:
            v = sp.views[vid]
            lent = vid in [ev[1] for ev in asks(fx)[:42]] and v["span"] < GB
            want = heights[vid] + 64 * MB if lent else 64 * MB if v["span"] < GB else GB
            self.assertGreaterEqual(sp.depth(vid, want), want, vid)

    def test_witcher_3_4x_places_its_pools_without_a_key(self):
        fx = load("witcher3-4x.json")
        sp = replay(fx)
        for _, vid, *_ in asks(fx):
            self.assertIsNotNone(sp.placements[vid], vid)
        self.assertEqual(sp.placements["pool16g"], 0x73FFFF0000)          # as today
        self.assertEqual(sp.views["pool16g"]["span"], 16 * GB)
        # 64 and 32 GiB: short grants, the later one below the earlier.
        g64, g32 = sp.views["pool64g"], sp.views["pool32g"]
        self.assertLess(g64["span"], 64 * GB)
        self.assertLess(g32["span"], 32 * GB)
        self.assertLess(g32["base"] + g32["span"], g64["base"] + 1)
        # First-match dispatch: no later pool inside an earlier claim.
        self.assertEqual(sp.landed_in_claim, [])
        self.assertEqual(sp.refused, {})
        self.assertEqual(sp.wrong_view, [])
        self.assertEqual(sp.counts()["lends"], 0)
        self.assertEqual(sp.views["pool64g"]["height"], 1490 * MB)
        self.assertEqual(sp.views["pool32g"]["height"], 77 * MB)
        self.assertGreaterEqual(sp.depth("pool64g"), 4 * GB)
        self.assertGreaterEqual(sp.depth("pool32g"), 2 * GB)

    def test_witcher_3_132_without_its_keys_in_a_split_window(self):
        sp = replay(load("witcher3-132-crowded.json"))
        g32 = sp.views["pool32g"]
        self.assertLess(g32["span"], 32 * GB)
        self.assertGreaterEqual(sp.depth("pool32g"), 4 * GB)   # decision 0180's bar for removing its keys
        self.assertEqual(g32["height"], 1600 * MB)
        self.assertEqual(sp.landed_in_claim, [])
        self.assertEqual(sp.refused, {})
        self.assertEqual(sp.wrong_view, [])


class Exceptions(unittest.TestCase):
    """Never shrunk, by property, under the same pressure that shortens Mewgenics' pools."""

    def full(self):
        fx = load("mewgenics.json")
        events = fx["events"][:fx["events"].index(["fill"]) + 1]
        return replay(dict(fx, events=events))

    def test_never_shrunk_asks_are_placed_whole_or_fail(self):
        for name in ("hint", "align", "placeholder", "ex", "limit", "commit", "held", "layout", "wow64"):
            sp = self.full()
            sp.reserve("pool43", GB, [])                         # shortened, for contrast
            self.assertLess(sp.views["pool43"]["span"], GB)
            sp.reserve("x", 2 * GB, [name])
            if sp.placements["x"] is not None:
                self.assertEqual(sp.views["x"]["span"], 2 * GB, name)
            for n in (512 * MB, 4 * GB):
                sp.reserve("y", n, [name])
                if sp.placements["y"] is not None:
                    self.assertEqual(sp.views["y"]["span"], n, name)
                    sp.release("y")

    def test_an_ask_over_twice_the_window_fails_as_today(self):
        sp = self.full()
        self.assertIsNone(sp.reserve("huge", 2 * WINDOW + GRAIN, []))
        self.assertEqual(sp.counts()["lends"], 0)
        self.assertIsNotNone(sp.reserve("big", 2 * WINDOW, []))


class Wow64Window(unittest.TestCase):
    """A WoW64 process's 4 GiB window (PLA-839) is an ask of the policy: placed as today (its fixed slots,
    then a first fit), lent room when that fails, never shrunk and never a lender."""

    def test_senren_banka_on_an_unentitled_map_fails_honestly(self):
        sp = replay(load("senren-banka-unentitled.json"))
        self.assertIsNone(sp.placements["window"])
        c = sp.counts()
        # Asked once today's placement failed; no lender, nothing shortened: STATUS_NO_MEMORY as reported.
        self.assertEqual((c["engaged"], c["lends"], c["shorts"]), (1, 0, 0))
        # The 1,124 MB left beside FEX's arena would not hold a 2 GiB window either.
        self.assertIsNone(sp.today(2 * GB, None))

    def rdr2_then_its_dllhost(self, elastic=True):
        # Run 20261030T122917-rdr2-p476l7: RDR2's Play started C:\windows\syswow64\dllhost.exe (line 126023),
        # whose 4 GiB window found no gap (maxgap 0xfb810000, line 126061) and failed with 0xc0000017
        # (lines 126074-126075). Here RDR2's own asks off the layout, then the rest of the window taken.
        fx = load("rdr2-off-layout.json")
        events = fx["events"] + [["fill"], ["reserve", "dllhost", "0x100000000", ["wow64"], {}]]
        return replay(dict(fx, events=events), elastic)

    def test_a_window_with_no_room_today_is_lent_room_and_placed_whole(self):
        self.assertIsNone(self.rdr2_then_its_dllhost(elastic=False).placements["dllhost"])
        sp = self.rdr2_then_its_dllhost()
        game = sp.views["game8960"]
        # The 8,960 MB pool, 2,357 MB committed, keeps twice its height and its guard (4,746 MB) and lends
        # the rest (4,214 MB): the window's first fit, whole.
        self.assertEqual(game["span"], 4746 * MB)
        self.assertEqual(sp.placements["dllhost"], game["base"] + 4746 * MB)
        self.assertEqual(sp.views["dllhost"]["span"], 4 * GB)
        self.assertEqual(sp.landed_in_claim, [("dllhost", game["base"])])
        c = sp.counts()
        self.assertEqual((c["lends"], c["shorts"]), (1, 0))
        # The pool commits to twice its height; past it, refused, never served in the window.
        sp.commit("game8960", 4714 * MB)
        self.assertEqual(sp.refused, {})
        sp.commit("game8960", 4714 * MB + MB)
        self.assertEqual(sp.refused, {"game8960": 4714 * MB})
        self.assertEqual(sp.wrong_view, [])

    def test_a_window_never_lends(self):
        sp = self.rdr2_then_its_dllhost()
        window = sp.placements["dllhost"]
        self.assertNotIn(window, [v["base"] for v in sp.mviews()])
        lends = sp.counts()["lends"]
        self.assertIsNotNone(sp.reserve("pool", GB, []))        # fails today: someone else lends
        self.assertGreater(sp.counts()["lends"], lends)
        self.assertEqual(sp.views["dllhost"]["span"], 4 * GB)


class GrowthAndRefusal(unittest.TestCase):

    def test_a_shortened_pool_grows_by_doubling_while_the_space_above_is_free_then_is_refused(self):
        free = [["0x7000000000", "0x7040000000"]]                # 1 GiB of window
        sp = Space(free)
        sp.reserve("a", GB, [])
        sp.commit("a", 4 * MB)
        sp.reserve("b", 64 * MB, [])                            # fails whole: a lends
        a = sp.views["a"]
        self.assertEqual(a["span"], 64 * MB + 4 * MB + GUARD)   # keeps h + 64 MiB, then its guard
        self.assertEqual(sp.placements["b"], a["base"] + a["span"])
        sp.release("b")
        sp.commit("a", 200 * MB)                                # reaches the guard: grows 68 -> 136 -> 272 MiB
        self.assertEqual(sp.refused, {})
        self.assertEqual(sp.views["a"]["span"], 272 * MB + GUARD)
        self.assertEqual(sp.counts()["grows"], 2)
        sp.reserve("c", 128 * MB, [])                           # lands just above a's guard
        self.assertEqual(sp.placements["c"], a["base"] + 272 * MB + GUARD)
        sp.commit("a", 300 * MB)
        self.assertEqual(sp.refused, {"a": 272 * MB})           # refused, never served in c
        self.assertEqual(sp.wrong_view, [])

    def test_a_commit_is_matched_to_its_own_view_before_a_covering_claim(self):
        free = [["0x7000000000", "0x7040000000"]]
        sp = Space(free)
        sp.reserve("a", GB, [])
        sp.reserve("b", 64 * MB, [])                            # inside a's lent claim
        b = sp.views["b"]["base"]
        a = sp.views["a"]["base"]
        self.assertTrue(a < b < a + GB)
        sp.commit("b", 16 * MB)                                 # b's own: served in b
        self.assertEqual((sp.refused, sp.wrong_view), ({}, []))
        # a's bump cursor running past its real part meets its own guard first; with b right above
        # the guard there is no room to grow, so the commit is refused, never served in b.
        self.assertFalse(sp.commit_one("a", sp.views["a"]["span"] - MB, MB))   # the guard: no room above
        self.assertEqual(sp.wrong_view, [])


class ReviewFixes(unittest.TestCase):
    """The rule's edges: nothing lends before today's placement fails, a never-shrunk ask lends only
    room that can hold it, a short grant is always tracked, and live claims are counted."""

    def engaged(self):
        fx = load("mewgenics.json")
        events = fx["events"][:fx["events"].index(["fill"]) + 1]
        sp = replay(dict(fx, events=events))
        sp.reserve("pool43", GB, [])                            # fails today: lends or shortens
        self.assertEqual(sp.counts()["engaged"], 1)
        return sp

    def test_before_never_lends_or_shortens(self):
        sp = self.engaged()
        before = sp.counts()
        for size in (256 * MB, GB, 4 * GB, 32 * GB):
            kind = sp.decide(LIB.s_before, size, 0)[0]
            self.assertIn(kind, (TODAY, PLACE), size)
        self.assertEqual(sp.counts(), before)

    def test_a_limited_ask_lends_nothing_its_limit_excludes(self):
        sp = self.engaged()
        lends = sp.counts()["lends"]
        self.assertIsNone(sp.reserve("low", 64 * MB, ["limit"], limit=LO + GRAIN))
        self.assertEqual(sp.counts()["lends"], lends)

    def test_an_aligned_ask_lends_nothing_that_cannot_hold_it_aligned(self):
        sp = self.engaged()
        lends = sp.counts()["lends"]
        self.assertIsNone(sp.reserve("a64", 512 * MB, ["align"], align=64 * GB))
        self.assertEqual(sp.counts()["lends"], lends)

    def test_a_commit_at_reserve_ask_lends_once_and_is_placed_whole(self):
        free = [["0x7000000000", "0x7040000000"]]                # 1 GiB of window
        sp = Space(free)
        sp.reserve("a", GB, [])
        sp.reserve("b", GB, [])                                 # fails: shortens or fails
        sp.reserve("c", 128 * MB, ["commit"])
        self.assertIsNotNone(sp.placements["c"])
        self.assertEqual(sp.views["c"]["span"], 128 * MB)
        self.assertEqual(sp.counts()["lends"], 1)

    def test_past_the_view_table_no_short_grant(self):
        st = LIB.s_new(WINDOW)
        try:
            for i in range(1024):
                self.assertEqual(LIB.s_placed(st, LO + i * 256 * MB, 256 * MB, 256 * MB, 0), i)
            gaps = (ctypes.c_uint64 * 2)(HI - 2 * GB, 2 * GB)
            o = (ctypes.c_uint64 * 4)()
            self.assertNotEqual(LIB.s_failed(st, 8 * GB, 0, 0, 0, gaps, 1, o), SHORT)
            LIB.s_released(st, LO)
            self.assertEqual(LIB.s_failed(st, 8 * GB, 0, 0, 0, gaps, 1, o), SHORT)
        finally:
            LIB.s_free(st)

    def test_live_claims_are_counted_as_they_come_and_go(self):
        free = [["0x7000000000", "0x7040000000"]]
        sp = Space(free)
        sp.reserve("a", GB, [])
        self.assertEqual(sp.counts()["shortened"], 0)
        sp.reserve("b", 64 * MB, [])                            # a lends
        self.assertEqual(sp.counts()["shortened"], 1)
        sp.release("b")
        sp.release("a")
        self.assertEqual(sp.counts()["shortened"], 0)


if __name__ == "__main__":
    unittest.main()

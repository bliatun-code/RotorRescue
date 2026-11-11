#!/usr/bin/env python3
"""Headless test bench for Rotor Rescue.

Runs scripts/RotorRescue/main.lua under Lua 5.4 (lupa) with a mock of the
ETHOS calls the game uses, and draws the frames with Pillow. It is a
development aid, not a replacement for the FrSky simulators: fonts, colours
and timing only approximate a radio.

What it checks:
  * the game flies a full mission with scripted sticks (autopilot);
  * Lua instructions per wakeup and per paint (ETHOS aborts a paint that
    runs too long), and memory allocated per frame;
  * partial redraws: every partially repainted frame must equal a full
    repaint of the same state, both when ETHOS clips the paint to the
    invalidated rectangle and when it does not;
  * the audio clips the game queues.

    pip install lupa pillow
    python3 tools/headless.py --frames out/   # also saves PNG frames
"""
import argparse
import math
import os
import sys
import tempfile

import lupa.lua54 as lupa
from PIL import Image, ImageChops, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_DIR = os.path.join(ROOT, "scripts", "RotorRescue")
FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

# Arbitrary but distinct values for the ETHOS constants main.lua reads.
CONSTANTS = dict(
    CATEGORY_ANALOG=1, ANALOG_STICK_THROTTLE=2, ANALOG_STICK_AILERON=3,
    FONT_XS=10, FONT_S=11, FONT_STD=12, FONT_L=13, FONT_XL=14,
    LEFT=0, CENTERED=1, RIGHT=2,
    EVT_KEY=100, EVT_TOUCH=101, EVT_CLOSE=102,
    TOUCH_START=200, TOUCH_MOVE=201, TOUCH_END=202,
    KEY_ENTER_FIRST=300, KEY_ENTER_BREAK=301, KEY_ENTER_LONG=302,
    KEY_EXIT_FIRST=310, KEY_EXIT_BREAK=311, KEY_PAGE_BREAK=320,
)
FONT_PX = {10: 13, 11: 16, 12: 19, 13: 25, 14: 32}


class Canvas:
    """A framebuffer with a clipping rectangle, drawn with Pillow."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.img = Image.new("RGB", (w, h), (0, 0, 0))
        self.limit = (0, 0, w, h)  # ETHOS-side clip (invalidated area)
        self.clip = (0, 0, w, h)   # script-side clip (lcd.setClipping)
        self.color = (255, 255, 255)
        self.font = 12
        self._fonts = {}
        self.ops = 0

    def font_obj(self, font=None):
        size = FONT_PX.get(font or self.font, 16)
        if size not in self._fonts:
            self._fonts[size] = ImageFont.truetype(FONT_PATH, size)
        return self._fonts[size]

    def _box(self):
        a, b = self.limit, self.clip
        x0, y0 = max(a[0], b[0]), max(a[1], b[1])
        x1, y1 = min(a[2], b[2]), min(a[3], b[3])
        return (x0, y0, x1, y1) if x1 > x0 and y1 > y0 else None

    def _draw(self, fn, bbox):
        """Draw fn(ImageDraw, ox, oy) clipped to the active clip box."""
        self.ops += 1
        box = self._box()
        if not box:
            return
        x0, y0 = max(box[0], math.floor(bbox[0])), max(box[1], math.floor(bbox[1]))
        x1, y1 = min(box[2], math.ceil(bbox[2]) + 1), min(box[3], math.ceil(bbox[3]) + 1)
        if x1 <= x0 or y1 <= y0:
            return
        # Rasterize on a tile that holds the whole primitive (origin at or left of it), so a
        # clipped draw sets exactly the pixels an unclipped one would; then keep the clip box.
        tx0, ty0 = max(0, math.floor(bbox[0]) - 2), max(0, math.floor(bbox[1]) - 2)
        tx1, ty1 = min(self.w, math.ceil(bbox[2]) + 3), min(self.h, math.ceil(bbox[3]) + 3)
        tile = self.img.crop((tx0, ty0, tx1, ty1))
        fn(ImageDraw.Draw(tile), tx0, ty0)
        self.img.paste(tile.crop((x0 - tx0, y0 - ty0, x1 - tx0, y1 - ty0)), (x0, y0))

    def rect(self, x, y, w, h):
        if w <= 0 or h <= 0:
            return
        c = self.color
        self._draw(lambda d, ox, oy: d.rectangle((x - ox, y - oy, x + w - 1 - ox, y + h - 1 - oy), fill=c),
                   (x, y, x + w - 1, y + h - 1))

    def line(self, x1, y1, x2, y2):
        c = self.color
        self._draw(lambda d, ox, oy: d.line((x1 - ox, y1 - oy, x2 - ox, y2 - oy), fill=c, width=1),
                   (min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)))

    def triangle(self, pts):
        c = self.color
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        self._draw(lambda d, ox, oy: d.polygon([(px - ox, py - oy) for px, py in pts], fill=c),
                   (min(xs), min(ys), max(xs), max(ys)))

    def circle(self, x, y, r):
        c = self.color
        self._draw(lambda d, ox, oy: d.ellipse((x - r - ox, y - r - oy, x + r - ox, y + r - oy), fill=c),
                   (x - r, y - r, x + r, y + r))

    def text(self, x, y, s, flags):
        font, c = self.font_obj(), self.color
        tw = font.getlength(s)
        if flags == CONSTANTS["CENTERED"]:
            x -= tw / 2
        elif flags == CONSTANTS["RIGHT"]:
            x -= tw
        th = FONT_PX.get(self.font, 16)
        self._draw(lambda d, ox, oy: d.text((x - ox, y - oy), s, font=font, fill=c),
                   (x, y, x + tw, y + th * 1.3))


class Sim:
    def __init__(self, w=800, h=480, system_clip=False, script_dir=SCRIPT_DIR):
        self.w, self.h = w, h
        self.system_clip = system_clip
        self.clock = 1000.0
        self.thr, self.ail = -1.0, 0.0
        self.sticks_ok = True
        self.played = []      # (time, file)
        self.haptics = []     # (time, args)
        self.exited = False
        self.invalid = None   # union of invalidated rects since the last paint
        self.full_clear = False
        self.cleared = False
        self.canvas = Canvas(w, h)
        self.paints = 0
        self.paint_instr = []
        self.paint_area = []
        self.wakeup_instr = []
        self.frame_kb = []
        self.mismatches = 0
        self.tmp = tempfile.mkdtemp(prefix="rr-")
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        self._install()
        self.tool = None
        chunk = self.lua.eval("function(path) return assert(loadfile(path))() end")(
            os.path.join(script_dir, "main.lua"))
        chunk.init()
        assert self.tool is not None, "registerSystemTool was not called"
        self.g = self.tool.create()

    # ---- ETHOS mock -----------------------------------------------------
    def _install(self):
        L, g = self.lua, self.lua.globals()
        for k, v in CONSTANTS.items():
            g[k] = v
        sim = self

        def path(p):
            return os.path.join(sim.tmp, p.replace("SCRIPTS:/RotorRescue/", ""))

        lcd = L.table()
        lcd.RGB = lambda r, gg, b, a=None: (int(r) << 16) | (int(gg) << 8) | int(b)
        lcd.getWindowSize = lambda: (sim.w, sim.h)
        lcd.loadMask = lambda *a: "mask"
        lcd.loadBitmap = lambda *a: "bitmap"

        def color(c=None):
            if c is not None:
                sim.canvas.color = ((c >> 16) & 255, (c >> 8) & 255, c & 255)

        def font(f=None):
            if f is not None:
                sim.canvas.font = f

        def invalidate(x=None, y=None, w=None, h=None):
            if x is None:
                sim.full_clear = True
                x, y, w, h = 0, 0, sim.w, sim.h
            r = (max(0, int(x)), max(0, int(y)), min(sim.w, int(x + w)), min(sim.h, int(y + h)))
            if sim.invalid is None:
                sim.invalid = r
            else:
                a = sim.invalid
                sim.invalid = (min(a[0], r[0]), min(a[1], r[1]), max(a[2], r[2]), max(a[3], r[3]))

        def set_clipping(x=None, y=None, w=None, h=None):
            if x is None:
                sim.canvas.clip = (0, 0, sim.w, sim.h)
            else:
                sim.canvas.clip = (int(x), int(y), int(x + w), int(y + h))

        def text_size(s):
            f = sim.canvas.font_obj()
            return int(f.getlength(s)), FONT_PX.get(sim.canvas.font, 16)

        lcd.color = color
        lcd.font = font
        lcd.invalidate = invalidate
        lcd.setClipping = set_clipping
        lcd.getTextSize = text_size
        lcd.drawFilledRectangle = lambda x, y, w, h: sim.canvas.rect(x, y, w, h)
        lcd.drawLine = lambda a, b, c, d: sim.canvas.line(a, b, c, d)
        lcd.drawFilledTriangle = lambda a, b, c, d, e, f: sim.canvas.triangle([(a, b), (c, d), (e, f)])
        lcd.drawFilledCircle = lambda x, y, r: sim.canvas.circle(x, y, r)
        lcd.drawText = lambda x, y, s, flags=0: sim.canvas.text(x, y, s, flags)
        g.lcd = lcd

        system = L.table()

        def register(params):
            sim.tool = params
            sim.title = params.title
        system.registerSystemTool = register

        def get_source(spec):
            member = spec.member
            if not sim.sticks_ok:
                return None
            src = L.table()
            src.value = (lambda self: sim.thr * 1024) if member == CONSTANTS["ANALOG_STICK_THROTTLE"] \
                else (lambda self: sim.ail * 1024)
            return src
        system.getSource = get_source
        system.getVersion = lambda: L.table_from({"board": "X20RS", "major": 26, "minor": 1})
        system.playFile = lambda f: sim.played.append((sim.clock, f.replace("SCRIPTS:/RotorRescue/", "")))
        system.playHaptic = lambda *a: sim.haptics.append((sim.clock, a))
        system.resetBacklightTimeout = lambda: None

        def exit_():
            sim.exited = True
        system.exit = exit_
        g.system = system

        # ETHOS file API: io.open / io.read(file, n) / io.write(file, s) / io.close(file)
        io = L.table()
        files = {}

        def io_open(p, mode="r"):
            try:
                fh = open(path(p), mode.replace("b", "") + "b")
            except OSError:
                return None
            files[id(fh)] = fh
            return fh
        io.open = io_open
        io.read = lambda fh, n=None: fh.read(int(n) if n else -1).decode("latin-1")
        io.write = lambda fh, *s: [fh.write(x.encode("latin-1")) for x in s] and None
        io.close = lambda fh: fh.close()
        g.io = io
        g.os.clock = lambda: sim.clock
        self.lua.execute("""
            local count = 0
            local function hook() count = count + 1 end
            function rr_measure(f, ...)
                count = 0
                collectgarbage("stop")
                local before = collectgarbage("count")
                debug.sethook(hook, "", 1)
                local ok, err = pcall(f, ...)
                debug.sethook()
                local kb = collectgarbage("count") - before
                collectgarbage("restart")
                if not ok then error(err, 0) end
                return count, kb
            end
        """)
        self.measure = g.rr_measure

    # ---- driving the tool ------------------------------------------------
    def wakeup(self):
        n, kb = self.measure(self.tool.wakeup, self.g)
        self.wakeup_instr.append(n)
        return kb

    def paint(self, check=True):
        c = self.canvas
        rect = self.invalid or (0, 0, self.w, self.h)
        if self.full_clear:
            self.cleared = True
            c.img.paste((0, 0, 0), (0, 0, self.w, self.h))
        c.limit = rect if self.system_clip else (0, 0, self.w, self.h)
        c.clip = (0, 0, self.w, self.h)
        n, kb = self.measure(self.tool.paint, self.g)
        self.paint_instr.append(n)
        self.paint_area.append((rect[2] - rect[0]) * (rect[3] - rect[1]) / (self.w * self.h))
        self.invalid, self.full_clear = None, False
        self.paints += 1
        if check:
            # A paint ETHOS asks for by itself must draw everything; it must
            # match the partially updated framebuffer pixel for pixel.
            ref = Canvas(self.w, self.h)
            saved, self.canvas = self.canvas, ref
            self.tool.paint(self.g)
            self.canvas = saved
            diff = ImageChops.difference(c.img, ref.img).getbbox()
            if diff:
                self.mismatches += 1
                if self.mismatches <= 3:
                    print(f"  partial redraw mismatch at {diff} (frame {self.paints}, rect {rect})")
        return kb

    def step(self, dt=0.010, check=True):
        """One ETHOS loop: wakeup, then a paint if something was invalidated."""
        self.clock += dt
        kb = self.wakeup()
        if self.invalid is not None:
            kb += self.paint(check)
            self.frame_kb.append(kb)
            return True
        return False

    def event(self, category, value, x=None, y=None):
        r = self.tool.event(self.g, CONSTANTS[category], CONSTANTS[value], x, y)
        return r

    def touch(self, x, y):
        self.tool.event(self.g, CONSTANTS["EVT_TOUCH"], CONSTANTS["TOUCH_START"], x, y)
        return self.tool.event(self.g, CONSTANTS["EVT_TOUCH"], CONSTANTS["TOUCH_END"], x, y)

    def save(self, name, out):
        if out:
            os.makedirs(out, exist_ok=True)
            self.canvas.img.save(os.path.join(out, name + ".png"))


# ---- autopilot ---------------------------------------------------------------
PADS = [(8, 2.8, 4.2), (24, 8, 3.6), (49, 14, 2.8), (65, 5, 2.3)]


def stick_for(command):
    """Invert command = s * (0.64 + 0.36 |s|)."""
    a = abs(command)
    s = (-0.64 + math.sqrt(0.64 ** 2 + 4 * 0.36 * a)) / (2 * 0.36)
    return math.copysign(min(1.0, s), command)


def autopilot(g, target):
    """Sticks (throttle -1..1, aileron -1..1) that fly to and land on a pad."""
    px, py, half = PADS[target - 1]
    x, y, vx, vy, tilt = g.x, g.y, g.vx, g.vy, g.tilt
    # Cruise above everything between here and the pad (Lookout is 14 m).
    lo, hi = min(x, px), max(x, px)
    cruise = max([p[1] for p in PADS if lo - 4 <= p[0] <= hi + 4] + [py]) + 4.5
    dx = px - x
    over = abs(dx) < 0.6
    if g.support:
        # On a pad: keep the rotor turning slowly while boarding, else lift off.
        return (-0.15 if g.boarding is not None else 0.35), 0.0
    if over:
        alt = py - 1.0  # descend through the deck
        vy_cmd = max(-1.2, min(1.5, 1.2 * (alt - y)))
    else:
        vy_cmd = max(-2.0, min(2.5, 1.5 * (cruise - y)))
    climbed = y > cruise - 1.5 or (abs(dx) < 6 and y > py + 1.5)
    vx_cmd = max(-5.5, min(5.5, 0.55 * dx)) if climbed else 0.0
    if abs(dx) < 2.5:
        vx_cmd = 0.6 * dx
    tilt_cmd = max(-0.45, min(0.45, 0.16 * (vx_cmd - vx) - 0.05 * vx * 0))
    stick = stick_for(tilt_cmd / 0.57)
    power = 0.52 / max(0.6, math.cos(tilt)) + 0.12 * (vy_cmd - vy)
    power = max(0.08, min(1.0, power))
    return power * 2 - 1, stick


def fly_mission(sim, out=None, max_seconds=240):
    g = sim.g
    sim.thr = -1
    for _ in range(30):
        sim.step()
    sim.save("01-ready", out)
    shots = {"02-boarding": False, "03-return": False}
    t0 = sim.clock
    while sim.clock - t0 < max_seconds:
        if g.mode == "won" or g.mode == "crashed":
            break
        sim.thr, sim.ail = autopilot(g, g.target) if g.mode == "flight" else (-1, 0)
        painted = sim.step()
        if painted and not shots["02-boarding"] and g.boarding is not None and g.boarding > 1.0:
            sim.save("02-boarding", out)
            shots["02-boarding"] = True
        if painted and not shots["03-return"] and g.target == 1 and g.x < 45 and not g.support:
            sim.save("03-return", out)
            shots["03-return"] = True
    for _ in range(40):
        sim.thr, sim.ail = -1, 0
        sim.step()
    sim.save("04-" + str(g.mode), out)
    return g.mode


def ui_flows(sim):
    """Menus, a crash and a retry; returns a list of failed checks."""
    g, w, h, failures = sim.g, sim.w, sim.h, []

    def run(seconds, thr=None):
        end = sim.clock + seconds
        while sim.clock < end:
            if thr is not None:
                sim.thr = thr
            sim.step()

    def expect(ok, what):
        if not ok:
            failures.append(what)

    sim.thr = 1.0  # throttle high: the game must not arm
    run(0.5)
    expect(g.mode == "ready", "stays ready with throttle high")
    sim.touch(w - 200, h - 30)
    run(0.3)
    expect(g.showScores, "TOP SCORES opens the list")
    sim.touch(w / 2, h * 0.19 + 220)
    run(0.3)
    expect(not g.showScores, "CLOSE hides the list")
    sim.touch(w - 60, h - 30)
    run(0.2)
    expect(g.mute and g.hud.sound == "SOUND OFF", "sound toggles off")
    sim.touch(w - 60, h - 30)
    run(0.2)
    expect(not g.mute, "sound toggles on")
    sim.touch(120, 20)
    run(1.5, -1)
    expect(g.perf and "FPS" in g.hud.build, "version line shows FPS")
    sim.touch(120, 20)
    run(0.2)
    expect(not g.perf, "FPS readout toggles off")
    # Climb, then cut the throttle: a hard landing.
    run(2.0, 0.6)
    run(2.0, -1)
    expect(g.mode == "crashed" and "Descent" in g.reason, "falling from height is a hard landing")
    expect(len(sim.haptics) >= 1, "crash vibrates")
    sim.touch(w * 0.37, g.lay.panelTop + 110)
    run(0.3, -1)
    expect(g.mode != "crashed" and g.retries == 1, "RETRY resumes with one retry")
    run(2.0, 0.6)
    run(2.0, -1)
    sim.event("EVT_KEY", "KEY_ENTER_BREAK")
    run(0.3, -1)
    expect(g.mode != "crashed" and g.retries == 2, "Enter retries after a crash")
    sim.touch(20, 20)
    expect(sim.exited, "exit button closes the tool")
    return failures


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames", help="directory for PNG frames")
    ap.add_argument("--size", default="800x480", help="window size, e.g. 800x480 or 790x409")
    args = ap.parse_args()
    w, h = (int(v) for v in args.size.split("x"))
    failed = False
    for clip in (False, True):
        sim = Sim(w, h, system_clip=clip)
        mode = fly_mission(sim, args.frames if not clip else None)
        g = sim.g
        label = "ETHOS clips paint" if clip else "no ETHOS clip   "
        p = sorted(sim.paint_instr)
        wk = sorted(sim.wakeup_instr)
        kb = sorted(sim.frame_kb)
        print(f"[{label}] result={mode} score={g.score} time={g.time:.2f}s retries={g.retries} "
              f"paints={sim.paints} mismatches={sim.mismatches}")
        area = sorted(sim.paint_area)
        print(f"   repainted area per paint: median={area[len(area)//2]:.1%} mean={sum(area)/len(area):.1%} "
              f"(clear-before-paint={'yes' if sim.cleared else 'no'})")
        print(f"   paint instr median={p[len(p)//2]} p95={p[int(len(p)*.95)]} max={p[-1]} | "
              f"wakeup median={wk[len(wk)//2]} max={wk[-1]} | KB/frame median={kb[len(kb)//2]:.2f} max={kb[-1]:.2f}")
        if mode != "won" or sim.mismatches:
            failed = True
        if not clip:
            files = {}
            for _, f in sim.played:
                files[f] = files.get(f, 0) + 1
            print(f"   audio clips queued={len(sim.played)} distinct={len(files)} haptics={len(sim.haptics)} "
                  f"title={sim.title}")
    for size in ((w, h), (790, 409)):
        sim = Sim(*size)
        failures = ui_flows(sim)
        print(f"[ui flows {size[0]}x{size[1]}] failed={failures or 'none'} paints={sim.paints} "
              f"mismatches={sim.mismatches} max paint instr={max(sim.paint_instr)}")
        failed = failed or bool(failures) or sim.mismatches > 0
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

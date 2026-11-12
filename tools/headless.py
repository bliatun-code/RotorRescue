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
FONT_FALLBACK = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
OPEN_SANS = "/usr/share/fonts/truetype/open-sans/OpenSans-{}.ttf"

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
# ETHOS font -> Open Sans weight, size (px), letter spacing (px) and the gap from the text's y to
# its cap tops. Fitted to text in the X20RS simulator (ETHOS 26.1.2); DejaVu Sans stands in when
# Open Sans is not installed (apt install fonts-open-sans).
FONT_STYLE = {10: ("Semibold", 12, 1.1, 2), 11: ("Semibold", 15, 0.4, 3), 12: ("Regular", 21, 0.6, 3),
              13: ("Regular", 25, -0.2, 3), 14: ("Regular", 32, 0.0, 3)}


TEXT_MASKS = {}


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
        """(Pillow font, letter spacing, cap offset) standing in for an ETHOS font."""
        key = font or self.font
        if key not in self._fonts:
            weight, size, spacing, cap = FONT_STYLE.get(key, FONT_STYLE[12])
            path = OPEN_SANS.format(weight)
            if not os.path.exists(path):
                path, spacing = FONT_FALLBACK, 0.0
            self._fonts[key] = (ImageFont.truetype(path, size), spacing, cap)
        return self._fonts[key]

    def text_width(self, s):
        font, spacing, _ = self.font_obj()
        return sum(font.getlength(ch) for ch in s) + spacing * max(0, len(s) - 1)

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
        (font, spacing, cap), c = self.font_obj(), self.color
        tw = self.text_width(s)
        if flags == CONSTANTS["CENTERED"]:
            x -= tw / 2
        elif flags == CONSTANTS["RIGHT"]:
            x -= tw
        self.ops += 1
        # Text is rendered once per font and string into a mask, then pasted in the colour.
        key = (self.font, s)
        mask = TEXT_MASKS.get(key)
        if mask is None:
            mask = Image.new("L", (math.ceil(tw) + 6, math.ceil(font.size * 1.6)), 0)
            d, cx = ImageDraw.Draw(mask), 3
            for ch in s:
                d.text((cx, 0), ch, font=font, fill=255)
                cx += font.getlength(ch) + spacing
            TEXT_MASKS[key] = mask
        left, top = round(x) - 3, round(y + cap - font.getbbox("H")[1])
        box = self._box()
        if not box:
            return
        x0, y0 = max(box[0], left), max(box[1], top)
        x1, y1 = min(box[2], left + mask.width), min(box[3], top + mask.height)
        if x1 > x0 and y1 > y0:
            self.img.paste(c, (x0, y0, x1, y1), mask.crop((x0 - left, y0 - top, x1 - left, y1 - top)))


class Sim:
    def __init__(self, w=800, h=480, system_clip=False, script_dir=SCRIPT_DIR, open_tool=True):
        self.w, self.h = w, h
        self.script_dir = script_dir
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
        self.g = None
        if open_tool:
            self.open()

    def open(self):
        """Open the System tool, as tapping its tile does."""
        self.g = self.tool.create()

    def close(self):
        """Leave the System tool."""
        if self.tool.close:
            self.tool.close(self.g)
        self.g = None

    def lua_kb(self):
        return self.lua.eval('(function() collectgarbage("collect"); collectgarbage("collect"); '
                             'return collectgarbage("count") end)()')

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
            return int(sim.canvas.text_width(s)), sim.canvas.font_obj()[0].size

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
        # ETHOS resolves SCRIPTS:/ paths; Lua RAM for scripts is a fixed pool (4 MB here).
        self.lua.execute("""
            local real, base = loadfile, ...
            loadfile = function(path, ...)
                return real((path:gsub("^SCRIPTS:/RotorRescue/", base .. "/")), ...)
            end
            system.getMemoryUsage = function()
                return { luaRamAvailable = 4 * 1024 * 1024 - math.floor(collectgarbage("count") * 1024) }
            end
        """, self.script_dir)
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


def readme_screenshots(out):
    """Fly the mission and save the README gameplay screenshots (800 x 480, full screen)."""
    sim = Sim(800, 480)
    g, shots = sim.g, {}
    sim.thr = -1
    for _ in range(30):
        sim.step(check=False)
    t0 = sim.clock
    while g.mode == "flight" and sim.clock - t0 < 240:
        sim.thr, sim.ail = autopilot(g, g.target)
        if not sim.step(check=False):
            continue
        # Passengers walking to the door at Ridge.
        if "boarding" not in shots and g.target == 2 and g.boarding is not None and g.boarding > 0.5:
            shots["boarding"] = sim.canvas.img.copy()
        # Heading home with all six, above Camp.
        if "return-to-base" not in shots and g.target == 1 and not g.support and g.x < 64 and g.y > 16:
            shots["return-to-base"] = sim.canvas.img.copy()
    for _ in range(40):
        sim.thr, sim.ail = -1, 0
        sim.step(check=False)
    shots["mission-complete"] = sim.canvas.img.copy()
    os.makedirs(out, exist_ok=True)
    for name, img in shots.items():
        img.save(os.path.join(out, name + ".png"), optimize=True)
    return sorted(shots)


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
    expect(g.perf and "FPS" in g.hud.title and "AT OPEN" in g.hud.build, "readout shows FPS and memory")
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
    ap.add_argument("--screenshots", help="save the README gameplay screenshots to this directory and stop")
    args = ap.parse_args()
    if args.screenshots:
        print("saved", ", ".join(readme_screenshots(args.screenshots)), "to", args.screenshots)
        return
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
    # Lazy loading: the System tile alone holds little Lua memory, and closing the game
    # gives back what opening it took.
    sim = Sim(w, h, open_tool=False)
    registered = sim.lua_kb()
    sim.open()
    for _ in range(60):
        sim.step(check=False)
    opened = sim.lua_kb()
    sim.close()
    closed = sim.lua_kb()
    for _ in range(5):
        sim.open()
        for _ in range(60):
            sim.step(check=False)
        sim.close()
    closed_again = sim.lua_kb()
    print(f"[memory] Lua heap: tile only {registered:.0f} KB, game open {opened:.0f} KB (+{opened - registered:.0f}), "
          f"after close {closed:.0f} KB, after five more openings {closed_again:.0f} KB")
    # Lua keeps a little of what the game grew (its string table shrinks lazily), but it must
    # not keep the game, and opening the game again must not add to it.
    if opened - registered < 20 or closed - registered > 15 or closed_again - closed > 1:
        print("   lazy loading check failed")
        failed = True

    for size in ((w, h), (790, 409)):
        sim = Sim(*size)
        failures = ui_flows(sim)
        print(f"[ui flows {size[0]}x{size[1]}] failed={failures or 'none'} paints={sim.paints} "
              f"mismatches={sim.mismatches} max paint instr={max(sim.paint_instr)}")
        failed = failed or bool(failures) or sim.mismatches > 0
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

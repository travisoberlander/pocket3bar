#!/usr/bin/env python3
"""Pocket 3 webcam-mode control panel.

Talks to the camera's standard UVC controls over USB (via the small IOKit helper
`uvcctl`), so it works while the camera is plugged in as a webcam.

  python3 server.py            then open http://localhost:8765

Gimbal note: the Pocket 3 only holds a commanded pan/tilt while it keeps
receiving it, so a background thread re-sends the target ~6x/second while
"hold" is on. Releasing lets the camera return to its own follow behaviour.
"""

import json
import os
import struct
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
UVCCTL = os.path.join(HERE, "uvcctl")
# Presets live outside the code folder (which may be inside the signed app bundle).
DATA_DIR = os.environ.get("POCKET3_DATA",
                          os.path.expanduser("~/Library/Application Support/Pocket3Bar"))
PRESETS_FILE = os.path.join(DATA_DIR, "presets.json")
PORT = int(os.environ.get("PORT", "8765"))

CT, XU = 1, 6                    # camera terminal / extension unit entity ids
ZOOM, PANTILT, ROLL = 11, 13, 15  # UVC selectors
ARCSEC = 3600
# Measured on the Pocket 3: USB moves stay on whichever side the camera faces, within
# these pan limits. (Moves can flip selfie to front if the camera body itself is
# leaning far forward; gimbal tilt alone, down to -90, is fine.)
PAN_LIMITS = {"front": (-35, 40), "selfie": (145, 215)}
GLIDE_TIMEOUT = 0.5   # s: a glide speed lapses (eases to a stop) if the page stops renewing it
GLIDE_EASE = 0.25     # s: time constant for easing between speeds

_lock = threading.Lock()


class CameraError(Exception):
    pass


def _run(*args):
    with _lock:
        r = subprocess.run([UVCCTL, *map(str, args)], capture_output=True, text=True, timeout=3)
    out = r.stdout.strip()
    if r.returncode != 0 or out.startswith("ERR"):
        raise CameraError(out or r.stderr.strip() or "camera not responding")
    return bytes.fromhex(out)


def get(req, sel, n):
    return _run("get", req, CT, sel, n)


def set_ctrl(sel, data: bytes):
    _run("set", CT, sel, data.hex())


def read_ranges():
    pt_min = struct.unpack("<ii", get("82", PANTILT, 8))
    pt_max = struct.unpack("<ii", get("83", PANTILT, 8))
    return {
        "pan": [pt_min[0] / ARCSEC, pt_max[0] / ARCSEC],
        "tilt": [pt_min[1] / ARCSEC, pt_max[1] / ARCSEC],
        "zoom": [struct.unpack("<H", get("82", ZOOM, 2))[0] / 100,
                 struct.unpack("<H", get("83", ZOOM, 2))[0] / 100],
        "roll": [struct.unpack("<h", get("82", ROLL, 2))[0],
                 struct.unpack("<h", get("83", ROLL, 2))[0]],
    }


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


class Gimbal:
    def __init__(self):
        self.ranges = None
        self.target = None   # (pan, tilt) degrees, or None when released
        self.hold = False
        # Glide mode (face tracking): the page sends a speed; the loop eases toward it
        # and moves the target a little on every tick instead of jumping.
        self.cmd_vel = (0.0, 0.0)   # deg/s requested by the page
        self.vel = (0.0, 0.0)       # deg/s actually applied (eased)
        self.vel_time = 0.0         # when the page last sent a speed
        threading.Thread(target=self._loop, daemon=True).start()

    def ensure(self):
        if self.ranges is None:
            self.ranges = read_ranges()

    def position(self):
        p, t = struct.unpack("<ii", get("81", PANTILT, 8))
        return p / ARCSEC, t / ARCSEC

    def _send(self, pan, tilt):
        set_ctrl(PANTILT, struct.pack("<ii", round(pan * ARCSEC), round(tilt * ARCSEC)))

    def goto(self, pan, tilt, facing=None):
        self.ensure()
        facing = facing or ("selfie" if pan > 90 else "front")
        pan = clamp(pan, *PAN_LIMITS[facing])
        tilt = clamp(tilt, *self.ranges["tilt"])
        self.target = (pan, tilt)
        self.cmd_vel = self.vel = (0.0, 0.0)   # a direct move cancels any glide
        self.hold = True
        self._send(pan, tilt)
        return self.target

    def nudge(self, dpan, dtilt):
        base = self.target or self.position()
        # stay on the side the camera is already facing
        return self.goto(base[0] + dpan, base[1] + dtilt, "selfie" if base[0] > 90 else "front")

    def glide(self, vpan, vtilt):
        """Set a pan/tilt speed in deg/s; it lapses if not renewed within GLIDE_TIMEOUT."""
        if self.target is None:
            self.ensure()
            p, t = self.position()
            self.target = (p, t)
            self.hold = True
        self.cmd_vel = (vpan, vtilt)
        self.vel_time = time.time()

    def release(self):
        self.hold = False
        self.target = None
        self.cmd_vel = self.vel = (0.0, 0.0)

    def _loop(self):
        last_check = 0.0
        last = time.time()
        while True:
            now = time.time()
            dt, last = min(now - last, 0.2), now
            gliding = False
            if self.hold and self.target:
                try:
                    # If the camera was flipped by hand (front <-> selfie), stop holding
                    # the old side or we'd drag it back.
                    if now - last_check > 1.0:
                        last_check = now
                        if (self.position()[0] > 90) != (self.target[0] > 90):
                            self.release()
                            continue
                    cmd = self.cmd_vel if now - self.vel_time < GLIDE_TIMEOUT else (0.0, 0.0)
                    a = min(1.0, dt / GLIDE_EASE)          # ease speed changes in and out
                    v = tuple(o + (c - o) * a for o, c in zip(self.vel, cmd))
                    self.vel = tuple(0.0 if abs(x) < 0.05 else x for x in v)
                    if self.vel != (0.0, 0.0) and self.target:
                        side = "selfie" if self.target[0] > 90 else "front"
                        self.target = (clamp(self.target[0] + self.vel[0] * dt, *PAN_LIMITS[side]),
                                       clamp(self.target[1] + self.vel[1] * dt, *self.ranges["tilt"]))
                        gliding = True
                    if self.target:
                        self._send(*self.target)
                except Exception:
                    pass
            time.sleep(0.04 if gliding else 0.16)


gimbal = Gimbal()


def load_presets():
    try:
        with open(PRESETS_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_presets(p):
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(PRESETS_FILE, "w") as f:
        json.dump(p, f, indent=2)


def state():
    gimbal.ensure()
    pan, tilt = gimbal.position()
    return {
        "connected": True,
        "pan": round(pan, 1), "tilt": round(tilt, 1),
        "zoom": struct.unpack("<H", get("81", ZOOM, 2))[0] / 100,
        "roll": struct.unpack("<h", get("81", ROLL, 2))[0],
        "hold": gimbal.hold,
        "facing": "selfie" if pan > 90 else "front",
        "target": [round(x, 2) for x in gimbal.target] if gimbal.target else None,
        "ranges": gimbal.ranges,
        "presets": load_presets(),
    }


def handle(path, body):
    if path == "/api/state":
        return state()
    if path == "/api/glide":
        # Face tracker: a pan/tilt speed in deg/s, renewed several times a second.
        gimbal.glide(float(body.get("pan", 0)), float(body.get("tilt", 0)))
        return {"ok": True}
    if path == "/api/track":
        # Small relative step from the panel's face tracker. Kept light (no full state
        # read) because it is called several times a second.
        t = gimbal.nudge(float(body.get("pan", 0)), float(body.get("tilt", 0)))
        return {"ok": True, "target": t}
    if path == "/api/goto":
        gimbal.goto(float(body["pan"]), float(body["tilt"]))
    elif path == "/api/nudge":
        gimbal.nudge(float(body.get("pan", 0)), float(body.get("tilt", 0)))
    elif path == "/api/release":
        gimbal.release()
    elif path == "/api/level":
        cur = gimbal.target or gimbal.position()
        gimbal.goto(cur[0], 0, "selfie" if cur[0] > 90 else "front")
    elif path == "/api/zoom":
        gimbal.ensure()
        z = clamp(float(body["zoom"]), *gimbal.ranges["zoom"])
        set_ctrl(ZOOM, struct.pack("<H", round(z * 100)))
    elif path == "/api/roll":
        gimbal.ensure()
        r = clamp(int(body["roll"]), *gimbal.ranges["roll"])
        set_ctrl(ROLL, struct.pack("<h", r))
    elif path == "/api/preset/save":
        p = load_presets()
        s = state()
        p[str(body["slot"])] = {"pan": s["target"][0] if s["target"] else s["pan"],
                                "tilt": s["target"][1] if s["target"] else s["tilt"],
                                "zoom": s["zoom"], "roll": s["roll"]}
        save_presets(p)
    elif path == "/api/preset/recall":
        p = load_presets().get(str(body["slot"]))
        if not p:
            raise CameraError("empty preset")
        cur = gimbal.target or gimbal.position()
        if (p["pan"] > 90) != (cur[0] > 90):
            raise CameraError("that preset was saved while " + ("selfie" if p["pan"] > 90 else "front-facing")
                              + "; flip the camera to that side first")
        set_ctrl(ZOOM, struct.pack("<H", round(p["zoom"] * 100)))
        set_ctrl(ROLL, struct.pack("<h", int(p["roll"])))
        gimbal.goto(p["pan"], p["tilt"])
    else:
        raise KeyError(path)
    return state()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj, ctype="application/json"):
        data = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _api(self, body):
        try:
            self._send(200, handle(self.path, body))
        except KeyError:
            self._send(404, {"error": "not found"})
        except Exception as e:
            self._send(503, {"connected": False, "error": str(e)})

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            with open(os.path.join(HERE, "panel.html"), "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        self._api({})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        self._api(body)


if __name__ == "__main__":
    if not os.path.exists(UVCCTL):
        raise SystemExit("uvcctl helper missing; build it with: clang -O2 -o uvcctl uvcctl.c "
                         "-framework IOKit -framework CoreFoundation")
    print(f"Pocket 3 control panel on http://localhost:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

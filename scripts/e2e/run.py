#!/usr/bin/env python3
"""End-to-end checks of the real app on a real Mac desktop.

Run with: python3 scripts/e2e/run.py [--media DIR] [--artifacts DIR]

It uses a throwaway library and settings, so a person's own wallpapers are never touched. It does take
over the screen for a few minutes: open apps are hidden, test windows appear, and focus moves around.
Hidden apps are restored at the end, including after a failure.

DIR holds optional media: any GIF, MP4 or MOV in it is imported too, as a check on real files.
"""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "dist/debug/Lull.app/Contents/MacOS/Lull"
CONTROL = ROOT / ".build/e2e-control"


class Run:
    def __init__(self, artifacts):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="lull-e2e-"))
        self.library = self.tmp / "library"
        self.state_path = self.tmp / "state.json"
        self.hidden_list = self.tmp / "hidden.txt"
        self.artifacts = pathlib.Path(artifacts) if artifacts else self.tmp / "artifacts"
        self.artifacts.mkdir(parents=True, exist_ok=True)
        self.defaults = f"lull-e2e-{os.getpid()}"
        self.process = None
        self.passed = 0
        self.failures = []

    # --- Plumbing ---

    def control(self, *args):
        return subprocess.run([str(CONTROL), *map(str, args)], capture_output=True, text=True).stdout.strip()

    def launch(self):
        env = dict(os.environ, LULL_DEBUG_ROOT=str(self.library), LULL_DEBUG_STATE=str(self.state_path), LULL_DEBUG_DEFAULTS=self.defaults)
        self.state_path.unlink(missing_ok=True)
        self.process = subprocess.Popen([str(APP)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.wait("app started", lambda s: True, timeout=10)

    def quit(self):
        if self.process and self.process.poll() is None:
            self.send("quit")
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None

    def send(self, command):
        self.control("send", command)
        time.sleep(0.1)

    def state(self):
        for _ in range(20):
            try:
                return json.loads(self.state_path.read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                time.sleep(0.05)
        return {}

    def check(self, name, condition, detail=""):
        if condition:
            self.passed += 1
            print(f"  ok    {name}")
        else:
            self.failures.append(name)
            print(f"  FAIL  {name} {detail}")

    def wait(self, name, predicate, timeout=6, report=True):
        deadline = time.time() + timeout
        state = {}
        while time.time() < deadline:
            state = self.state()
            if state and predicate(state):
                if report:
                    self.check(name, True)
                return state
            time.sleep(0.1)
        if report:
            self.check(name, False, json.dumps(state, sort_keys=True)[:600])
        return state

    def section(self, title):
        print(f"\n{title}")

    def footprint_mb(self):
        out = subprocess.run(["footprint", str(self.process.pid)], capture_output=True, text=True).stdout
        for line in out.splitlines():
            if "Footprint:" in line:
                parts = line.split("Footprint:")[1].split()
                value, unit = float(parts[0]), parts[1]
                return value / 1024 if unit == "KB" else value
        return -1

    def cpu_percent(self, seconds=6):
        """CPU of the app and decoder as a percentage of one core, and WindowServer's, from top."""
        out = subprocess.run(
            ["top", "-l", str(int(seconds / 2) + 1), "-s", "2", "-n", "300", "-o", "cpu", "-stats", "pid,command,cpu,rsize"],
            capture_output=True, text=True,
        ).stdout
        blocks = out.split("Processes:")[2:]
        totals = {"app": 0.0, "decoder": 0.0, "windowserver": 0.0}
        memory = {"decoder": ""}
        for block in blocks:
            for line in block.splitlines():
                fields = line.split()
                if len(fields) < 4:
                    continue
                try:
                    pid, cpu = int(fields[0]), float(fields[-2])
                except ValueError:
                    continue
                command = " ".join(fields[1:-2])
                if pid == self.process.pid:
                    totals["app"] += cpu
                elif command.startswith("VTDecoder"):
                    totals["decoder"] += cpu
                    if fields[-1].rstrip("+-").endswith("M"):
                        memory["decoder"] = fields[-1]
                elif command == "WindowServer":
                    totals["windowserver"] += cpu
        count = max(len(blocks), 1)
        return {k: round(v / count, 1) for k, v in totals.items()} | memory

    def cover(self, mode, seconds):
        return subprocess.Popen([str(CONTROL), "cover", mode, str(seconds)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def advancing(self):
        first = self.state().get("engineTime", 0)
        time.sleep(0.7)
        second = self.state().get("engineTime", 0)
        return first != second

    def go_to_desktop(self):
        self.control("activate", "com.apple.finder")

    # --- Media ---

    def make_media(self):
        media = self.tmp / "media"
        media.mkdir()
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            sys.exit("ffmpeg is needed to generate test media")
        def run(*args):
            subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", *args], check=True)
        source = "testsrc2=s=320x180:r=15:d=3"
        run("-f", "lavfi", "-i", source, "-vf", "split[a][b];[a]palettegen[p];[b][p]paletteuse", str(media / "chart.gif"))
        run("-f", "lavfi", "-i", "testsrc2=s=1280x720:r=120:d=3", "-c:v", "hevc_videotoolbox", "-b:v", "12M", "-tag:v", "hvc1", "-an", str(media / "fast.mp4"))
        (media / "broken.gif").write_text("this is not a gif")
        return media


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--media")
    parser.add_argument("--artifacts")
    options = parser.parse_args()

    subprocess.run(["swiftc", "-O", "-swift-version", "5", str(ROOT / "scripts/e2e/control.swift"), "-o", str(CONTROL)], check=True)
    subprocess.run([str(ROOT / "scripts/build-app.sh"), "debug"], check=True, stdout=subprocess.DEVNULL)

    run = Run(options.artifacts)
    media = run.make_media()
    run.control("hide-apps", run.hidden_list)
    try:
        scenario(run, media, options.media)
    finally:
        run.quit()
        run.control("show-apps", run.hidden_list)
        subprocess.run(["defaults", "delete", run.defaults], capture_output=True)
        shutil.rmtree(run.tmp, ignore_errors=True)

    print(f"\n{run.passed} passed, {len(run.failures)} failed")
    for failure in run.failures:
        print(f"  failed: {failure}")
    sys.exit(1 if run.failures else 0)


def scenario(run, media, extra_media):
    run.section("Empty start")
    run.launch()
    state = run.state()
    run.check("no windows before there's a wallpaper", state["engineWindows"] == 0)
    run.check("no player before there's a wallpaper", not state["enginePlayerLoaded"])
    run.check("nothing to report in the status line", state["status"] == "")
    time.sleep(1)
    print(f"        idle memory with no wallpaper: {run.footprint_mb():.1f} MB")

    run.section("Bad files")
    run.send(f"import {media / 'broken.gif'}")
    state = run.wait("a broken file shows a friendly message", lambda s: "Can't open this file" in s["message"])
    run.check("a broken file adds nothing", state["wallpaperCount"] == 0)

    run.section("Importing a GIF")
    run.send(f"import {media / 'chart.gif'}")
    state = run.wait("the GIF imports and becomes the wallpaper", lambda s: s["wallpaperCount"] == 1 and s["currentName"] == "chart", timeout=30)
    run.check("small GIF is enlarged", state["width"] == 1280 and state["height"] == 720, str(state))
    run.check("it has a desktop window", state["engineWindows"] >= 1)
    windows = run.control("windows", run.process.pid)
    level = run.control("level")
    print(f"        window server: {windows.splitlines()[:2]} {level}")
    desktop_level = level.split()[0].split("=")[1]
    run.check("the window sits at desktop level", f"layer={desktop_level}" in windows, windows)

    run.section("Desktop Focus")
    run.go_to_desktop()
    run.wait("clicking through to Finder starts playback", lambda s: s["finderFront"] and s["engineWantsPlaying"] and s["enginePlayerLoaded"] and s["enginePlayerRate"] > 0)
    run.check("time advances while playing", run.advancing())
    usage = run.cpu_percent()
    print(f"        playing a GIF at its own speed: {usage}, app footprint {run.footprint_mb():.1f} MB")
    (run.artifacts / "desktop-playing.png").unlink(missing_ok=True)
    subprocess.run(["screencapture", "-x", str(run.artifacts / "desktop-playing.png")], capture_output=True)

    focus = run.cover("focus", 8)
    run.wait("another app taking focus pauses it", lambda s: not s["finderFront"] and not s["engineWantsPlaying"])
    state = run.wait("the player is fully unloaded while paused", lambda s: not s["enginePlayerLoaded"])
    paused_at = state["engineTime"]
    time.sleep(1)
    run.check("time doesn't advance while paused", run.state()["engineTime"] == paused_at)
    usage = run.cpu_percent()
    run.check("paused CPU is effectively zero", usage["app"] + usage["decoder"] < 0.5, str(usage))
    print(f"        paused: {usage}, app footprint {run.footprint_mb():.1f} MB")
    focus.kill()
    run.go_to_desktop()
    state = run.wait("returning to the desktop resumes it", lambda s: s["engineWantsPlaying"] and s["enginePlayerRate"] > 0)
    run.check("it resumes from where it stopped", abs(state["engineTime"] - paused_at) < 1.0, f"{paused_at} then {state['engineTime']}")

    run.section("Coverage while the desktop is focused")
    cover = run.cover("full", 6)
    run.wait("a full-screen window pauses it", lambda s: not s["desktopOpen"] and not s["engineWantsPlaying"])
    cover.wait()
    run.wait("removing the window resumes it", lambda s: s["desktopOpen"] and s["engineWantsPlaying"])
    cover = run.cover("maximized", 6)
    run.wait("a maximized window pauses it", lambda s: not s["desktopOpen"] and not s["engineWantsPlaying"])
    cover.wait()
    run.wait("removing the maximized window resumes it", lambda s: s["desktopOpen"] and s["engineWantsPlaying"])
    cover = run.cover("partial", 4)
    time.sleep(3)
    run.check("a partial window doesn't pause it", run.state()["engineWantsPlaying"])
    cover.wait()

    run.section("Whenever Visible")
    run.send("rule visible")
    focus = run.cover("focus", 4)
    time.sleep(1.5)
    state = run.state()
    run.check("another app having focus doesn't pause it", not state["finderFront"] and state["engineWantsPlaying"], str(state))
    run.check("status line follows the rule", state["status"] == "Plays when the desktop is visible", state["status"])
    focus.wait()
    full = run.cover("fullscreen", 6)
    run.wait("native full screen pauses it", lambda s: not s["desktopOpen"] and not s["engineWantsPlaying"], timeout=7)
    full.wait()
    run.wait("leaving full screen resumes it", lambda s: s["desktopOpen"] and s["engineWantsPlaying"], timeout=7)
    run.send("rule focus")
    run.go_to_desktop()
    run.wait("back on Desktop Focus and playing", lambda s: s["rule"] == "desktopFocus" and s["engineWantsPlaying"])

    run.section("Panel")
    focus = run.cover("focus", 6)
    run.wait("paused before opening the panel", lambda s: not s["engineWantsPlaying"])
    run.send("panel open")
    run.wait("opening the panel plays it, so the preview is live", lambda s: s["panelOpen"] and s["engineWantsPlaying"])
    time.sleep(0.8)
    run.send(f"snapshot {run.artifacts / 'panel-animated.png'}")
    time.sleep(0.3)
    run.check("panel renders", (run.artifacts / "panel-animated.png").exists())
    run.send("panel close")
    run.wait("closing the panel goes back to the rule", lambda s: not s["panelOpen"] and not s["engineWantsPlaying"])
    focus.kill()
    run.go_to_desktop()
    run.wait("desktop focus plays again", lambda s: s["engineWantsPlaying"])

    run.send("panel open")
    run.wait("panel opens from the desktop", lambda s: s["panelOpen"])
    time.sleep(0.3)
    run.check("opening the panel doesn't count as leaving the desktop", run.state()["finderFront"])
    run.send("panel close")
    run.wait("panel closes", lambda s: not s["panelOpen"])
    time.sleep(0.5)
    run.check("focus returns after closing the panel", run.control("front") == "com.apple.finder", run.control("front"))
    state = run.state()
    run.check("the wallpaper is still playing after the panel closes", state["engineWantsPlaying"] and state["enginePlayerRate"] > 0, str(state))
    run.check("the desktop window survived hiding the app", state["engineWindows"] >= 1 and "layer=" in run.control("windows", run.process.pid))

    run.section("Still or Animated")
    run.send("mode still")
    state = run.wait("switching to Still stops the player", lambda s: s["mode"] == "still" and not s["enginePlayerLoaded"] and not s["engineWantsPlaying"])
    run.check("status line says still", state["status"] == "Still wallpaper")
    run.check("it freezes on the frame that was showing", 0 <= state["stillFrame"] < state["frameCount"], str(state))
    usage = run.cpu_percent()
    run.check("a still wallpaper costs effectively nothing", usage["app"] + usage["decoder"] < 0.5, str(usage))
    print(f"        still wallpaper: {usage}, app footprint {run.footprint_mb():.1f} MB")
    run.send("panel open")
    run.wait("panel opens on a still wallpaper", lambda s: s["panelOpen"])
    time.sleep(0.5)
    run.check("the panel doesn't start a still wallpaper", not run.state()["engineWantsPlaying"])
    for frame in [5, 10, 20]:
        run.send(f"scrub {frame}")
    run.send("frame 20")
    run.wait("the slider sets the frame", lambda s: s["stillFrame"] == 20)
    time.sleep(0.5)
    run.send(f"snapshot {run.artifacts / 'panel-still.png'}")
    time.sleep(0.3)
    run.send("panel close")
    run.wait("panel closes", lambda s: not s["panelOpen"])
    run.send("mode animated")
    run.wait("switching back to Animated plays again", lambda s: s["mode"] == "animated" and s["engineWantsPlaying"] and s["enginePlayerRate"] > 0)

    run.section("Smooth Motion")
    run.send("smooth on")
    state = run.wait("Smooth Motion finishes and takes over", lambda s: s["smoothMotion"] and not s["versionWorking"] and s["playbackFile"] == "smooth-120.mp4" and s["enginePlayerRate"] > 0, timeout=60)
    run.check("the panel shows no error", state["message"] == "" or "Can't open" in state["message"], state["message"])
    time.sleep(1.5)
    usage = run.cpu_percent()
    print(f"        GIF with Smooth Motion at 120: {usage}, app footprint {run.footprint_mb():.1f} MB")
    run.send("rate 60")
    state = run.wait("changing the rate makes that version", lambda s: s["playbackFile"] == "smooth-60.mp4" and not s["versionWorking"] and s["enginePlayerRate"] > 0, timeout=60)
    run.send("smooth off")
    state = run.wait("turning it off goes back to the original", lambda s: not s["smoothMotion"] and s["playbackFile"] == "prepared.mp4" and s["enginePlayerRate"] > 0)
    run.send("smooth on")
    run.wait("turning it back on reuses the saved version", lambda s: s["smoothMotion"] and s["playbackFile"] == "smooth-60.mp4" and s["enginePlayerRate"] > 0 and not s["versionWorking"], timeout=3)
    run.send("smooth off")
    run.wait("off again", lambda s: not s["smoothMotion"])

    run.section("Video and frame limit")
    run.send(f"import {media / 'fast.mp4'}")
    state = run.wait("a 120 FPS video imports", lambda s: s["wallpaperCount"] == 2 and s["currentName"] == "fast" and s["pendingImports"] == 0, timeout=30)
    run.check("it reports its frame rate", abs(state["sourceFPS"] - 120) < 1, str(state["sourceFPS"]))
    run.wait("it plays", lambda s: s["enginePlayerRate"] > 0, timeout=5)
    time.sleep(1.5)
    print(f"        720p video at 120: {run.cpu_percent()}, app footprint {run.footprint_mb():.1f} MB")
    run.send("limit 30")
    run.wait("a frame limit makes a slower version", lambda s: s["playbackFile"] == "limit-30.mp4" and not s["versionWorking"] and s["enginePlayerRate"] > 0, timeout=30)
    time.sleep(1.5)
    print(f"        same video limited to 30: {run.cpu_percent()}")
    run.send("limit none")
    run.wait("clearing the limit returns to the original", lambda s: s["playbackFile"] == "prepared.mp4" and s["enginePlayerRate"] > 0)

    run.section("Switching and relaunching")
    run.send("select 0")
    run.wait("selecting another wallpaper switches to it", lambda s: s["currentName"] == "chart" and s["enginePlayerRate"] > 0)
    run.quit()
    run.check("quitting ends the app", run.process is None)
    run.launch()
    state = run.wait("relaunching restores the wallpaper", lambda s: s["currentName"] == "chart" and s["wallpaperCount"] == 2 and s["engineWindows"] >= 1)
    run.wait("and it plays straight away with the desktop focused", lambda s: s["enginePlayerRate"] > 0)

    run.section("Damage")
    current_folder = next(p for p in (run.library).iterdir() if (p / "original.gif").exists())
    run.quit()
    (current_folder / "prepared.mp4").unlink()
    run.launch()
    run.wait("a missing prepared file is rebuilt from the original", lambda s: s["currentName"] == "chart" and s["enginePlayerRate"] > 0 and not s["versionWorking"], timeout=30)
    run.check("the file is back", (current_folder / "prepared.mp4").exists())

    other_folder = next(p for p in (run.library).iterdir() if not (p / "original.gif").exists() and p.is_dir())
    run.quit()
    (other_folder / "prepared.mp4").unlink()
    run.launch()
    run.wait("a wallpaper with no files left is reported missing", lambda s: s["missing"] == 1)
    state = run.state()
    run.check("the rest of the library still works", state["currentName"] == "chart" and state["wallpaperCount"] == 2)
    run.send("delete 1")
    run.wait("a missing wallpaper can be removed", lambda s: s["wallpaperCount"] == 1 and s["missing"] == 0)

    if extra_media:
        run.section("Real files")
        before = run.state()["wallpaperCount"]
        for file in sorted(pathlib.Path(extra_media).iterdir()):
            if file.suffix.lower() not in {".gif", ".mp4", ".mov"}:
                continue
            run.send(f"import {file}")
            before += 1
            state = run.wait(f"imports {file.name}", lambda s: s["wallpaperCount"] == before and s["pendingImports"] == 0, timeout=120)
            print(f"        {state['width']}x{state['height']}, {state['frameCount']} frames at {state['sourceFPS']:.1f} FPS")
            run.wait(f"plays {file.name}", lambda s: s["enginePlayerRate"] > 0, timeout=5)
            time.sleep(0.5)
            run.send("smooth on")
            run.wait(f"Smooth Motion finishes on {file.name}", lambda s: not s["versionWorking"] and s["enginePlayerRate"] > 0, timeout=300)
            run.send("smooth off")

    run.section("Deleting")
    count = run.state()["wallpaperCount"]
    run.send("select 0")
    time.sleep(0.5)
    while count > 0:
        run.send("delete 0")
        count -= 1
        run.wait(f"delete leaves {count}", lambda s: s["wallpaperCount"] == count, timeout=4)
    state = run.state()
    run.check("deleting the active wallpaper removes its windows", state["engineWindows"] == 0, str(state))
    run.check("nothing is left playing", not state["enginePlayerLoaded"])
    time.sleep(1)
    print(f"        idle memory after deleting everything: {run.footprint_mb():.1f} MB")


if __name__ == "__main__":
    main()

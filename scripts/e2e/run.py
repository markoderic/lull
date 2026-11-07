#!/usr/bin/env python3
"""End-to-end checks of the real app on a real Mac desktop.

Run with: python3 scripts/e2e/run.py [--media DIR] [--artifacts DIR]

It uses a throwaway library and settings, so a person's own wallpapers are never touched. It does take
over the screen for a few minutes: open apps are hidden, test windows appear, and focus moves around.
Hidden apps are restored at the end, including after a failure.

DIR holds optional media: any GIF, MP4 or MOV in it is imported too, as a check on real files.
"""
import argparse
import datetime
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
CONTROL_APP = ROOT / ".build/e2e-control.app"
CONTROL = CONTROL_APP / "Contents/MacOS/e2e-control"


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
        memory = {"decoderMemory": ""}
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
                        memory["decoderMemory"] = fields[-1]
                elif command == "WindowServer":
                    totals["windowserver"] += cpu
        count = max(len(blocks), 1)
        return {k: round(v / count, 1) for k, v in totals.items()} | memory

    def cover(self, mode, seconds):
        """Opens a test window. Launched through LaunchServices, because modern macOS only lets
        an app take focus at launch if it was started the way a person would start it."""
        log = open(self.tmp / "cover.log", "a")
        process = subprocess.Popen(
            ["open", "-n", "-W", str(CONTROL_APP), "--args", "cover", mode, str(seconds)],
            stdout=log, stderr=log,
        )
        return process

    def end_covers(self):
        subprocess.run(["pkill", "-f", "e2e-control.app/Contents/MacOS/e2e-control"], capture_output=True)

    def advancing(self):
        first = self.state().get("engineTime", 0)
        time.sleep(0.7)
        second = self.state().get("engineTime", 0)
        return first != second

    def go_to_desktop(self):
        subprocess.run(["open", "-a", "Finder"], capture_output=True)

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
        run("-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=8", "-vf", "split[a][b];[a]palettegen[p];[b][p]paletteuse", str(media / "long.gif"))
        run("-f", "lavfi", "-i", "testsrc2=s=1080x1920:r=60:d=5", "-c:v", "hevc_videotoolbox", "-b:v", "12M", "-tag:v", "hvc1", "-an", str(media / "vertical.mp4"))
        (media / "broken.gif").write_text("this is not a gif")
        return media


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--media")
    parser.add_argument("--artifacts")
    parser.add_argument("--races-only", action="store_true")
    parser.add_argument("--panel-only", action="store_true")
    parser.add_argument("--schedule-only", action="store_true")
    parser.add_argument("--speed-only", action="store_true")
    parser.add_argument("--cleanup-only", action="store_true")
    parser.add_argument("--hardened", action="store_true", help="test under the security settings a signed release uses")
    options = parser.parse_args()

    CONTROL.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-O", "-swift-version", "5", str(ROOT / "scripts/e2e/control.swift"), "-o", str(CONTROL)], check=True)
    (CONTROL_APP / "Contents/Info.plist").write_text("""<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.markoderic.lull.e2e-control</string>
<key>CFBundleExecutable</key><string>e2e-control</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
""")
    subprocess.run(["codesign", "--force", "--sign", "-", str(CONTROL_APP)], capture_output=True)
    build_env = dict(os.environ, HARDENED="1") if options.hardened else None
    subprocess.run([str(ROOT / "scripts/build-app.sh"), "debug"], check=True, stdout=subprocess.DEVNULL, env=build_env)
    signature = subprocess.run(["codesign", "-d", "--verbose=2", str(ROOT / "dist/debug/Lull.app")], capture_output=True, text=True).stderr
    print(next((line for line in signature.splitlines() if "flags=" in line), "no signature found"))

    run = Run(options.artifacts)
    media = run.make_media()
    # These checks don't need a bare desktop, so they leave open apps alone.
    if not (options.schedule_only or options.speed_only or options.cleanup_only):
        run.control("hide-apps", run.hidden_list)
    try:
        if options.cleanup_only:
            library_cleanup(run, media)
        elif options.schedule_only:
            day_and_night(run, media)
        elif options.speed_only:
            playback_speed(run, media)
        elif options.panel_only:
            panel_rules(run, media)
        else:
            if not options.races_only:
                scenario(run, media, options.media)
                run.quit()
            races(run, media)
            run.quit()
            panel_rules(run, media)
            run.quit()
            fit_to_screen(run, media)
            run.quit()
            day_and_night(run, media)
            run.quit()
            playback_speed(run, media)
            run.quit()
            library_cleanup(run, media)
    finally:
        run.end_covers()
        run.quit()
        run.control("show-apps", run.hidden_list)
        subprocess.run(["defaults", "delete", run.defaults], capture_output=True)
        if (run.tmp / "cover.log").exists():
            shutil.copy(run.tmp / "cover.log", run.artifacts / "cover.log")
        shutil.rmtree(run.tmp, ignore_errors=True)

    print(f"\n{run.passed} passed, {len(run.failures)} failed")
    for failure in run.failures:
        print(f"  failed: {failure}")
    if (run.artifacts / "cover.log").exists():
        print((run.artifacts / "cover.log").read_text()[:800])
    sys.exit(1 if run.failures else 0)


def library_cleanup(run, media):
    """Deleting several wallpapers at once."""
    shutil.rmtree(run.library, ignore_errors=True)
    run.launch()
    time.sleep(1)
    for index, name in enumerate(("chart.gif", "vertical.mp4", "fast.mp4", "long.gif")):
        run.send(f"import {media / name}")
        run.wait(f"{name} imports", lambda s: s["wallpaperCount"] == index + 1 and s["pendingImports"] == 0, timeout=60)
    folders = lambda: [p for p in run.library.iterdir() if p.is_dir()]
    run.check("each wallpaper has a folder", len(folders()) == 4)

    run.section("Clean Up Library")
    run.send("panel open")
    run.wait("panel opens", lambda s: s["panelOpen"])
    run.send("cleanup start")
    state = run.wait("clean up starts", lambda s: s["cleaningUp"])
    run.check("it says how big the library is", state["cleanupSummary"].startswith("4 wallpapers, "), state["cleanupSummary"])
    run.check("nothing is selected yet", state["cleanupSelected"] == 0)
    print(f"        {state['cleanupSummary']}")
    time.sleep(0.5)
    run.send("cleanup 0")
    run.send("cleanup 1")
    state = run.wait("wallpapers can be selected", lambda s: s["cleanupSelected"] == 2)
    run.check("it says how much space they free", state["cleanupSummary"].startswith("2 of 4 selected, "), state["cleanupSummary"])
    print(f"        {state['cleanupSummary']}")
    run.send("appearance dark")
    time.sleep(0.5)
    run.send(f"snapshot {run.artifacts / 'panel-cleanup-dark.png'}")
    time.sleep(0.2)
    run.send("cleanup 1")
    run.wait("and deselected", lambda s: s["cleanupSelected"] == 1)
    run.send("cleanup 1")
    run.wait("selected again", lambda s: s["cleanupSelected"] == 2)

    run.section("Deleting a selection")
    run.send("cleanup delete")
    state = run.wait("they're removed", lambda s: s["wallpaperCount"] == 2 and s["cleanupSelected"] == 0)
    run.check("it confirms what happened", state["message"] == "Moved 2 wallpapers to the Trash.", state["message"])
    run.check("the rest stay", state["cleaningUp"])
    run.check("their folders are gone", len(folders()) == 2)
    run.check("the wallpaper on screen wasn't touched", state["currentName"] == "long" and state["engineWindows"] >= 1, str(state))
    run.send("cleanup done")
    run.wait("Done goes back to the panel", lambda s: not s["cleaningUp"])

    run.section("Deleting the wallpaper on screen")
    run.send("cleanup start")
    run.send("cleanup all")
    run.wait("Select All selects everything", lambda s: s["cleanupSelected"] == 2)
    run.send("cleanup all")
    run.wait("and deselects it", lambda s: s["cleanupSelected"] == 0)
    run.send("cleanup 1")
    run.send("cleanup delete")
    state = run.wait("the current wallpaper can be deleted", lambda s: s["wallpaperCount"] == 1)
    run.check("the normal wallpaper comes back", state["engineWindows"] == 0 and not state["enginePlayerLoaded"], str(state))
    run.check("it says so once", state["message"] == "Moved 1 wallpaper to the Trash.", state["message"])
    run.send("cleanup done")
    run.wait("Done", lambda s: not s["cleaningUp"])
    time.sleep(0.4)
    run.send(f"snapshot {run.artifacts / 'panel-choose-dark.png'}")
    time.sleep(0.2)

    run.section("Clearing the library")
    run.send("cleanup start")
    run.send("cleanup all")
    run.send("cleanup delete")
    state = run.wait("everything can go", lambda s: s["wallpaperCount"] == 0)
    run.check("clean up ends by itself", not state["cleaningUp"])
    run.check("nothing is left on disk", len(folders()) == 0)
    run.send("panel close")
    run.wait("panel closes", lambda s: not s["panelOpen"])

    run.section("Leaving part way")
    run.send(f"import {media / 'chart.gif'}")
    run.wait("a wallpaper imports", lambda s: s["wallpaperCount"] == 1, timeout=30)
    run.send("panel open")
    run.wait("panel opens", lambda s: s["panelOpen"])
    run.send("cleanup start")
    run.send("cleanup 0")
    run.wait("selected", lambda s: s["cleanupSelected"] == 1)
    run.send("panel close")
    state = run.wait("closing the panel cancels it", lambda s: not s["panelOpen"] and not s["cleaningUp"])
    run.check("and deletes nothing", state["wallpaperCount"] == 1)


def playback_speed(run, media):
    """The panel's preview plays whatever else is going on, so this works with other apps open."""
    shutil.rmtree(run.library, ignore_errors=True)
    run.launch()
    time.sleep(1)
    run.send(f"import {media / 'long.gif'}")
    run.wait("a wallpaper imports", lambda s: s["wallpaperCount"] == 1, timeout=60)
    run.send("panel open")
    state = run.wait("it plays at normal speed", lambda s: s["panelOpen"] and s["enginePlayerRate"] == 1 and s["previewReady"])
    run.check("normal is the default", state["speed"] == 1)

    def real_speed(seconds=2.0, loop=8.0):
        """Measures how fast the video really moves, rather than trusting the setting."""
        first = run.state()["engineTime"]
        started = time.time()
        time.sleep(seconds)
        moved = (run.state()["engineTime"] - first) % loop
        return moved / (time.time() - started)

    run.section("Changing speed")
    for speed in (0.25, 0.5, 1.5, 2):
        run.send(f"speed {speed}")
        run.wait(f"{speed}x takes effect right away", lambda s: abs(s["enginePlayerRate"] - speed) < 0.01, timeout=2)
        time.sleep(0.3)
        measured = real_speed()
        print(f"        set {speed}, measured {measured:.2f}")
        run.check(f"the video really moves at {speed}x", abs(measured - speed) < speed * 0.2 + 0.05, f"measured {measured:.2f}")

    run.section("Keeping it")
    run.send("speed 0.5")
    run.wait("set to half speed", lambda s: abs(s["enginePlayerRate"] - 0.5) < 0.01, timeout=2)
    run.send("panel close")
    run.wait("panel closes", lambda s: not s["panelOpen"])
    time.sleep(0.5)
    run.send("panel open")
    run.wait("it keeps its speed after a pause", lambda s: s["panelOpen"] and abs(s["enginePlayerRate"] - 0.5) < 0.01)
    run.send("mode still")
    run.wait("switched to Still", lambda s: s["mode"] == "still" and not s["enginePlayerLoaded"])
    run.send("mode animated")
    run.wait("and after Still and back", lambda s: s["mode"] == "animated" and abs(s["enginePlayerRate"] - 0.5) < 0.01)

    run.section("With Smooth Motion")
    run.send("speed 0.25")
    state = run.wait("a quarter speed suggests Smooth Motion", lambda s: "Smooth Motion keeps it fluid" in s["speedHint"], timeout=2)
    print(f"        {state['speedHint']}")
    run.send("smooth on")
    state = run.wait("it keeps its speed on the new version", lambda s: s["playbackFile"] == "smooth-120.mp4" and not s["versionWorking"] and abs(s["enginePlayerRate"] - 0.25) < 0.01, timeout=120)
    run.check("the suggestion goes away", state["speedHint"] == "", state["speedHint"])
    run.send("smooth off")
    run.wait("Smooth Motion off", lambda s: not s["smoothMotion"])

    run.section("Per wallpaper")
    run.send(f"import {media / 'fast.mp4'}")
    state = run.wait("another wallpaper starts at normal speed", lambda s: s["currentName"] == "fast" and s["pendingImports"] == 0 and s["enginePlayerRate"] == 1, timeout=30)
    run.check("its own setting is normal", state["speed"] == 1)
    time.sleep(1)
    print(f"        720p at 120 FPS, normal: {run.cpu_percent()}")
    run.send("speed 0.25")
    run.wait("slowed down", lambda s: abs(s["enginePlayerRate"] - 0.25) < 0.01, timeout=2)
    time.sleep(1)
    print(f"        720p at 120 FPS, 0.25x: {run.cpu_percent()}")
    run.send("speed 2")
    run.wait("sped up", lambda s: abs(s["enginePlayerRate"] - 2) < 0.01, timeout=2)
    time.sleep(1)
    print(f"        720p at 120 FPS, 2x: {run.cpu_percent()}")
    run.send("speed 1")
    run.send("select 0")
    run.wait("the first wallpaper still has its own speed", lambda s: s["currentName"] == "long" and abs(s["enginePlayerRate"] - 0.25) < 0.01)
    run.send("panel close")
    run.wait("panel closes", lambda s: not s["panelOpen"])
    run.quit()
    run.launch()
    run.wait("it survives a relaunch", lambda s: s["currentName"] == "long" and s["speed"] == 0.25)
    time.sleep(1)
    run.send("panel open")
    run.wait("and plays at that speed", lambda s: s["panelOpen"] and abs(s["enginePlayerRate"] - 0.25) < 0.01)
    time.sleep(0.6)
    run.send(f"snapshot {run.artifacts / 'panel-speed-dark.png'}")
    time.sleep(0.2)
    run.send("panel close")


def day_and_night(run, media):
    """Uses the real clock, so the wallpaper really does change by itself while this waits."""
    shutil.rmtree(run.library, ignore_errors=True)
    run.launch()
    time.sleep(1)
    run.send(f"import {media / 'chart.gif'}")
    state = run.wait("first wallpaper imported", lambda s: s["wallpaperCount"] == 1, timeout=30)
    run.check("one wallpaper isn't enough to offer the schedule", not state["canSchedule"])
    run.send(f"import {media / 'vertical.mp4'}")
    state = run.wait("second wallpaper imported", lambda s: s["wallpaperCount"] == 2 and s["pendingImports"] == 0, timeout=30)
    run.check("two wallpapers offer it", state["canSchedule"])

    run.section("Turning it on")
    now = datetime.datetime.now()
    # At least 10 seconds away, so the switch can't happen before it's being watched for.
    change = (now + datetime.timedelta(seconds=70)).replace(second=0, microsecond=0)
    earlier = now - datetime.timedelta(hours=1)
    run.send("schedule on")
    run.send("schedule-wallpapers 0 1")
    run.send(f"schedule-times {earlier:%H:%M} {change:%H:%M}")
    state = run.wait("it puts on the day wallpaper right away", lambda s: s["scheduleActive"] and s["currentName"] == "chart")
    run.check("it says when the next change is", state["scheduleCaption"].startswith("Changes to Night"), state["scheduleCaption"])
    run.send("panel open")
    run.wait("panel opens with the schedule showing", lambda s: s["panelOpen"])
    run.send("appearance dark")
    time.sleep(0.6)
    run.send(f"snapshot {run.artifacts / 'panel-schedule-dark.png'}")
    time.sleep(0.2)
    run.send("panel close")
    run.wait("panel closes", lambda s: not s["panelOpen"])

    run.section("Waiting for the clock")
    seconds = (change - datetime.datetime.now()).total_seconds()
    print(f"        waiting about {seconds:.0f} seconds for {change:%H:%M}")
    state = run.wait("the wallpaper changes by itself at the chosen time", lambda s: s["currentName"] == "vertical", timeout=seconds + 8)
    run.check("the caption moves on", state["scheduleCaption"].startswith("Changes to Day"), state["scheduleCaption"])

    run.section("Picking by hand")
    run.send("select 0")
    run.wait("a wallpaper can still be picked by hand", lambda s: s["currentName"] == "chart")
    time.sleep(2.5)
    run.check("the schedule doesn't undo it straight away", run.state()["currentName"] == "chart")
    run.quit()
    run.launch()
    state = run.wait("it survives a relaunch", lambda s: s["scheduleActive"] and s["engineWindows"] >= 1)
    run.check("and the hand-picked wallpaper stays until the next change", state["currentName"] == "chart", state["currentName"])

    run.section("Changing the plan")
    later = datetime.datetime.now() + datetime.timedelta(hours=2)
    earlier = datetime.datetime.now() - datetime.timedelta(hours=1)
    run.send(f"schedule-times {later:%H:%M} {earlier:%H:%M}")
    run.wait("new times apply right away", lambda s: s["currentName"] == "vertical")
    run.send(f"schedule-times {later:%H:%M} {later:%H:%M}")
    state = run.wait("matching times are explained", lambda s: s["scheduleCaption"] == "Day and Night need different times.")
    run.check("and nothing is scheduled", not state["scheduleActive"])
    run.send(f"schedule-times {later:%H:%M} {earlier:%H:%M}")
    run.wait("fixing the times turns it back on", lambda s: s["scheduleActive"])

    run.section("Deleting a scheduled wallpaper")
    run.send("delete 1")
    state = run.wait("the schedule turns off", lambda s: s["wallpaperCount"] == 1 and not s["scheduleOn"])
    run.check("and says why", "Day and Night is off" in state["message"], state["message"])
    run.check("with no wallpapers to choose between, it's hidden", not state["canSchedule"])


def fit_to_screen(run, media):
    """A file that doesn't match the screen gets advice and an optional conversion."""
    shutil.rmtree(run.library, ignore_errors=True)
    run.go_to_desktop()
    run.launch()
    time.sleep(1)
    run.check("the best size is offered before anything is added", "Best fit for this screen" in run.state()["bestSize"], run.state()["bestSize"])
    run.send(f"import {media / 'chart.gif'}")
    run.wait("a landscape file imports", lambda s: s["wallpaperCount"] == 1, timeout=30)
    run.check("a landscape file gets no warning and no toggle", run.state()["fitNote"] == "" and not run.state()["canFit"], str(run.state()))

    run.section("Fit to Screen")
    run.send(f"import {media / 'vertical.mp4'}")
    state = run.wait("a vertical video imports", lambda s: s["wallpaperCount"] == 2 and s["currentName"] == "vertical", timeout=30)
    run.check("it says how much is hidden", "hiding about" in state["fitNote"], state["fitNote"])
    run.check("Fit to Screen is offered", state["canFit"])
    run.wait("it plays", lambda s: s["desktopMoving"], timeout=6)
    time.sleep(1.5)
    print(f"        vertical video, cropped: {run.cpu_percent()}, app footprint {run.footprint_mb():.1f} MB")
    started = time.time()
    run.send("fit on")
    state = run.wait("the conversion finishes and takes over", lambda s: s["fitOn"] and s["playbackFile"].startswith("fit-") and not s["versionWorking"] and s["desktopMoving"], timeout=120)
    print(f"        converted in {time.time() - started:.1f}s to {state['playbackFile']}")
    run.check("the warning goes away", state["fitNote"] == "", state["fitNote"])
    time.sleep(1.5)
    print(f"        vertical video, fitted: {run.cpu_percent()}, app footprint {run.footprint_mb():.1f} MB")
    run.send("mode still")
    run.wait("Still works on a fitted wallpaper", lambda s: s["mode"] == "still" and not s["enginePlayerLoaded"])
    run.send("frame 20")
    run.wait("the slider works on it", lambda s: s["stillFrame"] == 20)
    run.send("mode animated")
    run.wait("back to Animated", lambda s: s["mode"] == "animated" and s["desktopMoving"])
    run.send("smooth on")
    run.wait("Smooth Motion works on it", lambda s: s["playbackFile"].startswith("smooth-120-fit-") and not s["versionWorking"] and s["desktopMoving"], timeout=180)
    run.send("smooth off")
    run.wait("Smooth Motion off", lambda s: not s["smoothMotion"] and s["playbackFile"].startswith("fit-"))
    run.send("fit off")
    state = run.wait("turning it off goes back to the original", lambda s: not s["fitOn"] and s["playbackFile"] == "prepared.mp4" and s["desktopMoving"])
    run.check("and the advice returns", "hiding about" in state["fitNote"], state["fitNote"])
    run.send("fit on")
    run.wait("turning it back on is instant", lambda s: s["fitOn"] and s["playbackFile"].startswith("fit-") and not s["versionWorking"] and s["desktopMoving"], timeout=3)


def panel_rules(run, media):
    """The desktop follows the pause rule even while the panel is open."""
    shutil.rmtree(run.library, ignore_errors=True)
    run.go_to_desktop()
    run.launch()
    time.sleep(1)
    run.send(f"import {media / 'chart.gif'}")
    run.wait("wallpaper imported", lambda s: s["wallpaperCount"] == 1, timeout=30)
    run.wait("it plays with the desktop focused", lambda s: s["desktopMoving"])

    run.section("Opening the panel with another app in front")
    run.cover("focus", 60)
    run.wait("another app takes focus", lambda s: not s["finderFront"] and not s["engineWantsPlaying"])
    run.send("panel open")
    run.wait("the preview plays", lambda s: s["panelOpen"] and s["previewReady"] and s["enginePlayerRate"] > 0)
    time.sleep(0.5)
    state = run.state()
    run.check("the desktop stays frozen", not state["desktopMoving"], str(state))
    run.check("the desktop keeps showing a still frame", state["engineStillVisible"], str(state))
    run.send("panel close")
    run.wait("closing the panel stops everything", lambda s: not s["panelOpen"] and not s["enginePlayerLoaded"])
    run.end_covers()

    run.section("Changing the rule with the panel open")
    time.sleep(1.5)
    run.go_to_desktop()
    run.wait("playing on the desktop again", lambda s: s["finderFront"] and s["desktopMoving"])
    run.send("panel open")
    run.wait("panel opens", lambda s: s["panelOpen"])
    time.sleep(0.3)
    run.check("with the desktop focused, it keeps moving behind the panel", run.state()["desktopMoving"], str(run.state()))
    run.send("panel close")
    run.wait("panel closes", lambda s: not s["panelOpen"])

    run.section("Leaving the panel")
    run.send("panel open")
    run.wait("panel opens", lambda s: s["panelOpen"])
    run.cover("focus", 8)
    run.wait("another app taking focus closes the panel", lambda s: not s["panelOpen"], timeout=4)
    run.wait("and the desktop freezes", lambda s: not s["desktopMoving"] and not s["engineWantsPlaying"], timeout=4)
    run.end_covers()
    time.sleep(1.5)
    run.go_to_desktop()
    run.wait("clicking the desktop plays it again", lambda s: s["desktopMoving"])

    run.section("Whenever Visible with a window in front")
    run.send("rule visible")
    run.cover("focus", 8)
    run.wait("another app takes focus", lambda s: not s["finderFront"])
    time.sleep(0.5)
    run.check("the desktop keeps moving around a small window", run.state()["desktopMoving"], str(run.state()))
    run.end_covers()
    time.sleep(1)
    run.send("rule focus")


def races(run, media):
    """Timing that a person could hit by chance, forced by running commands back to back."""
    shutil.rmtree(run.library, ignore_errors=True)
    run.go_to_desktop()
    run.launch()
    time.sleep(1)
    run.send(f"import {media / 'chart.gif'}")
    run.wait("first wallpaper imported", lambda s: s["wallpaperCount"] == 1, timeout=30)
    run.send(f"import {media / 'long.gif'}")
    run.wait("second wallpaper imported", lambda s: s["wallpaperCount"] == 2 and s["pendingImports"] == 0, timeout=60)
    run.send("select 0")
    run.wait("first wallpaper selected", lambda s: s["currentName"] == "chart")
    run.send("smooth on")
    run.wait("Smooth Motion ready", lambda s: s["playbackFile"] == "smooth-120.mp4" and not s["versionWorking"], timeout=60)
    run.send("rate 60")
    run.wait("second rate ready", lambda s: s["playbackFile"] == "smooth-60.mp4" and not s["versionWorking"], timeout=60)
    run.send("smooth off")
    run.wait("Smooth Motion off", lambda s: not s["smoothMotion"])
    run.send("select 1")
    run.wait("other wallpaper playing", lambda s: s["currentName"] == "long" and s["enginePlayerRate"] > 0)

    run.section("Changing versions during a crossfade")
    run.send("batch select 0; smooth on")
    run.wait("the new version plays after the fade", lambda s: s["playbackFile"] == "smooth-60.mp4" and s["enginePlayerRate"] > 0)
    time.sleep(2.5)
    run.cover("focus", 20)
    run.wait("pausing still works afterwards", lambda s: not s["finderFront"] and not s["engineWantsPlaying"] and not s["enginePlayerLoaded"])
    run.end_covers()
    run.go_to_desktop()
    run.wait("and so does resuming", lambda s: s["finderFront"] and s["enginePlayerRate"] > 0)

    run.section("Changing versions while pausing")
    run.send("batch engine off; smooth off")
    run.wait("a still frame stays up instead of a black screen", lambda s: s["playbackFile"] == "prepared.mp4" and s["engineStillVisible"] and not s["enginePlayerLoaded"])
    run.send("engine on")
    run.wait("resuming plays the new version", lambda s: s["enginePlayerRate"] > 0 and not s["engineStillVisible"])

    run.section("Quickly switching Still and Animated")
    run.send("batch mode still; mode animated")
    time.sleep(1.5)
    run.wait("it ends up animated and playing", lambda s: s["mode"] == "animated" and s["enginePlayerRate"] > 0, timeout=3)

    run.section("Pausing before the player has loaded")
    run.send("mode still")
    run.wait("still", lambda s: not s["enginePlayerLoaded"])
    time.sleep(0.5)
    run.send("batch mode animated; engine off")
    time.sleep(1)
    run.check("the app survives", run.process.poll() is None)
    state = run.state()
    run.check("its place in the video is still valid", state["engineTime"] == state["engineTime"], str(state.get("engineTime")))
    run.send("engine on")
    run.wait("it can still play", lambda s: s["enginePlayerRate"] > 0)

    run.section("Changing the rate during a job")
    run.send("select 1")
    run.wait("the longer wallpaper is selected", lambda s: s["currentName"] == "long")
    run.send("batch smooth on; rate 60")
    time.sleep(1)
    run.check("progress stays visible for the new job", run.state()["versionWorking"], str(run.state()))
    run.wait("the new rate finishes and takes over", lambda s: s["playbackFile"] == "smooth-60.mp4" and not s["versionWorking"], timeout=120)
    folder = next(p for p in run.library.iterdir() if (p / "smooth-60.mp4").exists() and (p / "info.json").read_text().find('"long"') >= 0)
    run.check("the abandoned rate leaves no file", not (folder / "smooth-120.mp4").exists())
    run.check("and no partial file", not list(folder.glob("*.partial")))


def scenario(run, media, extra_media):
    run.section("Empty start")
    run.launch()
    # The menu bar icon takes a moment to appear, and a person can't click it before then either.
    time.sleep(1)
    run.send("panel open")
    run.wait("panel opens with nothing in the library", lambda s: s["panelOpen"])
    run.send("appearance dark")
    time.sleep(0.4)
    run.send(f"snapshot {run.artifacts / 'panel-empty-dark.png'}")
    time.sleep(0.2)
    run.send("panel close")
    run.wait("panel closes", lambda s: not s["panelOpen"])
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
    run.check("paused CPU is effectively zero", usage["app"] + usage["decoder"] < 1, str(usage))
    print(f"        paused: {usage}, app footprint {run.footprint_mb():.1f} MB")
    run.end_covers()
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
    # When an app quits, macOS hands focus back a moment later, which can undo a launch made too soon.
    time.sleep(1.5)
    focus = run.cover("focus", 5)
    state = run.wait("the test window takes focus", lambda s: not s["finderFront"])
    time.sleep(0.5)
    state = run.state()
    run.check("another app having focus doesn't pause it", state["engineWantsPlaying"] and state["enginePlayerRate"] > 0, str(state))
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
    time.sleep(1.5)
    focus = run.cover("focus", 60)
    run.wait("paused before opening the panel", lambda s: not s["engineWantsPlaying"])
    run.send("panel open")
    run.wait("opening the panel starts the preview", lambda s: s["panelOpen"] and s["engineWantsPlaying"])
    run.wait("the preview shows the video", lambda s: s["previewReady"] and s["enginePlayerRate"] > 0)
    time.sleep(0.5)
    for appearance in ("dark", "light"):
        run.send(f"appearance {appearance}")
        time.sleep(0.4)
        run.send(f"snapshot {run.artifacts / f'panel-animated-{appearance}.png'}")
        time.sleep(0.3)
    run.check("panel renders", (run.artifacts / "panel-animated-dark.png").exists())
    run.send("smooth on")
    run.wait("Smooth Motion finishes while the panel is open", lambda s: s["smoothMotion"] and not s["versionWorking"], timeout=60)
    time.sleep(0.4)
    run.send(f"snapshot {run.artifacts / 'panel-smooth-light.png'}")
    time.sleep(0.2)
    run.send("appearance dark")
    time.sleep(0.4)
    run.send(f"snapshot {run.artifacts / 'panel-smooth-dark.png'}")
    time.sleep(0.2)
    run.send("smooth off")
    run.wait("Smooth Motion off", lambda s: not s["smoothMotion"])
    run.send("panel close")
    run.wait("closing the panel goes back to the rule", lambda s: not s["panelOpen"] and not s["engineWantsPlaying"])
    run.end_covers()
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

    run.section("Panel memory")
    run.send("panel open")
    run.wait("panel opens", lambda s: s["panelOpen"])
    run.send("panel close")
    run.wait("panel closes", lambda s: not s["panelOpen"])
    time.sleep(1)
    before = run.footprint_mb()
    for _ in range(15):
        run.send("panel open")
        run.wait("", lambda s: s["panelOpen"], report=False)
        time.sleep(0.15)
        run.send("panel close")
        run.wait("", lambda s: not s["panelOpen"], report=False)
        time.sleep(0.15)
    time.sleep(2)
    after = run.footprint_mb()
    print(f"        footprint before {before:.1f} MB, after 15 opens {after:.1f} MB")
    run.check("opening and closing the panel doesn't leak", after - before < 6, f"{before} then {after}")
    run.go_to_desktop()

    run.section("Still or Animated")
    run.send("mode still")
    state = run.wait("switching to Still stops the player", lambda s: s["mode"] == "still" and not s["enginePlayerLoaded"] and not s["engineWantsPlaying"])
    run.check("status line says still", state["status"] == "Still wallpaper")
    run.check("it freezes on the frame that was showing", 0 <= state["stillFrame"] < state["frameCount"], str(state))
    usage = run.cpu_percent()
    # Debug builds write their state to disk four times a second. Release builds are measured separately.
    run.check("a still wallpaper costs effectively nothing", usage["app"] + usage["decoder"] < 1, str(usage))
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
    run.send("appearance light")
    time.sleep(0.4)
    run.send(f"snapshot {run.artifacts / 'panel-still-light.png'}")
    time.sleep(0.2)
    run.send("appearance dark")
    time.sleep(0.2)
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

    run.quit()
    size_before = (current_folder / "prepared.mp4").stat().st_size
    (current_folder / "prepared.mp4").write_bytes(b"this is not a video" * 100)
    run.launch()
    run.wait("a damaged prepared file is rebuilt from the original", lambda s: s["currentName"] == "chart" and s["enginePlayerRate"] > 0 and not s["versionWorking"], timeout=30)
    time.sleep(0.5)
    run.check("the rebuilt file is a real video", abs((current_folder / "prepared.mp4").stat().st_size - size_before) < size_before * 0.5, str((current_folder / "prepared.mp4").stat().st_size))

    run.quit()
    (current_folder / "still.png").unlink()
    run.launch()
    run.wait("a missing still frame is remade", lambda s: s["currentName"] == "chart", timeout=10)
    time.sleep(1.5)
    run.check("the still file is back", (current_folder / "still.png").exists())

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
            run.wait(f"Smooth Motion finishes on {file.name}", lambda s: not s["versionWorking"] and s["playbackFile"].startswith("smooth-"), timeout=300)
            run.go_to_desktop()
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

<p align="center"><img src="docs/images/icon.png" width="128" alt="Lull app icon"></p>

<h1 align="center">Lull</h1>

<p align="center">GIFs and looping videos as your Mac wallpaper. It rests when nobody's looking.</p>

Lull is a very light menu bar app for macOS. Drag in a GIF or video you already have and it becomes your wallpaper, behind your desktop icons. When you can't see the wallpaper, Lull stops doing work: the video player is fully unloaded and CPU use drops to zero.

It's a 2 MB native app with no accounts, analytics or network use. Free and open source under the MIT license.

<p align="center">
  <img src="docs/images/panel-dark.png" width="320" alt="The Lull panel in dark mode">
  <img src="docs/images/panel-light.png" width="320" alt="The Lull panel in light mode">
</p>

## Features

- **GIFs, MP4 and MOV.** Each file is prepared once, then played on your Mac's video hardware.
- **Desktop Focus or Whenever Visible.** By default the wallpaper plays only when you click the desktop. Switch to Whenever Visible to have it play whenever part of it can be seen.
- **Still or Animated.** Freeze any wallpaper and drag a slider to pick the exact frame. Your desktop updates as you drag.
- **Smooth Motion.** Generates in-between frames for GIFs and videos, up to 120 FPS, using Apple's frame rate conversion. It runs once and the result is saved.
- **Frame limits.** Lower a fast video to 60 or 30 FPS to save power.
- **Sharp pixel art.** Small GIFs are enlarged before encoding so pixel art stays crisp.
- **Multiple displays.** One wallpaper across every screen, decoded once.

Your real wallpaper setting is never changed. Quit Lull and your normal wallpaper is back.

## Install

Requires macOS 15.4 or later on Apple Silicon.

1. Download the latest DMG from [Releases](https://github.com/markoderic/lull/releases).
2. Drag Lull to Applications and open it.
3. Click the icon in your menu bar and add a GIF or video.

### Build from source

```bash
git clone https://github.com/markoderic/lull.git
cd lull
scripts/build-app.sh
open dist/release/Lull.app
```

You need Xcode 26 or later. There's no Xcode project to generate: it's a Swift package, and `Package.swift` opens directly in Xcode.

## How light is it?

Measured on the release build on an M5 Pro MacBook Pro with macOS 27. CPU figures are percentages of one core, and this chip has 18. WindowServer is the system process that draws everything on screen, and it sat around 4–5% before Lull did anything.

| What's on screen | Lull | Video decoder | WindowServer | Lull's memory | Decoder's memory |
|---|---|---|---|---|---|
| Paused, another app focused | 0.00% | 0% | no added load | 16 MB | up to 36 MB |
| Still wallpaper | 0.00% | 0% | no added load | 24 MB | none |
| GIF at its own 12.5 FPS | 1.1% | 0.8% | 9.6% | 21 MB | 23 MB |
| 1080p video, 30 FPS | 1.6% | 1.7% | 13.4% | 28 MB | 51 MB |
| GIF with Smooth Motion, 120 FPS | 3.6% | 4.3% | 44.6% | 22 MB | 55 MB |
| 4K video, 120 FPS | 4.1% | 7.0% | 44.9% | 56 MB | 430 MB |

Two honest notes:

- **120 FPS is the expensive part.** It keeps WindowServer redrawing the screen 120 times a second, whatever the resolution. That's why Smooth Motion is off by default and the 120 option says it uses more power.
- **Memory grows a little after Smooth Motion.** The Neural Engine holds on to about 13 MB until you quit, so Lull can sit around 36 MB after using it. A still wallpaper with no Smooth Motion stays closer to 24 MB.

These are from one Mac and a small number of samples, so treat them as a guide. Battery life and slower Macs haven't been measured yet.

## How it works

macOS has no public way to set an animated wallpaper, only still images. Lull places a borderless window at the desktop window level, which sits above the real wallpaper and below your icons, and ignores all clicks.

GIF is a costly format to play directly, because it's decoded on the CPU. So Lull converts each file once, on import, to an efficient HEVC video, and from then on Apple's standard player runs it on the video hardware. One player feeds every display.

To decide when to play, Lull listens for system events such as focus changes, locking and sleep. It works out whether the desktop is covered from window positions, because `NSWindow.occlusionState` proved unreliable in testing. That check runs every 2 seconds, and only when its answer could change anything.

The design and the evidence behind it are in [the design spec](docs/superpowers/specs/2026-11-06-lull-design.md).

## Known limitations

- **Desktop only.** The lock screen shows your normal wallpaper.
- **Menu bar colors follow your real wallpaper.** macOS picks the menu bar's text color from it, without knowing about the animation on top. A wallpaper that's much lighter or darker than your real one can make menu bar text harder to read.
- **Translucent full-screen windows count as covering the desktop,** so the wallpaper pauses behind them.
- **Fast clicks on the desktop can pause briefly** on systems that show extra windows at the moment of the click. Lull ignores the ones it knows about.
- **WebM isn't supported,** because Apple's video frameworks don't reliably open it.
- **Smooth Motion has limits.** Thin lines can wobble in generated frames, and hard cuts become a very quick dissolve.

## Not yet tested

Automated and hands-on checks ran on one Mac with one display. These haven't been tried yet:

- More than one display
- More than one Space
- macOS versions older than 27
- Battery life and slower Macs

If you try any of them, an issue saying how it went would help.

## Development

```bash
swift test               # unit and integration tests
python3 scripts/e2e/run.py   # end-to-end checks on your real desktop
```

The end-to-end checks drive a debug build against a throwaway library, so your own wallpapers aren't touched. They take over your screen for a few minutes and need `ffmpeg` to generate test files. The automation they use is compiled only into debug builds.

| Path | What's there |
|---|---|
| `Sources/LullCore` | Everything testable without a UI: importing, Smooth Motion, the library, the pause rule, coverage |
| `Sources/Lull` | The app: wallpaper engine, playback monitor, menu bar panel |
| `Tests/LullCoreTests` | Unit and integration tests, using real files and real encoders |
| `scripts/` | Build, release, icon and end-to-end tooling |

Lull has no third-party dependencies, and that's on purpose.

## License

[MIT](LICENSE)

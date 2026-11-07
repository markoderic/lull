# Lull: design spec

Lull is a very light, native macOS menu bar app that turns GIFs and looping videos into a desktop wallpaper. It rests when nobody can see it. It is free and open source, distributed through GitHub Releases.

Status: design approved by the project owner on 2026-11-06, including every recommendation below. The name "Lull" was chosen by the author on the owner's behalf and is easy to change.

## Goals

- A person drags in a GIF or looping video they already have and it becomes their wallpaper.
- It feels like an app Apple made: one menu bar icon, one simple panel, standard controls.
- It is as light as the platform allows, and does close to nothing when the wallpaper can't be seen.

## Non-goals (first version)

- Lock screen or screen saver wallpapers. A vendor reports macOS 27 changed how these are installed, and they would need private behavior.
- A built-in GIF browser, accounts, analytics or any network use.
- Different wallpapers per display. The design keeps this possible later.
- Intel Macs. Lightness relies on Apple Silicon video hardware, and Intel can't be tested here.
- WebM, because Apple's video frameworks don't reliably open it.

## Requirements

- macOS 15.4 or later on Apple Silicon. Swift, AppKit and SwiftUI only, with no third-party dependencies.
- Menu bar only: `LSUIElement`, no Dock icon, one status item.
- Accepts GIF, MP4 and MOV. Audio is always dropped.
- Never changes the system wallpaper setting. Quitting restores the normal wallpaper because the app's windows go away.

## How it works

macOS has no public API for animated wallpapers. The macOS 27.2 SDK only offers `NSWorkspace.setDesktopImageURL` for still images. Lull places a borderless window at `kCGDesktopWindowLevel`, which sits above the real wallpaper and below the desktop icons, on every Space, ignoring mouse events.

Each file is prepared once on import into an efficient video, then played by Apple's standard player on the video hardware.

## Components

1. **Importer.** Turns a GIF or video into a playable file, enlarges small GIFs, and runs Smooth Motion. Runs only during imports and holds only a few frames in memory.
2. **Library.** One folder per wallpaper in Application Support.
3. **Wallpaper engine.** One desktop-level window per display fed by one shared player. It shows a still, plays or unloads, and does not know why.
4. **Pause rule.** Watches focus, coverage, lock and sleep, and decides play or pause.
5. **Menu bar and panel.** One icon. The panel is created on click and destroyed on close.

## Behavior

### Pause rule

The user picks one rule, and **Desktop Focus is the default**.

- **Desktop Focus:** plays only when Finder is the frontmost app, which is what clicking the desktop does, and the desktop isn't fully covered.
- **Whenever Visible:** plays whenever the desktop isn't fully covered.

In both modes it always pauses when the screen is locked or asleep, the screen saver is running, the user session is inactive, or Low Power Mode is on.

The desktop only ever follows this rule, even while the panel is open. The panel's preview stays live on its own, using the same player with the desktop detached from it. An early version let an open panel force the desktop to play, which meant the rule visibly did nothing while a person was trying it out.

While paused, the player is **fully unloaded** and a still frame stays on screen. Resuming seeks back to the exact frame.

### Coverage

macOS's `occlusionState` proved unreliable in testing: it reported a fully covered ordinary window as visible while a screen capture service was running, and it would never count a maximized window as covering. Lull calculates coverage itself.

- Read on-screen windows with `CGWindowListCopyWindowInfo`, excluding Lull's own process.
- Count only **layer 0** windows. Layer 18 `WindowManager` shows a screen-sized window for a moment when the wallpaper is clicked, and that caused false pauses in testing.
- Ignore windows with alpha below 0.99 or smaller than 100 points in either dimension.
- Sample a 64 × 40 grid over each screen's `visibleFrame`, so the Dock and menu bar strips don't count. The desktop is covered only when every screen's area is fully covered.
- Check every 2 seconds, and immediately on focus or Space changes, and only when the result could change a decision. No polling for still wallpapers, while the panel is open, while locked, or under Desktop Focus when another app is frontmost.
- A failed check assumes the desktop is visible.

Translucent windows report alpha 1, so they count as covering. This is accepted.

### Still or Animated

Each wallpaper remembers its own mode and chosen frame.

- Switching to Still freezes on the frame showing at that moment.
- A slider then picks any frame, updating the panel preview and the real desktop live.
- The slider only uses real frames from the base prepared file, never ones Smooth Motion generated.
- A still wallpaper unloads the player and does no polling. It costs about the same as being paused.
- A file with a single frame imports as Still only.

### Frame rate and Smooth Motion

- Files play at their own frame rate. A 120 FPS video plays at 120 on a 120 Hz display.
- **Smooth Motion** is a per-wallpaper toggle, off by default, for GIFs and videos. It generates in-between frames once with `VTFrameRateConversionConfiguration` and saves the result.
- Its rate choices, 60 and 120 FPS, appear only when it's on, and only rates above the source's rate and within the fastest connected display. 120 FPS shows "Smoothest. Uses more power."
- Generated versions are kept after the toggle turns off, so switching back is quick.
- The last frame interpolates into the first, so the loop point is smooth too.
- **Frame limit** is a second control for videos at 59 FPS or above with Smooth Motion off: Original, 60 (only for sources over 61 FPS) and 30. It makes a version by dropping frames, without interpolation.

### File size and Fit to Screen

Wallpapers fill the screen, so a mismatched file is cropped or enlarged.

- With nothing added yet, the panel names the best size for the main display, in pixels.
- If filling the screen would hide more than 25% of a file, the panel says how much and offers **Fit to Screen**.
- If a video needs enlarging more than 2×, the panel says it may look soft and names a better size. GIFs skip this, because nearly all are small and nothing can be done about it. Fit to Screen isn't offered here, because enlarging can't add detail.
- Fit to Screen makes `fit-<width>x<height>.mp4` once, at the display's exact resolution: the whole picture centered, over a blurred copy of itself. Smooth Motion and frame limits build on the fitted file, and still frames come from it. Rotated phone videos are written upright.
- It's optional because it makes larger files.

### Importing

- **GIF timing:** per-frame delays are respected. A delay under 11 ms becomes 100 ms, the browser convention.
- **Transparency:** composited onto black.
- **Enlarging:** GIFs under 1280 pixels wide are enlarged by the largest whole factor from 1 to 4 that keeps the longer side at or below 1920. Pixel art uses nearest-neighbor. Other GIFs use high-quality smoothing. A GIF counts as pixel art when at least 60% of sampled neighboring pixels are exactly equal.
- **Even sizes:** output width and height are rounded up to even numbers, as HEVC requires.
- **Encoding:** HEVC. Bitrate is `width × height × fps × bpp`, with bpp 0.15 up to 30 FPS, 0.10 up to 60 and 0.07 above, between 1.5 and 100 Mbps.
- **Videos:** H.264 and HEVC files have audio stripped without re-encoding, and that file is both original and prepared. Other formats are converted to HEVC and the original is kept.
- Jobs run one at a time at low priority and continue when the panel closes. Right-clicking a tile cancels. Quitting discards partial files.

### Storage

`~/Library/Application Support/Lull/Wallpapers/<uuid>/`

| File | Purpose |
|---|---|
| `info.json` | Name, kind, sizes, timing, mode, chosen frame, settings |
| `original.<ext>` | Copy of the source (absent when `prepared.mp4` is the original) |
| `prepared.mp4` | The base file that plays |
| `smooth-60.mp4`, `smooth-120.mp4` | Smooth Motion versions |
| `limit-60.mp4`, `limit-30.mp4` | Frame limit versions |
| `still.png` | Chosen still frame, shown on launch without opening video |
| `thumb.jpg` | Library thumbnail |

There is one info file per wallpaper, so damage affects only that wallpaper. Deleting moves the folder to the Trash. App settings (current wallpaper, pause rule) live in `UserDefaults`.

### Panel

Width 320 points, native controls only:

1. Preview, sharing the player so it adds no decode work.
2. Segmented Animated or Still control.
3. Only the controls that apply: Smooth Motion and rate, frame limit, or the frame slider.
4. Divider, then a 4-column grid of thumbnails with an add tile. Files can also be dropped anywhere on the panel.
5. A status line and a "…" menu: the pause rule, Launch at Login, About and Quit.

The panel closes on a click outside that isn't the start of a drag, on switching apps, and on Escape. It doesn't use a transient popover, because that closes the moment another app is clicked, which would make dragging a file in from Finder impossible.

The status line reads "Plays when you click the desktop" or "Plays when the desktop is visible", or "Paused: Low Power Mode is on" or "Still wallpaper" when those apply. Right-clicking a tile offers Delete, or Cancel while importing, or Remove when missing.

The panel opens with the standard popover animation. Wallpaper changes crossfade over 250 ms. Reduce Motion is respected. SF Symbols, San Francisco, the system accent color and light and dark mode come from the system controls.

### Errors

| Situation | Behavior |
|---|---|
| Unreadable or unsupported file | "Can't open this file. GIF, MP4 and MOV work." Nothing is added. |
| Not enough disk space | Import stops, partial files removed, message shown. |
| Smooth Motion unavailable | Toggle disabled with a one-line reason. Wallpaper still works. |
| Smooth Motion fails partway | Toggle turns off, message shown, current version keeps playing. |
| Prepared file missing or damaged | Rebuilt from the original automatically. |
| Original missing too | Tile shows "Missing" and offers Remove. Normal wallpaper shows if it was active. |
| Playback fails | Still frame stays, one retry, then a message. |
| Display connected, removed or changed | Windows rebuilt. |
| Coverage check fails | Assumes visible. |

## Measured results of the finished app (M5 Pro, macOS 27.0.1, release build)

CPU is a percentage of one core, on an 18-core chip. WindowServer sat around 4–5% before Lull did anything.

| What's on screen | Lull | Decoder | WindowServer | Lull memory | Decoder memory |
|---|---|---|---|---|---|
| Paused, another app focused | 0.00% | 0% | no added load | 16 MB | up to 36 MB |
| Still wallpaper | 0.00% | 0% | no added load | 24 MB | none |
| GIF at its own 12.5 FPS | 1.1% | 0.8% | 9.6% | 21 MB | 23 MB |
| 1080p video, 30 FPS | 1.6% | 1.7% | 13.4% | 28 MB | 51 MB |
| GIF with Smooth Motion, 120 FPS | 3.6% | 4.3% | 44.6% | 22 MB | 55 MB |
| 4K video, 120 FPS | 4.1% | 7.0% | 44.9% | 56 MB | 430 MB |

13 MB at launch with no wallpaper. A still wallpaper had zero idle wakeups over 10 seconds. After Smooth Motion the Neural Engine keeps about 13 MB until quit, so memory can sit around 36 MB.

## Measured evidence (M5 Pro, macOS 27.0.1, throwaway prototype)

| What's playing | GPU | Total CPU (% of one core) | Share of whole CPU |
|---|---|---|---|
| Paused and unloaded | 0% | ~0.6% | effectively none |
| GIF, original 12.5 FPS | 2% | ~7% | ~0.4% |
| GIF, Smooth Motion 120 FPS | 2%* | ~40% | ~2.2% |
| 4K video, 120 FPS | 21% | ~44% | ~2.4% |

Totals include the app, decoder and WindowServer, with 4 to 5 samples each. *An earlier noisier run showed about 21% GPU for this case.

- App memory 15–23 MB. Decoder memory up to about 422 MB at 4K 120, and 8–36 MB when unloaded.
- 120 FPS delivered 116–120 frames per second, with worst loop gaps of 16–22 ms.
- Resume took 21–48 ms after the first load (80 ms) and landed on the exact frame.
- Smooth Motion took about 1.3–3 seconds on 50–100 frame GIFs, plus about 9 seconds the first time for each new frame size.
- Nearest-neighbor enlarging before encoding kept pixel art visibly sharp (SSIM 0.974 at 1×, 0.993 at 4×). Thin lines wobble in generated frames, and hard cuts become a 2–3 frame dissolve.
- Hands-on checks passed: click to play, icons usable, freeze, resume, full screen, lock screen, and Smooth Motion visibly smoother.

### API traps found

- `VTFrameProcessor.process(parameters:)` in Swift returns a lazy stream. Calling it without consuming the stream does nothing and leaves black frames. Use `process(parameters:completionHandler:)`.
- Frame rate conversion needs `RGhA` (16-bit float) buffers from the configuration's pixel buffer attributes.
- `AVPlayerLooper.loopingPlayerItems` are created lazily, and `AVQueuePlayer.currentItem` can be nil just after creation. Wait for it before seeking.
- Set `preventsDisplaySleepDuringVideoPlayback = false`, or the Mac will never sleep its display.

## Testing

- Unit tests with Swift Testing for timing, enlarging, pixel art detection, coverage, the pause rule, the store and every error path that can run headless.
- Integration tests that import generated GIFs and videos: odd sizes, variable delays, single frames, Smooth Motion, frame limits and color accuracy.
- End-to-end checks of the real app on this Mac, through a debug-only automation bridge compiled out of release builds.
- Still unverified by automation, to be listed in the release notes: multiple displays, multiple Spaces, battery life and slower Macs.

## Distribution

- MIT license. Public GitHub repository, with signed and notarized DMGs on GitHub Releases.
- SwiftPM package plus shell scripts, so contributors don't need a generated Xcode project.
- CI runs the tests on every push.
- Publishing the repository is left to the owner, because it's public and hard to undo.

import LullCore
import SwiftUI

/// Everything in the menu bar panel. One preview, one toggle, and only the controls that apply.
struct PanelView: View {
    @Bindable var model: AppModel
    let onAdd: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current = model.current {
                preview
                if !current.isStillOnly {
                    modePicker(current)
                }
                if current.mode == .animated, !current.isStillOnly {
                    AnimatedControls(model: model, info: current)
                } else if !current.isStillOnly {
                    StillControls(model: model, info: current)
                }
            } else {
                emptyState
            }

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            Divider()
            library
            footer
        }
        .padding(12)
        .frame(width: 320)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.add(urls: files)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: layoutKey)
    }

    /// Changes whenever the panel's shape changes, which is what animates its controls.
    private var layoutKey: [String] {
        [
            model.current?.mode.rawValue ?? "none",
            model.current?.smoothMotion.description ?? "",
            model.message ?? "",
            "\(model.wallpapers.count + model.pendingImports.count)",
        ]
    }

    // MARK: Sections

    private var preview: some View {
        PreviewSurfaceView(engine: model.engine)
            .aspectRatio(model.screenAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    private func modePicker(_ current: WallpaperInfo) -> some View {
        Picker("Wallpaper type", selection: Binding(
            get: { current.mode },
            set: { model.setMode($0) }
        )) {
            Text("Animated").tag(WallpaperInfo.Mode.animated)
            Text("Still").tag(WallpaperInfo.Mode.still)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Add a GIF or video")
                .font(.headline)
            Text("Drop a file here, or use the + button below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private var library: some View {
        let tileCount = model.wallpapers.count + model.pendingImports.count + 1
        let rows = Int((Double(tileCount) / 4).rounded(.up))
        return ScrollView(.vertical) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(model.wallpapers) { info in
                    WallpaperTile(
                        name: info.name,
                        image: model.thumbnails[info.id],
                        isSelected: info.id == model.currentID,
                        state: tileState(for: info),
                        action: { model.select(info.id) }
                    )
                    .contextMenu { tileMenu(for: info) }
                }
                ForEach(model.pendingImports) { pending in
                    WallpaperTile(
                        name: pending.name,
                        image: nil,
                        isSelected: false,
                        state: .working(pending.progress),
                        action: {}
                    )
                    .contextMenu {
                        Button("Cancel") { model.cancelImport(pending.id) }
                    }
                }
                AddTile(action: onAdd)
            }
        }
        .scrollDisabled(rows <= 3)
        .scrollIndicators(.never)
        .frame(height: gridHeight(rows: min(rows, 3)))
    }

    /// Each tile is a quarter of the panel's inner width, at 16:10.
    private func gridHeight(rows: Int) -> CGFloat {
        let tileWidth = (320.0 - 24.0 - 18.0) / 4.0
        let tileHeight = tileWidth * 10.0 / 16.0
        return CGFloat(rows) * tileHeight + CGFloat(max(rows - 1, 0)) * 6
    }

    private func tileState(for info: WallpaperInfo) -> WallpaperTile.State {
        if model.missingIDs.contains(info.id) { return .missing }
        if let progress = model.versionProgress[info.id] { return .working(progress) }
        return .ready
    }

    @ViewBuilder
    private func tileMenu(for info: WallpaperInfo) -> some View {
        if model.missingIDs.contains(info.id) {
            Button("Remove", role: .destructive) { model.delete(info.id) }
        } else {
            if model.versionProgress[info.id] != nil {
                Button("Cancel") { model.cancelVersion(info.id) }
            }
            Button("Delete", role: .destructive) { model.delete(info.id) }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                Picker("Play wallpaper", selection: Binding(
                    get: { model.pauseRule },
                    set: { model.setPauseRule($0) }
                )) {
                    Text("Desktop Focus").tag(PauseRuleMode.desktopFocus)
                    Text("Whenever Visible").tag(PauseRuleMode.wheneverVisible)
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Divider()
                Button("About Lull") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Button("Quit Lull") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More options")
        }
    }
}

/// Smooth Motion and frame limit. Rows appear only when they apply.
private struct AnimatedControls: View {
    let model: AppModel
    let info: WallpaperInfo

    private var rates: [Int] { info.availableSmoothRates(displayMaxFPS: model.displayMaxFPS) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !rates.isEmpty {
                smoothMotionRow
                if info.smoothMotion {
                    rateRow
                }
            }
            if !info.smoothMotion, !info.availableFrameLimits.isEmpty {
                frameLimitRow
            }
        }
    }

    private var smoothMotionRow: some View {
        HStack(spacing: 8) {
            Text("Smooth Motion")
            Spacer(minLength: 0)
            if let progress = model.versionProgress[info.id] {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
            Toggle("Smooth Motion", isOn: Binding(
                get: { info.smoothMotion },
                set: { model.setSmoothMotion($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!model.isSmoothMotionSupported)
        }
        .help(model.isSmoothMotionSupported ? "Generates in-between frames, once, then keeps them." : "Smooth Motion isn't available on this Mac.")
    }

    @ViewBuilder
    private var rateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if rates.count > 1 {
                Picker("Frame rate", selection: Binding(
                    get: { info.smoothRate },
                    set: { model.setSmoothRate($0) }
                )) {
                    ForEach(rates, id: \.self) { rate in
                        Text("\(rate) FPS").tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text(info.smoothRate >= 120 ? "Smoothest. Uses more power." : "Smooth, with less power use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var frameLimitRow: some View {
        HStack(spacing: 8) {
            Text("Frame limit")
            Spacer(minLength: 0)
            if let progress = model.versionProgress[info.id] {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
            Picker("Frame limit", selection: Binding(
                get: { info.frameLimit },
                set: { model.setFrameLimit($0) }
            )) {
                Text("Original").tag(Int?.none)
                ForEach(info.availableFrameLimits, id: \.self) { limit in
                    Text("\(limit) FPS").tag(Int?.some(limit))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// The frame slider. It follows the drag live, on the desktop as well as in the preview.
private struct StillControls: View {
    let model: AppModel
    let info: WallpaperInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Slider(
                value: Binding(
                    get: { Double(info.stillFrame) },
                    set: { value in
                        let frame = Int(value.rounded())
                        if frame != info.stillFrame { model.setStillFrame(frame, commit: false) }
                    }
                ),
                in: 0...Double(max(info.frameCount - 1, 1)),
                onEditingChanged: { isEditing in
                    if !isEditing, let frame = model.current?.stillFrame { model.setStillFrame(frame, commit: true) }
                }
            )
            .labelsHidden()
            .accessibilityLabel("Still frame")
            HStack {
                Text("Choose a frame")
                Spacer(minLength: 0)
                Text("\(info.stillFrame + 1) of \(info.frameCount)")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

import SwiftUI

/// One thumbnail in the library grid.
struct WallpaperTile: View {
    enum State: Equatable {
        case ready
        case missing
        case working(Double)
    }

    let name: String
    let image: NSImage?
    let isSelected: Bool
    let state: State
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    var body: some View {
        Button(action: action) {
            ZStack {
                shape.fill(.quaternary)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                switch state {
                case .ready:
                    EmptyView()
                case .missing:
                    shape.fill(.black.opacity(0.45))
                    Text("Missing")
                        .font(.caption2)
                        .foregroundStyle(.white)
                case .working(let progress):
                    shape.fill(.black.opacity(0.35))
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            .overlay {
                if isSelected {
                    shape.inset(by: -2).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The tile that adds a new wallpaper.
struct AddTile: View {
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    var body: some View {
        Button(action: action) {
            ZStack {
                shape.fill(.quaternary)
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help("Add a GIF or video")
        .accessibilityLabel("Add a GIF or video")
    }
}

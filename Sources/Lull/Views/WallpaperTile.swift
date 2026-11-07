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
    /// Shows a selection circle when cleaning up the library.
    var cleanupSelected: Bool?
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    var body: some View {
        Button(action: action) {
            shape.fill(.quaternary)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay {
                    // In an overlay, a wider image can't change the tile's size.
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .overlay {
                    switch state {
                    case .ready:
                        EmptyView()
                    case .missing:
                        ZStack {
                            shape.fill(.black.opacity(0.45))
                            Text("Missing")
                                .font(.caption2)
                                .foregroundStyle(.white)
                        }
                    case .working(let progress):
                        ZStack {
                            shape.fill(.black.opacity(0.35))
                            ProgressView(value: min(max(progress, 0), 1))
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .tint(.white)
                        }
                    }
                }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            .overlay {
                if isSelected {
                    shape.strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let cleanupSelected {
                    Image(systemName: cleanupSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .medium))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, cleanupSelected ? Color.accentColor : .black.opacity(0.35))
                        .background(Circle().fill(.black.opacity(cleanupSelected ? 0 : 0.2)))
                        .padding(3)
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

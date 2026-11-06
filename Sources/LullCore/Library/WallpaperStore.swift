import Foundation

/// The on-disk library: one folder per wallpaper, each with its own `info.json`.
public final class WallpaperStore: Sendable {
    public let root: URL
    private let moveToTrash: @Sendable (URL) throws -> Void

    public init(
        root: URL = WallpaperStore.defaultRoot(),
        moveToTrash: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.root = root
        self.moveToTrash = moveToTrash
    }

    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lull/Wallpapers", isDirectory: true)
    }

    public func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func url(_ filename: String, in id: UUID) -> URL {
        folder(for: id).appendingPathComponent(filename)
    }

    public func createFolder(for id: UUID) throws {
        try FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
    }

    public func save(_ info: WallpaperInfo) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(info).write(to: url(WallpaperFile.info, in: info.id), options: .atomic)
    }

    /// Every readable wallpaper, oldest first. An unreadable `info.json` hides only that wallpaper.
    public func loadAll() -> [WallpaperInfo] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { folder -> WallpaperInfo? in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(WallpaperFile.info)) else { return nil }
                return try? decoder.decode(WallpaperInfo.self, from: data)
            }
            .sorted { ($0.addedAt, $0.id.uuidString) < ($1.addedAt, $1.id.uuidString) }
    }

    /// Clears what an interrupted import left behind. Folders with an unreadable `info.json` are
    /// kept, because they may hold a person's only copy of a file.
    public func removeIncompleteItems() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.hasDirectoryPath {
            if !fm.fileExists(atPath: folder.appendingPathComponent(WallpaperFile.info).path) {
                try? fm.removeItem(at: folder)
                continue
            }
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasSuffix(WallpaperFile.partialSuffix) {
                try? fm.removeItem(at: file)
            }
        }
    }

    public func trash(id: UUID) throws {
        try moveToTrash(folder(for: id))
    }

    /// Permanently removes a folder that never became a finished wallpaper.
    public func discard(id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    public func fileExists(_ filename: String, in id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(filename, in: id).path)
    }

    public func isPreparedMissing(_ info: WallpaperInfo) -> Bool {
        !fileExists(WallpaperFile.prepared, in: info.id)
    }

    /// Whether the source needed to rebuild everything is gone.
    public func isOriginalMissing(_ info: WallpaperInfo) -> Bool {
        !fileExists(info.originalFilename ?? WallpaperFile.prepared, in: info.id)
    }
}

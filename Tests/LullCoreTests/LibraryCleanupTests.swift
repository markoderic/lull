import Foundation
import Testing
@testable import LullCore

@Suite("Library clean up")
struct LibraryCleanupTests {
    private func makeStore() throws -> WallpaperStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lull-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return WallpaperStore(root: root, moveToTrash: { try FileManager.default.removeItem(at: $0) })
    }

    @Test func diskUsageAddsUpEveryFileInAWallpapersFolder() throws {
        let store = try makeStore()
        let id = UUID()
        try store.createFolder(for: id)
        try Data(count: 1_000).write(to: store.url("prepared.mp4", in: id))
        try Data(count: 2_500).write(to: store.url("smooth-120.mp4", in: id))
        #expect(store.diskUsage(of: id) == 3_500)
    }

    @Test func aMissingFolderUsesNoSpace() throws {
        #expect(try makeStore().diskUsage(of: UUID()) == 0)
    }

    @Test func nothingSelectedSaysHowBigTheLibraryIs() {
        let summary = LibraryCleanup.summary(selected: 0, total: 5, selectedBytes: 0, totalBytes: 240_000_000)
        #expect(summary == "5 wallpapers, 240 MB")
    }

    @Test func oneWallpaperIsSingular() {
        let summary = LibraryCleanup.summary(selected: 0, total: 1, selectedBytes: 0, totalBytes: 23_000_000)
        #expect(summary == "1 wallpaper, 23 MB")
    }

    @Test func aSelectionSaysHowMuchSpaceItFrees() {
        let summary = LibraryCleanup.summary(selected: 2, total: 5, selectedBytes: 180_000_000, totalBytes: 240_000_000)
        #expect(summary == "2 of 5 selected, 180 MB")
    }

    @Test func theDeleteButtonNamesItsCount() {
        #expect(LibraryCleanup.deleteTitle(selected: 0) == "Delete")
        #expect(LibraryCleanup.deleteTitle(selected: 3) == "Delete 3")
    }

    @Test func theConfirmationIsSingularForOne() {
        #expect(LibraryCleanup.movedMessage(count: 1) == "Moved 1 wallpaper to the Trash.")
    }

    @Test func theConfirmationIsPluralForSeveral() {
        #expect(LibraryCleanup.movedMessage(count: 3) == "Moved 3 wallpapers to the Trash.")
    }

    @Test func aPartialFailureIsExplained() {
        #expect(LibraryCleanup.failedMessage(moved: 2, failed: 1) == "Moved 2 to the Trash, but 1 couldn't be moved.")
        #expect(LibraryCleanup.failedMessage(moved: 0, failed: 2) == "These wallpapers couldn't be moved to the Trash.")
    }
}

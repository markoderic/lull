import Foundation
import Testing
@testable import LullCore

@Suite("App location")
struct AppLocationTests {
    @Test func runningFromTheInstallerOffersToMove() {
        #expect(AppLocation.shouldOfferMove(bundlePath: "/Volumes/Lull/Lull.app"))
    }

    @Test func runningFromAQuarantineCopyOffersToMove() {
        #expect(AppLocation.shouldOfferMove(bundlePath: "/private/var/folders/ab/T/AppTranslocation/1234/d/Lull.app"))
    }

    @Test func runningFromApplicationsDoesnt() {
        #expect(!AppLocation.shouldOfferMove(bundlePath: "/Applications/Lull.app"))
    }

    @Test func runningFromYourOwnApplicationsFolderDoesnt() {
        #expect(!AppLocation.shouldOfferMove(bundlePath: "/Users/someone/Applications/Lull.app"))
    }

    @Test func aDevelopersOwnBuildDoesnt() {
        #expect(!AppLocation.shouldOfferMove(bundlePath: "/Users/someone/Projects/lull/dist/release/Lull.app"))
    }

    @Test func theInstallerVolumeIsFound() {
        #expect(AppLocation.volumeRoot(of: "/Volumes/Lull/Lull.app") == "/Volumes/Lull")
        #expect(AppLocation.volumeRoot(of: "/Applications/Lull.app") == nil)
    }

    private func makeBundle(in folder: URL, contents: String) throws -> URL {
        let bundle = folder.appendingPathComponent("Lull.app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: macOS.appendingPathComponent("Lull"))
        return bundle
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lull-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func executable(in bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("Contents/MacOS/Lull"), encoding: .utf8)
    }

    @Test func installingCopiesTheApp() throws {
        let source = try makeBundle(in: try temporaryFolder(), contents: "new")
        let applications = try temporaryFolder()
        let installed = try AppLocation.install(bundleAt: source, into: applications, moveExistingToTrash: { _ in })
        #expect(installed.path == applications.appendingPathComponent("Lull.app").path)
        #expect(try executable(in: installed) == "new")
    }

    @Test func installingReplacesAnOlderCopyByTrashingIt() throws {
        let source = try makeBundle(in: try temporaryFolder(), contents: "new")
        let applications = try temporaryFolder()
        _ = try makeBundle(in: applications, contents: "old")
        let trashed = TrashRecorder()
        let installed = try AppLocation.install(bundleAt: source, into: applications) { url in
            trashed.add(url)
            try FileManager.default.removeItem(at: url)
        }
        #expect(trashed.urls == [applications.appendingPathComponent("Lull.app")])
        #expect(try executable(in: installed) == "new")
    }

    @Test func aFailedInstallKeepsTheOlderCopy() throws {
        let source = URL(fileURLWithPath: "/no/such/Lull.app")
        let applications = try temporaryFolder()
        _ = try makeBundle(in: applications, contents: "old")
        #expect(throws: (any Error).self) {
            _ = try AppLocation.install(bundleAt: source, into: applications, moveExistingToTrash: { _ in
                Issue.record("the older copy shouldn't be touched when the new one can't be read")
            })
        }
        #expect(try executable(in: applications.appendingPathComponent("Lull.app")) == "old")
    }

    @Test func theInstalledCopyDoesntAskToBeApprovedASecondTime() throws {
        let source = try makeBundle(in: try temporaryFolder(), contents: "new")
        let flag = "0081;00000000;Safari;"
        #expect(setxattr(source.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0) == 0)
        let installed = try AppLocation.install(bundleAt: source, into: try temporaryFolder(), moveExistingToTrash: { _ in })
        #expect(getxattr(installed.path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
    }
}

@Suite("First launch")
struct FirstLaunchTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "lull-tests-\(UUID().uuidString)")!
    }

    @Test func aNewPersonHasntBeenWelcomed() {
        #expect(!AppSettings(defaults: defaults()).hasBeenWelcomed)
    }

    @Test func theWelcomeOnlyHappensOnce() {
        let store = defaults()
        AppSettings(defaults: store).hasBeenWelcomed = true
        #expect(AppSettings(defaults: store).hasBeenWelcomed)
    }

    @Test func thePanelOpensForSomeoneNewWithNothingAdded() {
        #expect(AppLocation.shouldWelcome(hasBeenWelcomed: false, wallpaperCount: 0))
    }

    @Test func itDoesntOpenAgainAfterThat() {
        #expect(!AppLocation.shouldWelcome(hasBeenWelcomed: true, wallpaperCount: 0))
    }

    @Test func itDoesntOpenForSomeoneAlreadyUsingIt() {
        #expect(!AppLocation.shouldWelcome(hasBeenWelcomed: false, wallpaperCount: 3))
    }
}

private final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    func add(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        stored.append(url)
    }
    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

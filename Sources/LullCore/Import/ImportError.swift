import AVFoundation
import Foundation

public enum ImportError: Error, Equatable, Sendable {
    case cantOpen
    case notEnoughDisk
    case smoothMotionUnavailable
    case smoothMotionFailed
    case failed

    /// What to show the person. Raw system errors never reach the interface.
    public var message: String {
        switch self {
        case .cantOpen: "Can't open this file. GIF, MP4 and MOV work."
        case .notEnoughDisk: "There isn't enough disk space for this."
        case .smoothMotionUnavailable: "Smooth Motion isn't available for this wallpaper."
        case .smoothMotionFailed: "Smooth Motion couldn't finish, so it's been turned off."
        case .failed: "This file couldn't be prepared."
        }
    }

    /// Maps any thrown error to one the interface can explain.
    public static func classify(_ error: Error) -> ImportError {
        if let error = error as? ImportError { return error }
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
             (NSPOSIXErrorDomain, Int(ENOSPC)),
             (AVFoundationErrorDomain, AVError.diskFull.rawValue):
            return .notEnoughDisk
        default:
            return .failed
        }
    }
}

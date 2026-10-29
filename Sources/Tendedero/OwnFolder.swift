import Foundation

/// Tendedero's own folder: where Quick Capture saves what it shoots, and the
/// one place whose files the line moves to the Trash when a photo leaves it.
/// Screenshots macOS takes are never touched: they stay wherever the system
/// saves them.
enum OwnFolder {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tendedero/Screenshots", isDirectory: true)
    }()

    /// Makes the folder exist, so a capture has somewhere to land.
    @discardableResult
    static func prepare() -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Whether this file lives in our own folder.
    static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }
}

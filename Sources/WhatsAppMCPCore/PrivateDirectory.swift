import Foundation

enum PrivateDirectory {
    /// Creates `url` and any missing parents, and makes `0700` only the directories this
    /// call created. A cache directory somebody pointed `--cache-directory` at — a home
    /// folder, `/tmp` — keeps whatever mode and owner it already has: its contents are
    /// protected by the files and sub-directories this server puts in it, and changing the
    /// mode of a directory it did not make is not this server's call.
    static func ensure(_ url: URL) throws {
        let fileManager = FileManager.default
        var missing: [URL] = []
        var current = url
        while !fileManager.fileExists(atPath: current.path), current.path != "/" {
            missing.append(current)
            current = current.deletingLastPathComponent()
        }
        for directory in missing.reversed() {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            // `createDirectory` applies the umask to the requested mode.
            try fileManager.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}

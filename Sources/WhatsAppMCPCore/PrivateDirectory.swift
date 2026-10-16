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

enum PrivateFile {
    /// Writes `data` to `url` so that the file is `0600` from its first byte and appears
    /// whole or not at all. `Data.write(options: .atomic)` creates its temporary under the
    /// umask and the mode is only set afterwards, which leaves a window — covered by the
    /// directory's `0700` where this server made it, and not at all where the cache
    /// directory already existed with looser permissions.
    static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        guard fileManager.createFile(
            atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}

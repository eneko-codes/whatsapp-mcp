import Foundation

/// A process-wide `umask` that is stricter than the default, for the moments a file is
/// created by a library that offers no way to set its mode (`VACUUM INTO`).
///
/// `umask` belongs to the process, not the thread, so two callers cannot each save and
/// restore it: the second would restore the first one's restrictive value and leave it
/// there for good. A counter under a lock makes the first caller in set it and the last
/// caller out put the original back. Being stricter than the default can only make another
/// thread's new file more private, never less.
enum PrivateUmask {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var depth = 0
    nonisolated(unsafe) private static var original: mode_t = 0

    static func run<T>(_ body: () throws -> T) rethrows -> T {
        lock.withLock {
            if depth == 0 { original = umask(0o077) }
            depth += 1
        }
        defer {
            lock.withLock {
                depth -= 1
                if depth == 0 { umask(original) }
            }
        }
        return try body()
    }
}

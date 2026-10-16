import Foundation

/// What a process has put on disk or started that must not outlive it.
///
/// A copy being made holds WhatsApp's keys until it has been scrubbed, and a conversion
/// leaves ffmpeg and a scratch directory behind if the server stops mid-call. Normal returns
/// clean up through `defer`, but a client that closes stdin, a `SIGTERM` or a closed pipe
/// skips every `defer`. This registry is what those paths run instead. `SIGKILL` cannot be
/// caught, so `SnapshotCache` also sweeps what an earlier process left behind.
///
/// One instance, `shared`, serves the whole process. It is a class and not a set of static
/// functions so that a test can use its own and call `run()` without deleting the files and
/// killing the children of every other test running beside it.
public final class ProcessCleanup: @unchecked Sendable {
    public static let shared = ProcessCleanup()

    private let lock = NSLock()
    private var paths: Set<String> = []
    private var children: [Int32: Process] = [:]
    private var sources: [DispatchSourceSignal] = []

    public init() {}

    public func register(path: String) { lock.withLock { _ = paths.insert(path) } }
    public func unregister(path: String) { lock.withLock { _ = paths.remove(path) } }

    public func register(child process: Process) {
        lock.withLock { children[process.processIdentifier] = process }
    }
    public func unregister(child process: Process) {
        lock.withLock { _ = children.removeValue(forKey: process.processIdentifier) }
    }

    /// Kills registered children and deletes registered files. Safe to call twice.
    public func run() {
        let (files, running) = lock.withLock { () -> ([String], [Process]) in
            let result = (Array(paths), Array(children.values))
            paths.removeAll()
            children.removeAll()
            return result
        }
        for process in running where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        for path in files {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
    }

    /// Runs `run()` and exits on the signals that end a stdio server, with the conventional
    /// 128+n status. `SIGPIPE` is one of them: it is how a client that has gone away shows up.
    public func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [self] in
                run()
                exit(128 + signalNumber)
            }
            source.resume()
            lock.withLock { sources.append(source) }
        }
    }
}

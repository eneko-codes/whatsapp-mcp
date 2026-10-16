import Foundation

/// What opening a path for reading would do, told apart by `errno`.
///
/// `FileManager.fileExists` answers a different question — whether the path can be seen —
/// and says "yes" for a file macOS will not let this process open. Reading WhatsApp's
/// container needs a privacy grant on recent macOS, so "there" and "readable" are not the
/// same fact, and the fix for each is different: open WhatsApp once, or grant access.
enum FileAccess: Equatable {
    case readable
    case missing
    /// `EPERM` or `EACCES`: macOS or the file's permissions refused.
    case denied
    case other(Int32)

    static func probe(_ path: String) -> FileAccess {
        // O_NONBLOCK: opening a FIFO for reading waits for a writer that never comes, and a
        // probe that can hang a thread forever is worse than the question it answers. A file
        // someone planted in WhatsApp's folder must not be able to do that.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if descriptor >= 0 {
            close(descriptor)
            return .readable
        }
        switch errno {
        case ENOENT, ENOTDIR: return .missing
        case EPERM, EACCES: return .denied
        case let code: return .other(code)
        }
    }
}

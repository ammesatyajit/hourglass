//
//  ChatDatabase.swift
//  Hourglass
//
//  Opens `~/Library/Messages/chat.db` READ-ONLY and exposes a GRDB
//  `DatabaseQueue` for the rest of the app to query.
//
//  REQUIREMENTS
//  ============
//  - **Full Disk Access** must be granted to the running process. In a
//    distributed build, that means the user enables it for `Hourglass.app`
//    in System Settings → Privacy & Security → Full Disk Access. In dev, the
//    same is required for the launching shell or Xcode.
//  - We open the database in **read-only** mode (`.readOnly`) and never
//    perform writes. The live `chat.db` is owned by Messages.app and mutating
//    it would corrupt the user's history.
//
//  DESIGN
//  ======
//  - One `DatabaseQueue` per process. GRDB serializes access on a private
//    queue, so it's safe to share across threads.
//  - We use a `DatabaseQueue` (not a `DatabasePool`) because pools need WAL
//    write access, which we don't have on a foreign read-only DB.
//  - Errors at open are surfaced as `ChatDatabase.OpenError` so callers can
//    distinguish "no FDA granted" from "file missing" from "schema mismatch".
//

import Foundation
import GRDB

public final class ChatDatabase: @unchecked Sendable {

    public enum OpenError: Error, CustomStringConvertible {
        case fileMissing(URL)
        case accessDenied(URL, underlying: Error)
        case underlying(Error)

        public var description: String {
            switch self {
            case .fileMissing(let url):
                return "chat.db not found at \(url.path)"
            case .accessDenied(let url, let underlying):
                return """
                Could not open chat.db at \(url.path).
                This usually means Full Disk Access is not granted to the running process.
                Underlying error: \(underlying)
                """
            case .underlying(let err):
                return "chat.db open failed: \(err)"
            }
        }
    }

    public let dbQueue: DatabaseQueue
    public let url: URL

    /// Default location of the user's chat.db.
    public static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "Library/Messages/chat.db", directoryHint: .notDirectory)
    }

    public init(url: URL = ChatDatabase.defaultURL) throws {
        self.url = url

        // Verify the file is reachable before letting GRDB's error message
        // become the only signal — we want to distinguish "file missing" from
        // "permission denied" cleanly.
        if !FileManager.default.fileExists(atPath: url.path) {
            throw OpenError.fileMissing(url)
        }

        var config = Configuration()
        config.readonly = true
        // Defensive: even though `readonly=true` blocks writes, ensure no
        // implicit transactions try to create journal/shm/wal files we
        // don't have permission to.
        config.busyMode = .timeout(2.0)

        do {
            self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_AUTH
            || error.resultCode == .SQLITE_PERM
            || error.resultCode == .SQLITE_CANTOPEN {
            throw OpenError.accessDenied(url, underlying: error)
        } catch {
            // POSIX errno 1 (EPERM) / 13 (EACCES) usually means TCC denial.
            let ns = error as NSError
            if ns.domain == NSPOSIXErrorDomain && (ns.code == 1 || ns.code == 13) {
                throw OpenError.accessDenied(url, underlying: error)
            }
            throw OpenError.underlying(error)
        }
    }

    /// Lightweight smoke test — returns the highest `message.ROWID` in the DB,
    /// or throws. Use to verify the connection is healthy and FDA is granted.
    public func maxMessageRowID() throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(ROWID) FROM message") ?? 0
        }
    }
}

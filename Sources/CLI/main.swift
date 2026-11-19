//
//  main.swift
//  hourglass-cli
//
//  Headless command-line access to Hourglass's CANONICAL engine — the same
//  ContactResolver, ChatListing, and search engines the app uses. Built for
//  external analysis tooling (Claude-driven forensics, scripts, future MCP
//  shims) so nothing ever re-implements identity resolution or search
//  semantics against raw chat.db again.
//
//  Subcommands (all output is stable, pipe-separated UTF-8 on stdout):
//    identity                 HANDLE|<raw>|<displayName> and CHAT|<rowid>|<label>
//    chats [query]            CHAT|<rowid>|<group|dm>|<label> (label-filtered)
//    search <query> [limit]   RESULT|<ISO date>|<chat label>|<sender>|<body one-line>
//
//  Read-only by construction: ChatDatabase opens chat.db read-only, and the
//  FTS index is only read (never built) here — if the mirror is stale the
//  search falls back to the INSTR engine exactly like the app does.
//

import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + msg + "\n").utf8))
    exit(1)
}

func oneLine(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "|", with: "¦")
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: hourglass-cli <identity|chats|search> …")
}

let contacts = ContactResolver.resolve()
guard let db = try? ChatDatabase() else {
    fail("cannot open chat.db — grant Full Disk Access to the invoking terminal")
}

switch command {
case "identity":
    for c in contacts.allContacts {
        for h in c.handles {
            print("HANDLE|\(oneLine(h.raw))|\(oneLine(c.displayName))")
        }
    }
    if let chats = try? ChatListing.allChats(database: db, contacts: contacts) {
        for chat in chats {
            print("CHAT|\(chat.rowID)|\(oneLine(chat.label))")
        }
    }

case "chats":
    let query = args.count > 1 ? args[1].lowercased() : nil
    guard let chats = try? ChatListing.allChats(database: db, contacts: contacts) else {
        fail("chat listing failed")
    }
    for chat in chats {
        if let q = query, !chat.label.lowercased().contains(q) { continue }
        print("CHAT|\(chat.rowID)|\(chat.isGroup ? "group" : "dm")|\(oneLine(chat.label))")
    }

case "search":
    guard args.count > 1 else { fail("usage: hourglass-cli search <query> [limit]") }
    let phrase = args[1]
    let limit = args.count > 2 ? Int(args[2]) ?? 50 : 50
    // Engine pick mirrors SearchViewModel: FTS when the mirror is fresh,
    // INSTR otherwise.
    let instr = MessageSearch(database: db, contacts: contacts)
    var results: [MessageSearch.Result] = []
    if let store = try? IndexStore(),
       case .ready = (try? store.freshness(against: db)) ?? .missing {
        let fts = FTSSearcher(store: store, chatDB: db, contacts: contacts)
        results = (try? fts.search(phrase: phrase, limit: limit)) ?? []
    }
    if results.isEmpty {
        results = (try? instr.search(phrase: phrase, limit: limit)) ?? []
    }
    let iso = ISO8601DateFormatter()
    for r in results {
        print("RESULT|\(iso.string(from: r.message.date))|\(oneLine(r.partnerName))|\(oneLine(r.senderName))|\(oneLine(r.message.body))")
    }

default:
    fail("unknown subcommand '\(command)' — expected identity|chats|search")
}

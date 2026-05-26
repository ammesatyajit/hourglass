#!/usr/bin/env swift
//
//  smoke-guid-reveal.swift
//  End-to-end smoke for the GUID-based reveal pipeline. Mirrors the logic in
//  `Sources/Reveal/MessagesGUIDReveal.swift` so it runs as a standalone Swift
//  invocation (no `import Hourglass`).
//
//  USAGE (from repo root):
//      swift scripts/smoke-guid-reveal.swift <chat_guid> <message_guid> [<expected_body>]
//
//  Example:
//      swift scripts/smoke-guid-reveal.swift "any;-;+15551234567" "ABCDE…" "hello"
//
//  Opens the chat via sms://open?groupid=… and then walks Messages.app's
//  Accessibility tree to find the message bubble whose AXDescription matches
//  `<expected_body>` (or the most-recent bubble if no body given).
//
//  Reports what was found and whether AXScrollToVisible succeeded.
//
//  REQUIRES: Accessibility permission for the running shell (Settings →
//  Privacy & Security → Accessibility). Messages.app must be running.
//

import Cocoa
import ApplicationServices

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: \(args[0]) <chat_guid> <message_guid> [<expected_body>]")
    exit(2)
}

let chatGUID = args[1]
let messageGUID = args[2]
let expectedBody = args.count > 3 ? args[3] : ""

// MARK: - URL construction (mirrors MessagesGUIDReveal)

func chatIdentifier(fromChatGUID guid: String) -> String? {
    let parts = guid.split(separator: ";", omittingEmptySubsequences: false)
    if parts.count == 3 {
        let id = String(parts[2])
        return id.isEmpty ? nil : id
    }
    return guid
}

func chatOpenURL(forChatIdentifier identifier: String) -> URL? {
    let escaped = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
    return URL(string: "sms://open?groupid=\(escaped)")
}

guard let chatID = chatIdentifier(fromChatGUID: chatGUID),
      let url = chatOpenURL(forChatIdentifier: chatID) else {
    print("[fail] couldn't parse chat GUID")
    exit(1)
}

print("[1/4] chat_id = \(chatID)")
print("[2/4] open URL = \(url.absoluteString)")
print("[3/4] message GUID  = \(messageGUID)")
print("[4/4] expected body = \(expectedBody.isEmpty ? "(none — attachment)" : expectedBody)")
print()

// Open chat
let opened = NSWorkspace.shared.open(url)
print("NSWorkspace.shared.open returned: \(opened)")

// Settle
Thread.sleep(forTimeInterval: 0.7)

// AX walk
let options: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
guard AXIsProcessTrustedWithOptions(options) else {
    print("[fail] Accessibility permission not granted to this shell.")
    exit(1)
}

guard let messagesApp = NSWorkspace.shared.runningApplications
    .first(where: { $0.bundleIdentifier == "com.apple.MobileSMS" }) else {
    print("[fail] Messages.app not running")
    exit(1)
}

let app = AXUIElementCreateApplication(messagesApp.processIdentifier)

func get<T>(_ elem: AXUIElement, _ attr: String) -> T? {
    var v: AnyObject?
    let err = AXUIElementCopyAttributeValue(elem, attr as CFString, &v)
    guard err == .success else { return nil }
    return v as? T
}

func axString(_ elem: AXUIElement, _ attr: String) -> String? {
    get(elem, attr)
}

func axChildren(_ elem: AXUIElement) -> [AXUIElement] {
    var v: AnyObject?
    let err = AXUIElementCopyAttributeValue(elem, "AXChildren" as CFString, &v)
    guard err == .success, let arr = v as? [AXUIElement] else { return [] }
    return arr
}

func findFirst(_ root: AXUIElement, identifier: String, maxDepth: Int = 30) -> AXUIElement? {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    while let (elem, depth) = stack.popLast() {
        if depth > maxDepth { continue }
        if let id: String = axString(elem, "AXIdentifier"), id == identifier {
            return elem
        }
        for c in axChildren(elem) { stack.append((c, depth + 1)) }
    }
    return nil
}

func findAll(_ root: AXUIElement, identifier: String, maxDepth: Int = 30) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    while let (elem, depth) = stack.popLast() {
        if depth > maxDepth { continue }
        if let id: String = axString(elem, "AXIdentifier"), id == identifier {
            out.append(elem)
        }
        for c in axChildren(elem) { stack.append((c, depth + 1)) }
    }
    return out
}

// Find the chat transcript
guard let window: AXUIElement = get(app, "AXFocusedWindow") ?? get(app, "AXMainWindow") else {
    print("[fail] no focused window")
    exit(1)
}
let windowTitle: String? = axString(window, "AXTitle")
print("Front window title: \(windowTitle ?? "(none)")")

guard let transcript = findFirst(window, identifier: "TranscriptCollectionView") else {
    print("[fail] no TranscriptCollectionView in AX tree")
    exit(1)
}

let bubbles = findAll(transcript, identifier: "Sticker")
print("Found \(bubbles.count) message bubbles in AX tree.")

// Print descriptions (truncated for privacy)
print("Visible descriptions (first 5):")
for b in bubbles.prefix(5) {
    let desc: String? = axString(b, "AXDescription")
    let preview = (desc ?? "").prefix(60)
    print("  - \(preview)...")
}

// Match by expected body if given. (The full needle-set match is in
// the Swift module — this smoke uses the simpler body-only contains check.)
let needle = expectedBody.lowercased()
var matched: AXUIElement?
if !needle.isEmpty {
    for b in bubbles {
        let desc = (axString(b, "AXDescription") ?? "").lowercased()
        if desc.contains(needle) {
            matched = b
            print("\n[match] description contains body: <REDACTED \(desc.count) chars>")
            break
        }
    }
}

if let m = matched {
    let err = AXUIElementPerformAction(m, "AXScrollToVisible" as CFString)
    print("AXScrollToVisible err = \(err.rawValue) (0 = success)")
} else {
    print("\n[no AX match] message not in visible AX tree. Chat is open at most-recent position.")
}

print("\n[done] smoke test complete.")

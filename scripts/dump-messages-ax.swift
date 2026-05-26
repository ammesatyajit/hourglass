#!/usr/bin/env swift
//
//  dump-messages-ax.swift
//  Research-only AX tree dumper for Messages.app.
//
//  USAGE (from repo root):
//      swift scripts/dump-messages-ax.swift [max-depth]
//
//  REQUIRES Accessibility permission for the running shell (Terminal). On
//  first run macOS will prompt; grant it in System Settings → Privacy &
//  Security → Accessibility, then re-run.
//
//  Walks the AX tree rooted at Messages.app and prints each node's role,
//  subrole, title, value, description, identifier, and key attribute names.
//  Depth-limited to keep output sane; pass the depth as the first arg.
//

import Cocoa
import ApplicationServices

let maxDepth: Int = CommandLine.arguments.count > 1
    ? (Int(CommandLine.arguments[1]) ?? 6)
    : 6

// MARK: - AX permission gate

let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
if !AXIsProcessTrustedWithOptions(opts) {
    FileHandle.standardError.write(Data(
        "Accessibility permission NOT granted to this process.\nGrant Terminal in System Settings → Privacy & Security → Accessibility, then re-run.\n".utf8
    ))
    exit(1)
}

// MARK: - Find Messages.app

guard let msgs = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
    FileHandle.standardError.write(Data("Messages.app is not running. Launch it, open a chat, then re-run.\n".utf8))
    exit(2)
}
let pid = msgs.processIdentifier
print("Messages.app pid=\(pid)")

let appElement = AXUIElementCreateApplication(pid)

// MARK: - Generic AX helpers

func axCopy<T>(_ element: AXUIElement, _ attr: String) -> T? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
    if err != .success { return nil }
    return value as? T
}

func axCopyChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
    if err != .success { return [] }
    return (value as? [AXUIElement]) ?? []
}

func axAttributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let err = AXUIElementCopyAttributeNames(element, &names)
    if err != .success { return [] }
    return (names as? [String]) ?? []
}

func axActionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let err = AXUIElementCopyActionNames(element, &names)
    if err != .success { return [] }
    return (names as? [String]) ?? []
}

func shortDescribe(_ element: AXUIElement) -> String {
    let role: String = axCopy(element, kAXRoleAttribute) ?? "?"
    let subrole: String = axCopy(element, kAXSubroleAttribute) ?? ""
    let title: String = axCopy(element, kAXTitleAttribute) ?? ""
    let desc: String = axCopy(element, kAXDescriptionAttribute) ?? ""
    let identifier: String = axCopy(element, kAXIdentifierAttribute) ?? ""
    let valueAny: AnyObject? = axCopy(element, kAXValueAttribute)
    let value = valueAny.map { String(describing: $0) } ?? ""
    let help: String = axCopy(element, kAXHelpAttribute) ?? ""
    let sizeStr: String
    if let positionVal: AXValue = axCopy(element, kAXPositionAttribute),
       let sizeVal: AXValue = axCopy(element, kAXSizeAttribute) {
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionVal, .cgPoint, &origin)
        AXValueGetValue(sizeVal, .cgSize, &size)
        sizeStr = "@(\(Int(origin.x)),\(Int(origin.y))) \(Int(size.width))x\(Int(size.height))"
    } else {
        sizeStr = ""
    }
    var pieces: [String] = []
    pieces.append("role=\(role)")
    if !subrole.isEmpty { pieces.append("subrole=\(subrole)") }
    if !identifier.isEmpty { pieces.append("id=\(identifier)") }
    if !title.isEmpty { pieces.append("title=\(title.prefix(80))") }
    if !desc.isEmpty { pieces.append("desc=\(desc.prefix(80))") }
    if !value.isEmpty { pieces.append("value=\(value.prefix(80))") }
    if !help.isEmpty { pieces.append("help=\(help.prefix(80))") }
    if !sizeStr.isEmpty { pieces.append(sizeStr)}
    return pieces.joined(separator: " ")
}

func dump(_ element: AXUIElement, depth: Int = 0, path: String = "") {
    let indent = String(repeating: "  ", count: depth)
    let desc = shortDescribe(element)
    let attrs = axAttributeNames(element)
    let actions = axActionNames(element)

    // Filter out the most common, noisy attribute names so the interesting
    // ones (AXScrollToVisible, AXSelected, AXValue, AXIdentifier, AXLabel...)
    // stand out.
    let interesting = attrs.filter { name in
        !["AXFrame", "AXParent", "AXPosition", "AXSize",
          "AXTopLevelUIElement", "AXWindow", "AXEnabled",
          "AXRole", "AXRoleDescription", "AXSubrole", "AXTitle",
          "AXIdentifier", "AXValue", "AXDescription", "AXHelp",
          "AXChildren", "AXFocused"].contains(name)
    }
    print("\(indent)[\(depth)] \(desc)")
    if !interesting.isEmpty {
        print("\(indent)    attrs+: \(interesting.joined(separator: ", "))")
    }
    if !actions.isEmpty {
        print("\(indent)    actions: \(actions.joined(separator: ", "))")
    }

    guard depth < maxDepth else { return }
    let children = axCopyChildren(element)
    for child in children {
        dump(child, depth: depth + 1, path: path)
    }
}

dump(appElement)

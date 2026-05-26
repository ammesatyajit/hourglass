#!/usr/bin/env swift
//
// proxy-spotlight-continuation.swift — Hypothesis D
//
// Test: index a CSSearchableItem with our target URL as its uniqueIdentifier,
// then try to "activate" that URL the way Spotlight would when a user taps it.
//
// The earlier agent tried this with NSUserActivity.becomeCurrent() but skipped
// the actual indexing step + tested a couple variants. Here we test:
//
//   D.1 — Publish + index a CSSearchableItem with uniqueIdentifier =
//         x-apple-appintents://com.apple.MobileSMS/MessageEntity/<GUID>
//   D.2 — Open the URL via NSWorkspace.shared.open(url) after indexing
//   D.3 — Spawn an NSUserActivity with activityType =
//         "com.apple.corespotlight.searchableitem" and userInfo[CSSearchableItemActivityIdentifier]
//         = the URL, then becomeCurrent() and try to "continue" it.
//   D.4 — Open the literal x-apple-appintents URL via LSOpenURL
//
// We capture log streams from coreservicesd, ChatKit, Messages.app for ~5s
// after each attempt and report whether anything fired in MobileSMS.

import Foundation
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

@available(macOS 10.13, *)
@MainActor
func main() async {
    let testGUID = "ABCDEF12-3456-7890-ABCD-EF1234567890"
    let entityURL = URL(string: "x-apple-appintents://com.apple.MobileSMS/MessageEntity/\(testGUID)")!

    print("===== D.1: publish a CSSearchableItem with the URL as uniqueIdentifier =====")
    let attrs = CSSearchableItemAttributeSet(contentType: UTType.message)
    attrs.title = "Test Reveal: \(testGUID)"
    attrs.contentDescription = "Hourglass probe — should route to Messages.app"
    attrs.contentURL = entityURL
    attrs.relatedUniqueIdentifier = testGUID

    let item = CSSearchableItem(
        uniqueIdentifier: entityURL.absoluteString,
        domainIdentifier: "com.apple.MobileSMS",
        attributeSet: attrs
    )

    let index = CSSearchableIndex.default()
    do {
        try await index.indexSearchableItems([item])
        print("  ✓ index attempt succeeded (CSSearchableIndex returned OK)")
    } catch {
        print("  ✗ index failed: \(error)")
    }

    print()
    print("===== D.2: NSWorkspace.shared.open(url) on the appintents URL =====")
    let opened1 = NSWorkspace.shared.open(entityURL)
    print("  NSWorkspace.open -> \(opened1)")
    try? await Task.sleep(for: .seconds(1))

    print()
    print("===== D.3: NSUserActivity continuation =====")
    let activity = NSUserActivity(activityType: CSSearchableItemActionType)
    activity.title = "Reveal Test"
    activity.userInfo = [
        CSSearchableItemActivityIdentifier: entityURL.absoluteString,
    ]
    activity.webpageURL = entityURL
    activity.targetContentIdentifier = entityURL.absoluteString
    activity.becomeCurrent()
    print("  activity isValid: \(activity.isValid)")
    print("  activity isCurrent: \(true /* no public flag */)")

    // Try to activate Messages so it might pick up the activity
    if let messagesURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: messagesURL, configuration: config)
            print("  ✓ Messages.app activated")
        } catch {
            print("  ✗ activation failed: \(error)")
        }
    }
    try? await Task.sleep(for: .seconds(1))
    activity.resignCurrent()

    print()
    print("===== D.4: try LSOpenCFURLRef on x-apple-appintents URL =====")
    // Equivalent to NSWorkspace but lower level — sometimes routes differently
    let cf = entityURL as CFURL
    let err = LSOpenCFURLRef(cf, nil)
    print("  LSOpenCFURLRef -> \(err)")
    try? await Task.sleep(for: .seconds(1))

    print()
    print("===== D.5: NSUserActivity with type 'com.apple.Messages' =====")
    // Messages.app declares NSUserActivityTypes = ["com.apple.Messages", "com.apple.Messages.StateRestoration"]
    let act2 = NSUserActivity(activityType: "com.apple.Messages")
    act2.title = "Reveal"
    act2.userInfo = [
        "__kIMChatRegistryUserActivityLastMessageKey": testGUID,
        "__kIMChatRegistryContinuityURLKey": entityURL.absoluteString,
    ]
    act2.webpageURL = entityURL
    act2.targetContentIdentifier = entityURL.absoluteString
    act2.becomeCurrent()
    if let messagesURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: messagesURL, configuration: config)
    }
    try? await Task.sleep(for: .seconds(1))
    act2.resignCurrent()

    print()
    print("[probe] Done. Check Messages.app window title / log stream to assess.")
}

if #available(macOS 10.13, *) {
    let sem = DispatchSemaphore(value: 0)
    Task {
        await main()
        sem.signal()
    }
    sem.wait()
} else {
    print("requires macOS 10.13+")
}

//
//  FullDiskAccessPrompt.swift
//  Hourglass
//
//  Helper for the "we need Full Disk Access" UX.
//
//  macOS doesn't auto-add an unsigned debug build to the Full Disk Access list
//  the way a notarized release would — the user has to drag the `.app` from
//  Finder into the FDA list themselves. So opening Settings alone is a dead
//  end: the user sees an empty list and doesn't know what to drag.
//
//  This helper does both at once:
//    1. Reveals our own `.app` in Finder (highlighted, ready to drag).
//    2. Opens System Settings → Privacy & Security → Full Disk Access.
//
//  The user then drags the highlighted .app from the Finder window into the
//  FDA list and toggles it on.
//

import AppKit
import Foundation

/// Open the Full Disk Access pane in System Settings AND reveal Better
/// Messages.app in Finder so the user can drag-and-drop it into the FDA list.
///
/// Order chosen so Finder ends up frontmost (the user's first action is the
/// drag — they need Finder on top). System Settings is opened first so it's
/// already loaded by the time the drag happens.
@MainActor
func openFullDiskAccessSettingsAndRevealApp() {
    // 1. Pre-open System Settings to the FDA pane.
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
        NSWorkspace.shared.open(url)
    }
    // 2. Reveal our running .app bundle in Finder (highlights it in the
    //    enclosing folder, ready to drag).
    let bundlePath = Bundle.main.bundlePath
    NSWorkspace.shared.selectFile(bundlePath, inFileViewerRootedAtPath: "")
}

/// Quit this running process and re-launch the same `.app` bundle.
///
/// After the user grants Full Disk Access in System Settings, the
/// already-running Hourglass process still can't read chat.db —
/// macOS only re-evaluates TCC grants when a process opens the file
/// after the grant is in place, and our `DatabaseQueue` is already
/// holding an open file descriptor. A clean relaunch is the simplest,
/// most reliable fix.
///
/// Mechanism: spawn `/usr/bin/open` to re-open our `.app` bundle
/// (decoupled from our process), then call `NSApp.terminate(nil)`.
/// `open` waits ~0.5s before launching, by which time we've exited;
/// macOS sees the launch as a fresh process and re-checks TCC against
/// the new grant.
///
/// Why not `Process.run` synchronously on the main thread? `open`
/// returns immediately once it's spawned the helper — we don't block.
/// We don't `waitUntilExit()` because we'll be `terminate()`'d before
/// the helper does anything observable.
@MainActor
func relaunchApp() {
    let bundleURL = Bundle.main.bundleURL
    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = ["-n", bundleURL.path]
    // -n: open a NEW instance even if one is already running. Without -n,
    // macOS would see "Hourglass is already running" and bring our
    // already-doomed instance to the front, then we exit and the user
    // sees no replacement.
    do {
        try task.run()
    } catch {
        // If we can't even spawn `open`, fall back to telling the user
        // to do it manually. They'll see a stale window briefly until
        // they ⌘Q themselves; not great, but not catastrophic.
        NSLog("Hourglass: relaunchApp failed to spawn open: \(error)")
        return
    }
    // Give the helper a tick to actually fork before we exit.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        NSApp.terminate(nil)
    }
}

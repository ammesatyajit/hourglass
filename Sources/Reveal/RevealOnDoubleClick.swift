//
//  RevealOnDoubleClick.swift
//  Hourglass — universal double-click-to-reveal (0.3.1)
//
//  ONE modifier so any message rendered anywhere in the app opens
//  Messages.app at that exact message on double-click — same Spotlight-grade
//  deep link the search panel uses, including bringing Messages to the front
//  when another app is focused. Views opt in with:
//
//      .revealsInMessages(MessageRevealTarget(memoryMessage))
//
//  Passing nil leaves the view untouched, so callers don't need to branch on
//  whether their model carried a GUID.
//

import SwiftUI

/// The minimal identity needed to reveal a message. Built from any model in
/// the app that knows its message — `MemoryMessage`, `MessageSearch.Result`,
/// or raw fields.
public struct MessageRevealTarget {
    public let messageGUID: String?
    public let chatGUID: String?
    public let body: String
    public let senderName: String
    public let isFromMe: Bool
    public let date: Date

    public init(
        messageGUID: String?,
        chatGUID: String?,
        body: String,
        senderName: String,
        isFromMe: Bool,
        date: Date
    ) {
        self.messageGUID = messageGUID
        self.chatGUID = chatGUID
        self.body = body
        self.senderName = senderName
        self.isFromMe = isFromMe
        self.date = date
    }
}

public extension View {
    /// Double-click anywhere on this view → open Messages.app scrolled to the
    /// message via the Spotlight-grade deep link. STRICTLY deep-link only:
    /// a target without a message GUID gets NO gesture (the app must never
    /// take control of Messages — no synthesized keystrokes, no AX driving).
    @ViewBuilder
    func revealsInMessages(_ target: MessageRevealTarget?) -> some View {
        if let target, let guid = target.messageGUID {
            self
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Task { @MainActor in
                        _ = await MessagesGUIDReveal.reveal(
                            messageGUID: guid,
                            chatGUID: target.chatGUID,
                            body: target.body,
                            senderName: target.senderName,
                            isFromMe: target.isFromMe,
                            messageDate: target.date
                        )
                    }
                }
                .help("Double-click to open in Messages")
        } else {
            self
        }
    }
}

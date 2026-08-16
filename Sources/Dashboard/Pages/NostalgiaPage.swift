//
//  NostalgiaPage.swift
//  Hourglass — Dashboard / Nostalgia page
//
//  The "Nostalgia" sidebar page. Renders the existing `NostalgiaPanel`
//  unchanged (it gets rebuilt in a later pass). The panel owns its own
//  `NostalgiaViewModel` and runs its DB-backed analysis on appear — so this
//  page's heavy work runs only when the user selects "Nostalgia" in the
//  sidebar, never while sitting on Overview.
//
//  `NostalgiaPanel` needs three inputs the shared dashboard VM already owns:
//  `database`, `contacts`, and the all-time `aggregate`. The aggregate is
//  preloaded off-main shortly after launch; until it lands we show a graceful
//  loading state so the page never renders a half-built panel.
//

import SwiftUI

struct NostalgiaPage: View {

    let database: ChatDatabase?
    let contacts: ResolvedContacts?
    let aggregate: DashboardAllTimeAggregate?
    /// Summon the Spotlight panel (header pill).
    let onSearchTap: () -> Void

    var body: some View {
        DashboardScrollPage(
            title: "Nostalgia",
            subtitle: "Memories, milestones & people you used to talk to",
            onSearchTap: onSearchTap,
            content: { content }
        )
    }

    @ViewBuilder
    private var content: some View {
        if let db = database, let contacts, let aggregate {
            NostalgiaPanel(database: db, contacts: contacts, aggregate: aggregate)
                .frame(maxWidth: .infinity)
        } else if database == nil {
            DashboardAccessPrompt(message: "Database unavailable")
        } else {
            // DB is open but the all-time aggregate is still preloading. Hold a
            // graceful placeholder so the page never shows a partial panel.
            VStack(spacing: Space.md) {
                ProgressView()
                Text("Gathering your memories…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }
}

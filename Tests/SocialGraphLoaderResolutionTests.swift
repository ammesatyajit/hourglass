//
//  SocialGraphLoaderResolutionTests.swift
//  HourglassTests — Social Graph
//
//  Tests for the loader's PURE helpers — handle → merged-contact node id
//  resolution and contact-info assembly. These are the "contact resolution is
//  half the feature" pieces; we exercise them with a hand-built
//  `ResolvedContacts` so no chat.db / AddressBook is required.
//

import XCTest
@testable import Hourglass

final class SocialGraphLoaderResolutionTests: XCTestCase {

    /// A resolver where Mom has TWO handles (phone + email) and there's a
    /// "Me" contact.
    private func fixtureContacts() -> ResolvedContacts {
        let momPhone = Handle(raw: "+15551112222")
        let momEmail = Handle(raw: "mom@icloud.com")
        let mom = Contact(displayName: "Mom", handles: [momPhone, momEmail], avatarData: nil)

        let bobPhone = Handle(raw: "+15553334444")
        let bob = Contact(displayName: "Bob", handles: [bobPhone], avatarData: nil)

        let mePhone = Handle(raw: "+15559998888")
        let me = Contact(displayName: "Me Myself", handles: [mePhone], avatarData: nil)

        var byHandle: [Handle: Contact] = [:]
        byHandle[momPhone] = mom
        byHandle[momEmail] = mom
        byHandle[bobPhone] = bob
        byHandle[mePhone] = me

        return ResolvedContacts(
            byHandle: byHandle,
            allContacts: [bob, mom, me].sorted { $0.displayName < $1.displayName },
            meContact: me
        )
    }

    // MARK: - nodeID resolution

    func testNodeID_mergesMultipleHandlesForSamePerson() {
        let contacts = fixtureContacts()
        let viaPhone = SocialGraphLoader.nodeID(forRawHandle: "+15551112222", contacts: contacts, meContact: contacts.meContact)
        let viaEmail = SocialGraphLoader.nodeID(forRawHandle: "mom@icloud.com", contacts: contacts, meContact: contacts.meContact)
        XCTAssertEqual(viaPhone.id, "name:Mom")
        XCTAssertEqual(viaEmail.id, "name:Mom")
        XCTAssertEqual(viaPhone.id, viaEmail.id, "phone + email collapse to ONE node")
        XCTAssertEqual(viaPhone.displayName, "Mom")
    }

    func testNodeID_phoneFormattingNormalizes() {
        let contacts = fixtureContacts()
        // Same number, punctuated differently → same merged node.
        let a = SocialGraphLoader.nodeID(forRawHandle: "(555) 111-2222", contacts: contacts, meContact: contacts.meContact)
        XCTAssertEqual(a.id, "name:Mom")
    }

    func testNodeID_unknownHandleKeepsHandleKey() {
        let contacts = fixtureContacts()
        let r = SocialGraphLoader.nodeID(forRawHandle: "+15550000000", contacts: contacts, meContact: contacts.meContact)
        XCTAssertEqual(r.id, "handle:+15550000000")
        XCTAssertEqual(r.displayName, "+15550000000")
        XCTAssertNil(r.avatar)
    }

    func testNodeID_meHandleCollapsesToCenter() {
        let contacts = fixtureContacts()
        let r = SocialGraphLoader.nodeID(forRawHandle: "+15559998888", contacts: contacts, meContact: contacts.meContact)
        XCTAssertEqual(r.id, "me", "the user's own handle resolves to the center node, not a duplicate")
    }

    // MARK: - fallbackLabel

    func testFallbackLabel_stripsPrefixes() {
        XCTAssertEqual(SocialGraphLoader.fallbackLabel(forID: "handle:+15551234567"), "+15551234567")
        XCTAssertEqual(SocialGraphLoader.fallbackLabel(forID: "name:Mom"), "Mom")
        XCTAssertEqual(SocialGraphLoader.fallbackLabel(forID: "weird"), "weird")
    }

    // MARK: - buildContactInfo

    func testBuildContactInfo_seedsDirectCountsAndGroupOnlyMembers() {
        let contacts = fixtureContacts()
        let memberships: [ChatMembership] = [
            // group with Mom + an unknown handle
            ChatMembership(chatRowID: 1, isGroup: true, participantNodeIDs: ["name:Mom", "handle:+15550000000"]),
        ]
        let directCounts = ["name:Mom": 42]

        let info = SocialGraphLoader.buildContactInfo(
            memberships: memberships,
            directCounts: directCounts,
            contacts: contacts,
            meNodeID: "me"
        )

        // Mom: from direct counts, label from resolved contacts.
        XCTAssertEqual(info["name:Mom"]?.directMessageCount, 42)
        XCTAssertEqual(info["name:Mom"]?.displayName, "Mom")

        // Unknown group-only handle: 0 direct volume, label == the number.
        XCTAssertEqual(info["handle:+15550000000"]?.directMessageCount, 0)
        XCTAssertEqual(info["handle:+15550000000"]?.displayName, "+15550000000")
    }

    func testBuildContactInfo_excludesMe() {
        let contacts = fixtureContacts()
        let directCounts = ["me": 99, "name:Bob": 5]
        let info = SocialGraphLoader.buildContactInfo(
            memberships: [], directCounts: directCounts, contacts: contacts, meNodeID: "me"
        )
        XCTAssertNil(info["me"], "center node never appears as a contact")
        XCTAssertEqual(info["name:Bob"]?.directMessageCount, 5)
    }

    // MARK: - makeMeNode

    func testMakeMeNode_usesMeContactWhenPresent() {
        let contacts = fixtureContacts()
        let node = SocialGraphLoader.makeMeNode(contacts: contacts)
        XCTAssertEqual(node.id, "me")
        XCTAssertTrue(node.isMe)
        XCTAssertEqual(node.displayName, "Me Myself")
    }

    func testMakeMeNode_fallsBackToYou() {
        let contacts = ResolvedContacts(byHandle: [:], allContacts: [], meContact: nil)
        let node = SocialGraphLoader.makeMeNode(contacts: contacts)
        XCTAssertEqual(node.displayName, "You")
        XCTAssertTrue(node.isMe)
    }
}

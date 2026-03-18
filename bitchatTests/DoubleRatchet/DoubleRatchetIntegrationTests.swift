//
// DoubleRatchetIntegrationTests.swift
// bitchatTests
//

import Foundation
import NdrFfi
import Testing
@testable import bitchat

struct DoubleRatchetIntegrationTests {

    @Test("ndr-ffi version is 0.0.85 (nostr-double-ratchet 0.0.85)")
    func ndrFfiVersion_is_0_0_85() {
        #expect(version() == "0.0.85")
    }

    @Test("SessionManager invite flow produces working sessions (encrypt/decrypt roundtrip)")
    func sessionManagerInviteFlow_encryptDecryptRoundTrip() throws {
        let aliceKeys = generateKeypair()
        let bobKeys = generateKeypair()

        let aliceMgr = try SessionManagerHandle(
            ourPubkeyHex: aliceKeys.publicKeyHex,
            ourIdentityPrivkeyHex: aliceKeys.privateKeyHex,
            deviceId: "alice-device",
            ownerPubkeyHex: nil
        )
        let bobMgr = try SessionManagerHandle(
            ourPubkeyHex: bobKeys.publicKeyHex,
            ourIdentityPrivkeyHex: bobKeys.privateKeyHex,
            deviceId: "bob-device",
            ownerPubkeyHex: nil
        )

        try aliceMgr.`init`()
        try bobMgr.`init`()

        let aliceInitEvents = try aliceMgr.drainEvents()
        let bobInitEvents = try bobMgr.drainEvents()
        let aliceInvite = try #require(
            aliceInitEvents.first(where: { $0.kind == "publish_signed" })?.eventJson,
            "Alice should publish an invite on init"
        )
        let bobInvite = try #require(
            bobInitEvents.first(where: { $0.kind == "publish_signed" })?.eventJson,
            "Bob should publish an invite on init"
        )
        #expect(try extractNostrKind(json: aliceInvite) == 30078)
        #expect(try extractNostrKind(json: bobInvite) == 30078)

        // Bob accepts Alice's invite and emits a giftwrap response.
        try bobMgr.processEvent(eventJson: aliceInvite)
        let bobAfterInvite = try bobMgr.drainEvents()
        let bobResponse = try #require(
            bobAfterInvite.first(where: { $0.kind == "publish_signed" && ((try? extractNostrKind(json: $0.eventJson ?? "")) == 1059) })?.eventJson,
            "Bob should publish a response after processing Alice invite"
        )
        #expect(try extractNostrKind(json: bobResponse) == 1059)

        // Alice processes Bob's response; both sides are now able to exchange messages.
        try aliceMgr.processEvent(eventJson: bobResponse)
        _ = try aliceMgr.drainEvents()

        // Bob -> Alice
        _ = try bobMgr.sendText(recipientPubkeyHex: aliceKeys.publicKeyHex, text: "hello from bob", expiresAtSeconds: nil)
        let bobOutbound = try bobMgr.drainEvents().compactMap(\.eventJson)
        #expect(try bobOutbound.map { try extractNostrKind(json: $0) }.contains(1060))
        for eventJson in bobOutbound {
            try aliceMgr.processEvent(eventJson: eventJson)
        }
        let aliceInbound = try aliceMgr.drainEvents()
        let aliceDecryptedInner = try #require(
            aliceInbound.first(where: { $0.kind == "decrypted_message" })?.content,
            "Alice should receive decrypted message from Bob"
        )
        #expect(try innerEventContent(json: aliceDecryptedInner) == "hello from bob")

        // Alice -> Bob
        _ = try aliceMgr.sendText(recipientPubkeyHex: bobKeys.publicKeyHex, text: "hello from alice", expiresAtSeconds: nil)
        let aliceOutbound = try aliceMgr.drainEvents().compactMap(\.eventJson)
        #expect(try aliceOutbound.map { try extractNostrKind(json: $0) }.contains(1060))
        for eventJson in aliceOutbound {
            try bobMgr.processEvent(eventJson: eventJson)
        }
        let bobInbound = try bobMgr.drainEvents()
        let bobDecryptedInner = try #require(
            bobInbound.first(where: { $0.kind == "decrypted_message" })?.content,
            "Bob should receive decrypted message from Alice"
        )
        #expect(try innerEventContent(json: bobDecryptedInner) == "hello from alice")
    }

    @Test("SessionManager invite/response are Nostr events (for subscription filtering)")
    func sessionManagerInviteFlow_inviteAndResponse_areNostrEvents() throws {
        let aliceKeys = generateKeypair()
        let bobKeys = generateKeypair()

        let aliceMgr = try SessionManagerHandle(
            ourPubkeyHex: aliceKeys.publicKeyHex,
            ourIdentityPrivkeyHex: aliceKeys.privateKeyHex,
            deviceId: "test-device",
            ownerPubkeyHex: nil
        )
        let bobMgr = try SessionManagerHandle(
            ourPubkeyHex: bobKeys.publicKeyHex,
            ourIdentityPrivkeyHex: bobKeys.privateKeyHex,
            deviceId: "bob-device",
            ownerPubkeyHex: nil
        )
        try aliceMgr.`init`()
        try bobMgr.`init`()

        let inviteEventJson = try #require(
            try aliceMgr.drainEvents().first(where: { $0.kind == "publish_signed" })?.eventJson,
            "Alice should publish an invite on init"
        )
        // Clear Bob init-time invite so we can assert on the actual response generated by processing Alice's invite.
        _ = try bobMgr.drainEvents()
        let inviteKind = try extractNostrKind(json: inviteEventJson)
        let inviteTags = try extractNostrTags(json: inviteEventJson)
        let invitePubkey = try extractNostrPubkey(json: inviteEventJson)

        try bobMgr.processEvent(eventJson: inviteEventJson)
        let responseEventJson = try #require(
            try bobMgr.drainEvents().first(where: { $0.kind == "publish_signed" && ((try? extractNostrKind(json: $0.eventJson ?? "")) == 1059) })?.eventJson,
            "Bob should publish a giftwrap response after invite processing"
        )
        let responseKind = try extractNostrKind(json: responseEventJson)
        let responseTags = try extractNostrTags(json: responseEventJson)
        let responsePubkey = try extractNostrPubkey(json: responseEventJson)

        #expect(inviteKind == 30078)
        #expect(invitePubkey == aliceKeys.publicKeyHex)
        let ephemeralKey = try #require(tagValue(inviteTags, name: "ephemeralKey"))
        _ = try #require(tagValue(inviteTags, name: "sharedSecret"))
        #expect(tagValue(inviteTags, name: "l") == "double-ratchet/invites")
        #expect(tagValue(inviteTags, name: "d") == "double-ratchet/invites/test-device")

        // Response is a giftwrap (1059) addressed to the invite's ephemeral key.
        #expect(responseKind == 1059)
        #expect(responsePubkey.count == 64) // ephemeral gift-wrap signer key
        let responseP = try #require(
            responseTags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1],
            "Response giftwrap should include a p tag"
        )
        #expect(responseP == ephemeralKey)
    }

    @Test("SessionManagerHandle emits pubsub events on init (smoke test)")
    func sessionManagerHandle_init_emitsPubSubEvents() throws {
        let keys = generateKeypair()

        let mgr = try SessionManagerHandle(
            ourPubkeyHex: keys.publicKeyHex,
            ourIdentityPrivkeyHex: keys.privateKeyHex,
            deviceId: "test-device",
            ownerPubkeyHex: nil
        )
        try mgr.`init`()

        let events = try mgr.drainEvents()
        #expect(events.contains(where: { $0.kind == "publish_signed" }))
        #expect(events.contains(where: { $0.kind == "subscribe" }))

        let inviteEventJson = try #require(events.first(where: { $0.kind == "publish_signed" })?.eventJson)
        let inviteKind = try extractNostrKind(json: inviteEventJson)
        #expect(inviteKind == 30078)

        let inviteTags = try extractNostrTags(json: inviteEventJson)
        let ephemeralKey = try #require(inviteTags.first(where: { $0.count >= 2 && $0[0] == "ephemeralKey" })?[1])

        // Expect subscription for invite responses (giftwraps addressed to the ephemeralKey).
        let inviteResponseSub = try #require(events.first(where: { $0.kind == "subscribe" && ($0.subid?.hasPrefix("invite-response-") == true) }))
        let inviteResponseFilterJson = try #require(inviteResponseSub.filterJson)
        let decodedInviteResponseFilter = try JSONDecoder().decode(NostrFilter.self, from: Data(inviteResponseFilterJson.utf8))
        let reencodedInviteResponseFilter = try JSONEncoder().encode(decodedInviteResponseFilter)
        let reencodedObj = try JSONSerialization.jsonObject(with: reencodedInviteResponseFilter, options: []) as? [String: Any]
        let kinds = reencodedObj?["kinds"] as? [Int]
        let p = reencodedObj?["#p"] as? [String]
        #expect(kinds == [1059])
        #expect(p == [ephemeralKey])

        // Expect a subscription for app keys maintenance by owner.
        let appKeysSub = try #require(events.first(where: { $0.kind == "subscribe" && ($0.subid?.hasPrefix("app-keys-") == true) }))
        let appKeysFilterJson = try #require(appKeysSub.filterJson)
        let decodedAppKeysFilter = try JSONDecoder().decode(NostrFilter.self, from: Data(appKeysFilterJson.utf8))
        let reencodedAppKeysFilter = try JSONEncoder().encode(decodedAppKeysFilter)
        let reencodedAppKeysObj = try JSONSerialization.jsonObject(with: reencodedAppKeysFilter, options: []) as? [String: Any]
        let appKinds = reencodedAppKeysObj?["kinds"] as? [Int]
        let authors = reencodedAppKeysObj?["authors"] as? [String]
        #expect(appKinds == [30078])
        #expect(authors == [keys.publicKeyHex])
    }

    @Test("SessionManagerHandle can process invite/response and exchange a message (in-memory relay simulation)")
    func sessionManagerHandle_inviteResponse_messageRoundTrip() throws {
        let alice = generateKeypair()
        let bob = generateKeypair()

        let aliceMgr = try SessionManagerHandle(
            ourPubkeyHex: alice.publicKeyHex,
            ourIdentityPrivkeyHex: alice.privateKeyHex,
            deviceId: "alice-device",
            ownerPubkeyHex: nil
        )
        let bobMgr = try SessionManagerHandle(
            ourPubkeyHex: bob.publicKeyHex,
            ourIdentityPrivkeyHex: bob.privateKeyHex,
            deviceId: "bob-device",
            ownerPubkeyHex: nil
        )

        try aliceMgr.`init`()
        try bobMgr.`init`()

        let aliceInitEvents = try aliceMgr.drainEvents()
        let bobInitEvents = try bobMgr.drainEvents()

        let aliceInvite = try #require(aliceInitEvents.first(where: { $0.kind == "publish_signed" })?.eventJson, "Alice should publish an invite on init")
        let bobInvite = try #require(bobInitEvents.first(where: { $0.kind == "publish_signed" })?.eventJson, "Bob should publish an invite on init")
        #expect(try extractNostrKind(json: aliceInvite) == 30078)
        #expect(try extractNostrKind(json: bobInvite) == 30078)

        // Bob discovers Alice invite (e.g. via relay query) and processes it.
        try bobMgr.processEvent(eventJson: aliceInvite)
        let bobAfterInvite = try bobMgr.drainEvents()
        let bobResponse = try #require(bobAfterInvite.first(where: { $0.kind == "publish_signed" })?.eventJson, "Bob should publish a response after processing invite")
        #expect(try extractNostrKind(json: bobResponse) == 1059)

        // Alice receives Bob response and processes it.
        try aliceMgr.processEvent(eventJson: bobResponse)
        _ = try aliceMgr.drainEvents()

        // Bob sends a message to Alice.
        _ = try bobMgr.sendText(recipientPubkeyHex: alice.publicKeyHex, text: "bitchat1:hello", expiresAtSeconds: nil)
        let bobSendEvents = try bobMgr.drainEvents()
        let bobOutbound = bobSendEvents.compactMap(\.eventJson)
        #expect(!bobOutbound.isEmpty)
        let outboundKinds = try bobOutbound.map { try extractNostrKind(json: $0) }
        #expect(outboundKinds.contains(1060))

        // Deliver all outbound events to Alice.
        for eventJson in bobOutbound {
            try aliceMgr.processEvent(eventJson: eventJson)
        }

        let aliceInbound = try aliceMgr.drainEvents()

        // Expect the decrypted inner event (rumor) to surface from the session manager.
        let decrypted = aliceInbound.first(where: { $0.kind == "decrypted_message" })
        #expect(decrypted != nil)
        if let inner = decrypted?.content {
            #expect(try extractNostrPubkey(json: inner) == bob.publicKeyHex)
            #expect(try innerEventContent(json: inner) == "bitchat1:hello")
        }
    }

    private func innerEventContent(json: String) throws -> String {
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try #require(obj as? [String: Any], "Inner event should be a JSON object")
        return try #require(dict["content"] as? String, "Inner event should have string content")
    }

    private func extractNostrKind(json: String) throws -> Int {
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try #require(obj as? [String: Any], "Event should be a JSON object")
        return try #require(dict["kind"] as? Int, "Event should have integer kind")
    }

    private func extractNostrTags(json: String) throws -> [[String]] {
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try #require(obj as? [String: Any], "Event should be a JSON object")
        return try #require(dict["tags"] as? [[String]], "Event should have string tags")
    }

    private func extractNostrPubkey(json: String) throws -> String {
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try #require(obj as? [String: Any], "Event should be a JSON object")
        return try #require(dict["pubkey"] as? String, "Event should have string pubkey")
    }

    private func tagValue(_ tags: [[String]], name: String) -> String? {
        tags.first(where: { $0.count >= 2 && $0[0] == name })?[1]
    }
}

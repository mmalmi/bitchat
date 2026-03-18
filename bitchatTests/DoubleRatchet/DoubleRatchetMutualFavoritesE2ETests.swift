//
// DoubleRatchetMutualFavoritesE2ETests.swift
// bitchatTests
//
// End-to-end-ish integration test:
// - Two ChatViewModels (two "devices")
// - Mutual favorites established
// - ndr (nostr-double-ratchet) invite/response exchanged out-of-band over mocked BLE Noise channel
// - Kind 1060 message can be encrypted/decrypted end-to-end
//

import Foundation
import Testing
@testable import bitchat

@MainActor
struct DoubleRatchetMutualFavoritesE2ETests {

    @Test("Mutual favorites bootstrap ndr over BLE OOB and can exchange kind 1060 messages")
    func mutualFavorites_bootstrapOob_andDecrypts() async throws {
        // Safety: avoid touching user keychain if this isn't a test runner.
        let env = ProcessInfo.processInfo.environment
        let runningTests =
            NSClassFromString("XCTestCase") != nil ||
            env["XCTestConfigurationFilePath"] != nil ||
            env["XCTestBundlePath"] != nil
        guard runningTests else {
            Issue.record("Not running under a test runner; refusing to touch FavoritesPersistenceService persistence.")
            return
        }

        // Two distinct devices.
        let aliceKeychain = MockKeychain()
        let bobKeychain = MockKeychain()
        let aliceIdBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let bobIdBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let aliceIdentityManager = MockIdentityManager(aliceKeychain)
        let bobIdentityManager = MockIdentityManager(bobKeychain)

        let aliceTransport = MockTransport()
        aliceTransport.myPeerID = PeerID(str: "alice-e2e")
        aliceTransport.myNickname = "Alice"

        let bobTransport = MockTransport()
        bobTransport.myPeerID = PeerID(str: "bob-e2e")
        bobTransport.myNickname = "Bob"

        // ndr services are per-device and use in-memory relay managers.
        let aliceRelay = FakeRelayManager()
        let bobRelay = FakeRelayManager()
        let aliceStorage = try makeTempDir(label: "ndr-e2e-alice")
        let bobStorage = try makeTempDir(label: "ndr-e2e-bob")
        let aliceNdr = NdrNostrService(
            relayManager: aliceRelay,
            deviceId: "alice-device",
            storageDirectoryProvider: { aliceStorage }
        )
        let bobNdr = NdrNostrService(
            relayManager: bobRelay,
            deviceId: "bob-device",
            storageDirectoryProvider: { bobStorage }
        )

        // Link transports so `sendNdrEvent` delivers a Noise payload to the other side.
        aliceTransport.ndrEventDelivery = { [weak bobTransport, weak aliceTransport] peerID, eventJson in
            guard let bobTransport, let aliceTransport else { return }
            #expect(peerID == bobTransport.myPeerID)
            bobTransport.delegate?.didReceiveNoisePayload(
                from: aliceTransport.myPeerID,
                type: .ndrEvent,
                payload: Data(eventJson.utf8),
                timestamp: Date()
            )
        }
        bobTransport.ndrEventDelivery = { [weak aliceTransport, weak bobTransport] peerID, eventJson in
            guard let aliceTransport, let bobTransport else { return }
            #expect(peerID == aliceTransport.myPeerID)
            aliceTransport.delegate?.didReceiveNoisePayload(
                from: bobTransport.myPeerID,
                type: .ndrEvent,
                payload: Data(eventJson.utf8),
                timestamp: Date()
            )
        }

        // View models (per device) with injected ndr services.
        let aliceVM = ChatViewModel(
            keychain: aliceKeychain,
            idBridge: aliceIdBridge,
            identityManager: aliceIdentityManager,
            transport: aliceTransport,
            ndrService: aliceNdr
        )
        let bobVM = ChatViewModel(
            keychain: bobKeychain,
            idBridge: bobIdBridge,
            identityManager: bobIdentityManager,
            transport: bobTransport,
            ndrService: bobNdr
        )

        // Connected peer snapshots with stable Noise pubkeys.
        let aliceNoisePubkey = TestHelpers.generateRandomData(length: 32)
        let bobNoisePubkey = TestHelpers.generateRandomData(length: 32)
        let now = Date()
        aliceTransport.updatePeerSnapshots([
            TransportPeerSnapshot(
                peerID: bobTransport.myPeerID,
                nickname: "Bob",
                isConnected: true,
                noisePublicKey: bobNoisePubkey,
                lastSeen: now
            )
        ])
        bobTransport.updatePeerSnapshots([
            TransportPeerSnapshot(
                peerID: aliceTransport.myPeerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: aliceNoisePubkey,
                lastSeen: now
            )
        ])

        // Let the peer snapshot updates propagate through UnifiedPeerService -> ChatViewModel before
        // we post favorite notifications (bootstrap depends on finding the connected peer).
        let aliceSeesBob = await TestHelpers.waitUntil(
            { aliceVM.allPeers.contains(where: { $0.peerID == bobTransport.myPeerID && $0.isConnected }) },
            timeout: TestConstants.shortTimeout
        )
        let bobSeesAlice = await TestHelpers.waitUntil(
            { bobVM.allPeers.contains(where: { $0.peerID == aliceTransport.myPeerID && $0.isConnected }) },
            timeout: TestConstants.shortTimeout
        )
        #expect(aliceSeesBob)
        #expect(bobSeesAlice)

        // Establish mutual favorites (both sides) so OOB ndr exchange is allowed.
        let aliceIdentity = try #require(try aliceIdBridge.getCurrentNostrIdentity())
        let bobIdentity = try #require(try bobIdBridge.getCurrentNostrIdentity())

        // First: make Bob treat Alice as mutual favorite (so Bob will accept Alice's OOB invite).
        FavoritesPersistenceService.shared.addFavorite(
            peerNoisePublicKey: aliceNoisePubkey,
            peerNostrPublicKey: aliceIdentity.publicKeyHex,
            peerNickname: "Alice"
        )
        FavoritesPersistenceService.shared.updatePeerFavoritedUs(
            peerNoisePublicKey: aliceNoisePubkey,
            favorited: true,
            peerNickname: "Alice",
            peerNostrPublicKey: aliceIdentity.publicKeyHex
        )

        // Then: make Alice treat Bob as mutual favorite (this should trigger the bootstrap send).
        FavoritesPersistenceService.shared.addFavorite(
            peerNoisePublicKey: bobNoisePubkey,
            peerNostrPublicKey: bobIdentity.publicKeyHex,
            peerNickname: "Bob"
        )
        FavoritesPersistenceService.shared.updatePeerFavoritedUs(
            peerNoisePublicKey: bobNoisePubkey,
            favorited: true,
            peerNickname: "Bob",
            peerNostrPublicKey: bobIdentity.publicKeyHex
        )

        // Wait until both sides have active sessions.
        let aliceHasSession = await TestHelpers.waitUntil(
            { aliceNdr.hasActiveSession(with: bobIdentity.publicKeyHex) },
            timeout: TestConstants.defaultTimeout
        )
        let bobHasSession = await TestHelpers.waitUntil(
            { bobNdr.hasActiveSession(with: aliceIdentity.publicKeyHex) },
            timeout: TestConstants.defaultTimeout
        )
        #expect(aliceHasSession)
        #expect(bobHasSession)

        // Alice sends a DR message (kind 1060) via relays; Bob decrypts it.
        aliceRelay.resetSentEvents()
        #expect(aliceNdr.sendIfPossible("bitchat1:hello", to: bobIdentity.publicKeyHex))

        let outbound = aliceRelay.sentEvents.filter { $0.kind == 1060 }
        #expect(!outbound.isEmpty)

        var decryptedInner: NostrEvent?
        bobNdr.onDecryptedMessage = { inner in
            decryptedInner = inner
        }

        for event in outbound {
            bobNdr.processInboundRelayEvent(event)
        }

        let inner = try #require(decryptedInner)
        #expect(inner.pubkey.lowercased() == aliceIdentity.publicKeyHex.lowercased())
        #expect(inner.content == "bitchat1:hello")
    }

    private func makeTempDir(label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bitchat-tests-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }
}

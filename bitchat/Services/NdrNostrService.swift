import BitLogger
import Foundation
import NdrFfi

@MainActor
protocol NostrRelayManaging: AnyObject {
    func subscribe(
        filter: NostrFilter,
        id: String,
        relayUrls: [String]?,
        handler: @escaping (NostrEvent) -> Void,
        onEOSE: (() -> Void)?
    )
    func unsubscribe(id: String)
    func sendEvent(_ event: NostrEvent, to relayUrls: [String]?)
}

extension NostrRelayManager: NostrRelayManaging {}

/// Bridges `nostr-double-ratchet` (ndr-ffi) `SessionManagerHandle` with `NostrRelayManager`.
///
/// The ndr session manager emits a stream of pub/sub actions we must execute externally:
/// - `subscribe` / `unsubscribe`: Nostr filter subscriptions (for invite responses, sessions, etc)
/// - `publish_signed`: signed Nostr events to publish
/// - `decrypted_message`: decrypted inner event JSON (kind 14) to surface to the app
///
/// BitChat policy: do NOT publish double-ratchet invite/response handshake events to Nostr.
/// Those are exchanged out-of-band over the BLE Noise channel (see `Transport.sendNdrEvent`).
@MainActor
final class NdrNostrService {
    static let shared = NdrNostrService()

    /// Called when an ndr message is decrypted into an inner Nostr event (kind 14).
    var onDecryptedMessage: ((NostrEvent) -> Void)?

    private let relayManager: NostrRelayManaging
    private let storageDirectoryProvider: @MainActor () throws -> URL

    private var sessionManager: SessionManagerHandle?
    private var activeSubIDs = Set<String>()
    private var cachedInviteEventJson: String?

    private var configuredForPubkeyHex: String?
    private let deviceId: String

    private init() {
        self.relayManager = NostrRelayManager.shared
        self.deviceId = Self.loadOrCreateDeviceId()
        self.storageDirectoryProvider = Self.ndrStorageDirectory
    }

    /// Dependency-injected initializer (primarily for tests).
    init(
        relayManager: NostrRelayManaging,
        deviceId: String,
        storageDirectoryProvider: @escaping @MainActor () throws -> URL
    ) {
        self.relayManager = relayManager
        self.deviceId = deviceId
        self.storageDirectoryProvider = storageDirectoryProvider
    }

    var isConfigured: Bool { sessionManager != nil }
    var configuredPubkeyHex: String? { configuredForPubkeyHex }

    // MARK: - Debug Helpers

    var ndrFfiVersion: String { version() }
    var debugDeviceId: String { deviceId }
    var debugOurPubkeyHex: String? { sessionManager?.getOurPubkeyHex() }
    var debugTotalSessions: UInt64? { sessionManager?.getTotalSessions() }

    /// Returns our current device invite event JSON (kind 30078), if available.
    ///
    /// This is exchanged out-of-band with mutual favorites over BLE and is never published to Nostr.
    func currentInviteEventJson() -> String? {
        cachedInviteEventJson
    }

    func configureIfNeeded(identity: NostrIdentity) {
        let pubkey = identity.publicKeyHex.lowercased()
        if configuredForPubkeyHex == pubkey, sessionManager != nil { return }

        // Identity changed: tear down subscriptions we created (best-effort).
        for id in activeSubIDs {
            relayManager.unsubscribe(id: id)
        }
        activeSubIDs.removeAll()
        sessionManager = nil
        cachedInviteEventJson = nil
        configuredForPubkeyHex = pubkey

        do {
            let storagePath = try storageDirectoryProvider().path
            let mgr = try SessionManagerHandle.newWithStoragePath(
                ourPubkeyHex: pubkey,
                ourIdentityPrivkeyHex: identity.privateKey.hexEncodedString(),
                deviceId: deviceId,
                storagePath: storagePath,
                ownerPubkeyHex: nil
            )
            try mgr.`init`()
            sessionManager = mgr
            _ = drainAndApplyPubSubEvents()
            SecureLogger.info("NdrNostrService configured pub=\(pubkey.prefix(8))… device=\(deviceId)", category: .session)
        } catch {
            SecureLogger.error("NdrNostrService: failed to configure: \(error)", category: .session)
            sessionManager = nil
        }
    }

    func hasActiveSession(with peerPubkeyHex: String) -> Bool {
        guard let mgr = sessionManager else { return false }
        do {
            return try mgr.getActiveSessionState(peerPubkeyHex: peerPubkeyHex.lowercased()) != nil
        } catch {
            return false
        }
    }

    func activeSessionStateJson(with peerPubkeyHex: String) -> String? {
        guard let mgr = sessionManager else { return nil }
        return try? mgr.getActiveSessionState(peerPubkeyHex: peerPubkeyHex.lowercased())
    }

    /// Attempt to send via ndr. Returns true if sent (i.e. a session existed and an outbound publish was queued).
    func sendIfPossible(_ text: String, to peerPubkeyHex: String) -> Bool {
        guard let mgr = sessionManager else { return false }
        do {
            _ = try mgr.sendText(recipientPubkeyHex: peerPubkeyHex.lowercased(), text: text, expiresAtSeconds: nil)
            _ = drainAndApplyPubSubEvents()
            return true
        } catch {
            SecureLogger.debug("NdrNostrService: send failed (no session yet?): \(error)", category: .session)
            // Still drain in case the error queued any pubsub actions.
            _ = drainAndApplyPubSubEvents()
            return false
        }
    }

    /// Process a received invite/response event JSON (transferred out-of-band over BLE).
    ///
    /// Returns any outbound handshake events (e.g. giftwrap response) that should be returned to the sender over BLE.
    func processOutOfBandEventJson(_ eventJson: String) -> [String] {
        guard let mgr = sessionManager else { return [] }
        do {
            if isDoubleRatchetInviteEventJson(eventJson) {
                _ = try mgr.acceptInviteFromEventJson(eventJson: eventJson, ownerPubkeyHintHex: nil)
            } else {
                try mgr.processEvent(eventJson: eventJson)
            }
        } catch {
            SecureLogger.debug("NdrNostrService: processOutOfBandEventJson ignored/rejected: \(error)", category: .session)
        }
        return drainAndApplyPubSubEvents(collectOutOfBandPublishes: true)
    }

    /// Process a Nostr event received from relays (kind 1060 messages, app-keys maintenance, etc).
    func processInboundRelayEvent(_ event: NostrEvent) {
        processInboundNostrEvent(event)
    }

    // MARK: - Internals

    private func processInboundNostrEvent(_ event: NostrEvent) {
        guard let mgr = sessionManager else { return }
        guard let json = try? event.jsonString() else { return }

        do {
            try mgr.processEvent(eventJson: json)
        } catch {
            // ndr will reject most unrelated events; keep log noise low.
            SecureLogger.debug("NdrNostrService: processEvent ignored/rejected: \(error)", category: .session)
        }

        _ = drainAndApplyPubSubEvents()
    }

    @discardableResult
    private func drainAndApplyPubSubEvents(collectOutOfBandPublishes: Bool = false) -> [String] {
        guard let mgr = sessionManager else { return [] }
        var outOfBandPublishes: [String] = []
        do {
            let events = try mgr.drainEvents()
            for e in events {
                apply(
                    pubsub: e,
                    collectOutOfBandPublish: collectOutOfBandPublishes ? { outOfBandPublishes.append($0) } : nil
                )
            }
        } catch {
            SecureLogger.error("NdrNostrService: drainEvents failed: \(error)", category: .session)
        }
        return outOfBandPublishes
    }

    private func apply(pubsub e: PubSubEvent, collectOutOfBandPublish: ((String) -> Void)?) {
        switch e.kind {
        case "subscribe":
            guard let subid = e.subid, let filterJson = e.filterJson else { return }

            do {
                let filter = try JSONDecoder().decode(NostrFilter.self, from: Data(filterJson.utf8))
                // BitChat policy: don't do Nostr-based DR invite discovery or invite-response listening.
                if shouldIgnoreNdrSubscription(filter) {
                    return
                }
                guard activeSubIDs.insert(subid).inserted else { return } // already subscribed
                relayManager.subscribe(
                    filter: filter,
                    id: subid,
                    relayUrls: nil,
                    handler: { [weak self] event in
                        self?.processInboundNostrEvent(event)
                    },
                    onEOSE: nil
                )
            } catch {
                SecureLogger.error("NdrNostrService: failed to decode subscribe filter: \(error)", category: .session)
            }

        case "unsubscribe":
            guard let subid = e.subid else { return }
            relayManager.unsubscribe(id: subid)
            activeSubIDs.remove(subid)

        case "publish_signed":
            guard let eventJson = e.eventJson else { return }
            do {
                let event = try JSONDecoder().decode(NostrEvent.self, from: Data(eventJson.utf8))

                if isDoubleRatchetInviteEvent(event) {
                    // Cache the current device invite for out-of-band sharing; never publish to Nostr.
                    cachedInviteEventJson = eventJson
                    collectOutOfBandPublish?(eventJson)
                    return
                }
                if event.kind == 1059 {
                    // Giftwrap responses are part of the DR handshake; exchange OOB over BLE.
                    collectOutOfBandPublish?(eventJson)
                    return
                }

                relayManager.sendEvent(event, to: nil)
            } catch {
                SecureLogger.error("NdrNostrService: failed to decode outbound event: \(error)", category: .session)
            }

        case "decrypted_message":
            guard let innerJson = e.content else { return }
            do {
                let inner = try JSONDecoder().decode(NostrEvent.self, from: Data(innerJson.utf8))
                onDecryptedMessage?(inner)
            } catch {
                SecureLogger.error("NdrNostrService: failed to decode decrypted inner event: \(error)", category: .session)
            }

        default:
            // Other events currently ignored (e.g. app-keys maintenance).
            break
        }
    }

    private func isDoubleRatchetInviteEvent(_ event: NostrEvent) -> Bool {
        guard event.kind == 30078 else { return false }
        for tag in event.tags where tag.count >= 2 {
            if tag[0] == "l", tag[1] == "double-ratchet/invites" {
                return true
            }
            if tag[0] == "d", tag[1].hasPrefix("double-ratchet/invites/") {
                return true
            }
        }
        return false
    }

    private func isDoubleRatchetInviteEventJson(_ eventJson: String) -> Bool {
        guard let event = try? JSONDecoder().decode(NostrEvent.self, from: Data(eventJson.utf8)) else {
            return false
        }
        return isDoubleRatchetInviteEvent(event)
    }

    private func shouldIgnoreNdrSubscription(_ filter: NostrFilter) -> Bool {
        // Never use Nostr for invite/response exchange in BitChat.
        if filter.kinds?.contains(1059) == true {
            return true
        }
        if filter.kinds?.contains(30078) == true,
           filter.tagFilters?["l"]?.contains("double-ratchet/invites") == true {
            return true
        }
        return false
    }

    private static func loadOrCreateDeviceId() -> String {
        let defaults = UserDefaults.standard
        let key = "ndr.device_id"
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }

    private static func ndrStorageDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = documents.appendingPathComponent("ndr", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }
}

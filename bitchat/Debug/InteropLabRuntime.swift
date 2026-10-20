#if DEBUG && BITCHAT_INTEROP_LAB
#if os(iOS)
import UIKit
#endif
import BitFoundation
import Combine
import Foundation
import SwiftUI

@main
struct InteropLabApp: App {
    @StateObject private var lab = InteropLabRuntime()
    var body: some Scene {
        WindowGroup("BitChat interop lab") {
            VStack(alignment: .leading, spacing: 12) {
                Text("BitChat interop lab").font(.title)
                Text(lab.ready ? "Ready for controlled Bluetooth tests" : "Starting test services")
                Text("Synthetic accounts · local relay · location disabled")
            }.padding(24).frame(minWidth: 420)
        }
    }
}

@MainActor
final class InteropLabRuntime: ObservableObject {
    static weak var active: InteropLabRuntime?
    static var receivingSource = "ble"
    @Published private(set) var ready = false
    let nickname = "ndr-lab-apple"
    let mesh: BLEService
    let viewModel: ChatViewModel
    let bridge: NostrIdentityBridge
    let favorites: FavoritesPersistenceService
    let ndr: NdrNostrService
    private var control: InteropLabControl?
    private var approved: [String: String] = [:] // Synthetic Noise key -> approved nickname.
    private var peerKeys: [String: Data] = [:]
    private var received: [[String: String]] = []
    private var sent: [[String: String]] = []
    private var backgroundCount = 0
    var receivedBootstrapCount = 0
    private let root: URL

    init() {
        root = InteropLabStorage.root
        let keychain = InteropLabStorage.keychain
        let labBridge = NostrIdentityBridge(keychain: keychain)
        let labFavorites = FavoritesPersistenceService.shared
        let labNdr = NdrNostrService.shared
        let identity = SecureIdentityStateManager(keychain)
        let labMesh = BLEService(keychain: keychain, idBridge: labBridge, identityManager: identity,
                                 initializeBluetoothManagers: true, doubleRatchetEnabled: DoubleRatchetFeature.isEnabled)
        let labViewModel = ChatViewModel(keychain: keychain, idBridge: labBridge, identityManager: identity,
                                         transport: labMesh, ndrService: labNdr, favoritesService: labFavorites)
        bridge = labBridge
        favorites = labFavorites
        ndr = labNdr
        mesh = labMesh
        viewModel = labViewModel
        Self.active = self
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.backgroundCount += 1 }
        }
        #endif
        if let data = try? Data(contentsOf: root.appendingPathComponent("approved.json")) {
            approved = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("received.json")) {
            received = (try? JSONDecoder().decode([[String: String]].self, from: data)) ?? []
        }
        viewModel.nickname = nickname
        mesh.setNickname(nickname)
        viewModel.setupNostrMessageHandling()
        mesh.startServices()
        NostrRelayManager.shared.connect()
        do {
            control = try InteropLabControl { [weak self] command in
                guard let self else { return ["error": "lab_stopped"] }
                return self.execute(command)
            }
            ready = true
        } catch {
            mesh.stopServices()
        }
    }

    private func noiseKey(_ peer: PeerID) -> Data? {
        mesh.authenticatedPeerTransportState(peer)?.noisePublicKey
            ?? mesh.currentPeerSnapshots().first(where: { $0.peerID == peer })?.noisePublicKey
            ?? peer.noiseKey
            ?? peerKeys[peer.id]
    }

    func isAllowed(_ peer: PeerID) -> Bool {
        guard let key = noiseKey(peer)?.hexEncodedString(), let name = approved[key] else { return false }
        let currentName = mesh.currentPeerSnapshots().first(where: { $0.peerID == peer })?.nickname
        return currentName == nil || currentName == name
    }

    static func recordReceived(_ message: BitchatMessage, peerID: PeerID) {
        guard let lab = active, message.isPrivate, message.content.hasPrefix("ndr-lab:"),
              message.id.hasPrefix("ndr-lab-"), lab.isAllowed(peerID) else { return }
        lab.received.append(["id": message.id, "content": message.content,
                             "peer_id": peerID.id, "transport": receivingSource])
        do {
            try JSONEncoder().encode(lab.received).write(to: lab.root.appendingPathComponent("received.json"), options: .atomic)
        } catch { lab.ready = false }
    }

    private func status() -> [String: Any] {
        let snapshots = mesh.currentPeerSnapshots()
        let peers: [[String: Any]] = snapshots.filter { $0.nickname.hasPrefix("ndr-lab-") }.map { snapshot in
            let state = mesh.authenticatedPeerTransportState(snapshot.peerID)
            let key = state?.noisePublicKey ?? snapshot.noisePublicKey
            let relationship = key.flatMap { favorites.getFavoriteStatus(for: $0) }
            let nostr = relationship.flatMap { $0.peerNostrPublicKey }.flatMap { ChatViewModel.ndrNostrPubkeyHex(from: $0) }
            return ["peer_id": snapshot.peerID.id, "nickname": snapshot.nickname,
                    "noise_pubkey": key?.hexEncodedString() ?? "", "allowed": isAllowed(snapshot.peerID),
                    "connected": snapshot.isConnected, "authenticated": state != nil,
                    "ndr_capable": state?.capabilities.contains(.doubleRatchet) == true,
                    "mutual_favorite": relationship?.isMutual == true,
                    "ndr_ready": nostr.map { ndr.hasActiveSession(with: $0) } ?? false,
                    "pinned": nostr.map { !favorites.canAcceptLegacyNostrDM(from: $0) } ?? false]
        }
        let contacts: [[String: Any]] = approved.map { key, name in
            let relationship = Data(hexString: key).flatMap { favorites.getFavoriteStatus(for: $0) }
            let nostr = relationship.flatMap { $0.peerNostrPublicKey }.flatMap { ChatViewModel.ndrNostrPubkeyHex(from: $0) }
            return ["peer_id": key, "nickname": name, "noise_pubkey": key,
                    "nostr_pubkey": nostr ?? "", "mutual_favorite": relationship?.isMutual == true,
                    "ndr_ready": nostr.map { ndr.hasActiveSession(with: $0) } ?? false,
                    "pinned": nostr.map { !favorites.canAcceptLegacyNostrDM(from: $0) } ?? false]
        }
        return ["ready": ready, "nickname": nickname, "peer_id": mesh.myPeerID.id,
                "noise_pubkey": mesh.noiseStaticPublicKeyData().hexEncodedString(),
                "nostr_pubkey": (try? bridge.getCurrentNostrIdentity()?.publicKeyHex) ?? "",
                "bluetooth_state": mesh.getCurrentBluetoothState().rawValue,
                "radio": mesh.interopLabRadioStatus(),
                "rollout_enabled": ndr.isRolloutEnabled,
                "background_count": backgroundCount,
                "relay_connected": NostrRelayManager.shared.isDMRelayConnected,
                "unknown_peer_count": snapshots.filter { !isAllowed($0.peerID) }.count,
                "received_bootstrap_count": receivedBootstrapCount,
                "peers": peers, "known_contacts": contacts,
                "received": received, "sent": sent]
    }

    private func execute(_ command: [String: Any]) -> [String: Any] {
        let op = command["op"] as? String ?? "status"
        if op == "status" { return status() }
        if op == "ble_stop" { mesh.interopLabSetRadioEnabled(false); return ["ok": true] }
        if op == "ble_start" { mesh.interopLabSetRadioEnabled(true); return ["ok": true] }
        guard let rawPeer = command["peer_id"] as? String else { return ["error": "missing_peer"] }
        let peer = PeerID(str: rawPeer)
        if op == "allow_peer" {
            guard let key = command["noise_pubkey"] as? String,
                  let name = command["nickname"] as? String, name.hasPrefix("ndr-lab-"),
                  key.count == 64, key.allSatisfy(\.isHexDigit),
                  noiseKey(peer)?.hexEncodedString() == key.lowercased(),
                  mesh.currentPeerSnapshots().contains(where: { $0.peerID == peer && $0.nickname == name })
            else { return ["error": "identity_mismatch"] }
            var next = approved; next[key.lowercased()] = name
            do { try JSONEncoder().encode(next).write(to: root.appendingPathComponent("approved.json"), options: .atomic) }
            catch { return ["error": "approval_write_failed"] }
            approved = next
            peerKeys[peer.id] = noiseKey(peer)
            return ["ok": true]
        }
        guard isAllowed(peer) else { return ["error": "peer_not_approved"] }
        guard !mesh.currentPeerSnapshots().contains(where: { !isAllowed($0.peerID) }) else {
            return ["error": "unknown_peer_present"]
        }
        if op == "favorite" {
            guard let state = mesh.authenticatedPeerTransportState(peer) else { return ["error": "not_authenticated"] }
            let name = approved[state.noisePublicKey.hexEncodedString()]!
            favorites.addFavorite(peerNoisePublicKey: state.noisePublicKey, peerNickname: name)
            mesh.sendFavoriteNotification(to: peer, isFavorite: true)
            viewModel.setupNostrMessageHandling()
            viewModel.bootstrapDoubleRatchetIfNeeded(for: peer)
            return ["ok": true]
        }
        guard let messageID = command["id"] as? String, messageID.hasPrefix("ndr-lab-"),
              let content = command["content"] as? String, content.hasPrefix("ndr-lab:"),
              messageID.utf8.count < 160, content.utf8.count <= 255 else { return ["error": "invalid_fixture"] }
        let name = noiseKey(peer).flatMap { approved[$0.hexEncodedString()] } ?? "ndr-lab-peer"
        switch op {
        case "ble_send":
            mesh.sendPrivateMessage(content, to: peer, recipientNickname: name, messageID: messageID)
            sent.append(["id": messageID, "transport": "ble_requested", "result": "submitted"])
            return ["ok": true]
        case "ndr_send":
            let transport = NostrTransport(keychain: InteropLabStorage.keychain, idBridge: bridge, ndrService: ndr)
            transport.senderPeerID = mesh.myPeerID
            do {
                let used = try transport.sendPrivateMessageAndReturnTransport(content, to: peer,
                                                                               recipientNickname: name, messageID: messageID)
                sent.append(["id": messageID, "transport": used.rawValue, "result": "submitted"])
                return ["ok": true, "transport": used.rawValue]
            } catch {
                sent.append(["id": messageID, "transport": "none", "result": "rejected"])
                return ["ok": false, "error": "send_rejected"]
            }
        default: return ["error": "unknown_operation"]
        }
    }
}
#endif

#if os(macOS)
import CoreBluetooth
import Foundation

@MainActor
final class AppAutomationService {
    static let shared = AppAutomationService()

    private enum Constants {
        static let pollIntervalSeconds: TimeInterval = 0.5
    }

    private struct AutomationRequest: Codable {
        let id: String
        let command: String
        let target: String?
        let value: Bool?
        let text: String?
        let nickname: String?
        let nostrPublicKey: String?
    }

    private struct AutomationResponse: Codable {
        let id: String
        let ok: Bool
        let message: String?
        let details: [String: String]?
        let error: String?
        let snapshot: ChatViewModel.AutomationSnapshot?
    }

    private struct AutomationCommandResult {
        let message: String?
        let details: [String: String]?
    }

    private enum AutomationError: LocalizedError {
        case missingViewModel
        case missingDirectory
        case invalidRequest(String)
        case unsupportedCommand(String)
        case targetNotFound(String)

        var errorDescription: String? {
            switch self {
            case .missingViewModel:
                return "Automation service is not attached to a ChatViewModel."
            case .missingDirectory:
                return "BITCHAT_AUTOMATION_DIR is not configured."
            case .invalidRequest(let message):
                return message
            case .unsupportedCommand(let command):
                return "Unsupported automation command: \(command)"
            case .targetNotFound(let target):
                return "Could not resolve automation target: \(target)"
            }
        }
    }

    private weak var chatViewModel: ChatViewModel?
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var rootURL: URL?
    private var requestsURL: URL?
    private var responsesURL: URL?
    private var stateURL: URL?
    private var pollTimer: Timer?

    private init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func startIfEnabled(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel

        guard let directory = configuredAutomationDirectoryPath(),
              !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let expandedPath = (directory as NSString).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        let requestsURL = rootURL.appendingPathComponent("requests", isDirectory: true)
        let responsesURL = rootURL.appendingPathComponent("responses", isDirectory: true)
        let stateURL = rootURL.appendingPathComponent("state.json", isDirectory: false)

        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: requestsURL, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: responsesURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return
        }

        self.rootURL = rootURL
        self.requestsURL = requestsURL
        self.responsesURL = responsesURL
        self.stateURL = stateURL

        if pollTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: Constants.pollIntervalSeconds, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }

        tick()
    }

    private func configuredAutomationDirectoryPath() -> String? {
        if let envDirectory = ProcessInfo.processInfo.environment["BITCHAT_AUTOMATION_DIR"],
           !envDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envDirectory
        }

        let arguments = CommandLine.arguments
        guard let argumentIndex = arguments.firstIndex(of: "--automation-dir") else {
            return nil
        }

        let valueIndex = arguments.index(after: argumentIndex)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        let argumentDirectory = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return argumentDirectory.isEmpty ? nil : argumentDirectory
    }

    private func tick() {
        guard chatViewModel != nil else {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }

        processRequests()
        writeCurrentState()
    }

    private func processRequests() {
        guard let requestsURL else { return }

        let requestFiles: [URL]
        do {
            requestFiles = try fileManager.contentsOfDirectory(
                at: requestsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return
        }

        for requestFile in requestFiles {
            processRequest(at: requestFile)
        }
    }

    private func processRequest(at requestURL: URL) {
        let fallbackID = requestURL.deletingPathExtension().lastPathComponent

        let response: AutomationResponse
        do {
            let data = try Data(contentsOf: requestURL)
            let request = try decoder.decode(AutomationRequest.self, from: data)
            let result = try handle(request)
            response = AutomationResponse(
                id: request.id,
                ok: true,
                message: result.message,
                details: result.details,
                error: nil,
                snapshot: chatViewModel?.automationSnapshot()
            )
        } catch {
            response = AutomationResponse(
                id: fallbackID,
                ok: false,
                message: nil,
                details: nil,
                error: error.localizedDescription,
                snapshot: chatViewModel?.automationSnapshot()
            )
        }

        writeResponse(response)
        try? fileManager.removeItem(at: requestURL)
    }

    private func handle(_ request: AutomationRequest) throws -> AutomationCommandResult {
        guard let chatViewModel else {
            throw AutomationError.missingViewModel
        }

        switch request.command {
        case "ping":
            return AutomationCommandResult(message: "pong", details: nil)
        case "snapshot":
            return AutomationCommandResult(message: "snapshot written", details: nil)
        case "setNickname":
            guard let nickname = request.nickname?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !nickname.isEmpty else {
                throw AutomationError.invalidRequest("setNickname requires a non-empty nickname")
            }
            chatViewModel.nickname = nickname
            chatViewModel.validateAndSaveNickname()
            return AutomationCommandResult(message: "nickname set to \(chatViewModel.nickname)", details: nil)
        case "setFavorite":
            guard let target = request.target,
                  let value = request.value else {
                throw AutomationError.invalidRequest("setFavorite requires target and value")
            }
            let resolvedTarget = try resolveTarget(target)
            let wasFavorite = chatViewModel.isFavorite(peerID: resolvedTarget)
            if wasFavorite != value {
                chatViewModel.toggleFavorite(peerID: resolvedTarget)
            }
            return AutomationCommandResult(message: "favorite=\(value) for \(resolvedTarget.id)", details: nil)
        case "setFavoritedUs":
            guard let target = request.target,
                  let value = request.value else {
                throw AutomationError.invalidRequest("setFavoritedUs requires target and value")
            }
            let resolvedTarget = try resolveTarget(target)
            guard let peer = chatViewModel.automationPeer(matching: resolvedTarget) else {
                throw AutomationError.targetNotFound(target)
            }
            FavoritesPersistenceService.shared.updatePeerFavoritedUs(
                peerNoisePublicKey: peer.noisePublicKey,
                favorited: value,
                peerNickname: peer.nickname,
                peerNostrPublicKey: request.nostrPublicKey ?? peer.nostrPublicKey
            )
            return AutomationCommandResult(message: "theyFavoritedUs=\(value) for \(resolvedTarget.id)", details: nil)
        case "sendPrivateMessage":
            guard let target = request.target,
                  let text = request.text,
                  !text.isEmpty else {
                throw AutomationError.invalidRequest("sendPrivateMessage requires target and non-empty text")
            }
            let resolvedTarget = try resolveTarget(target)
            chatViewModel.sendPrivateMessage(text, to: resolvedTarget)
            return AutomationCommandResult(message: "sent private message to \(resolvedTarget.id)", details: nil)
        case "sendPrivateMessageViaNostr":
            guard let target = request.target,
                  let text = request.text,
                  !text.isEmpty else {
                throw AutomationError.invalidRequest("sendPrivateMessageViaNostr requires target and non-empty text")
            }
            let resolvedTarget = try resolveTarget(target)
            guard let peer = chatViewModel.automationPeer(matching: resolvedTarget) else {
                throw AutomationError.targetNotFound(target)
            }
            let transport = NostrTransport(
                keychain: chatViewModel.keychain,
                idBridge: chatViewModel.idBridge,
                ndrService: chatViewModel.ndrService
            )
            transport.senderPeerID = chatViewModel.meshService.myPeerID
            let transportUsed = try transport.sendPrivateMessageAndReturnTransport(
                text,
                to: resolvedTarget,
                recipientNickname: peer.nickname,
                messageID: UUID().uuidString
            )
            return AutomationCommandResult(
                message: "sent Nostr private message to \(resolvedTarget.id)",
                details: ["transportUsed": transportUsed.rawValue]
            )
        default:
            throw AutomationError.unsupportedCommand(request.command)
        }
    }

    private func resolveTarget(_ rawTarget: String) throws -> PeerID {
        guard let chatViewModel else {
            throw AutomationError.missingViewModel
        }
        guard let peerID = chatViewModel.resolveAutomationTarget(rawTarget) else {
            throw AutomationError.targetNotFound(rawTarget)
        }
        return peerID
    }

    private func writeCurrentState() {
        guard let chatViewModel,
              let stateURL else { return }
        writeJSON(chatViewModel.automationSnapshot(), to: stateURL)
    }

    private func writeResponse(_ response: AutomationResponse) {
        guard let responsesURL else { return }
        let responseURL = responsesURL.appendingPathComponent("\(response.id).json", isDirectory: false)
        writeJSON(response, to: responseURL)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }
}

extension ChatViewModel {
    struct AutomationSnapshot: Codable {
        let updatedAt: Date
        let hostName: String
        let bundleIdentifier: String
        let nickname: String
        let myPeerID: String
        let myNoisePublicKeyHex: String
        let myNostrPublicKey: String?
        let bluetoothState: String
        let activeChannel: String
        let selectedPrivateChatPeerID: String?
        let peers: [AutomationPeerSnapshot]
        let privateChats: [AutomationConversationSnapshot]
    }

    struct AutomationPeerSnapshot: Codable {
        let peerID: String
        let noisePublicKeyHex: String
        let nickname: String
        let displayName: String
        let isConnected: Bool
        let isReachable: Bool
        let isFavorite: Bool
        let theyFavoritedUs: Bool
        let isMutualFavorite: Bool
        let nostrPublicKey: String?
        let encryptionStatus: String
        let encryptionIcon: String?
        let doubleRatchetEnabled: Bool
        let doubleRatchetStatus: String
        let doubleRatchetStatusDetail: String?
        let doubleRatchetPeerPubkeyHex: String?
        let doubleRatchetSessionStateJson: String?
    }

    struct AutomationConversationSnapshot: Codable {
        let conversationKey: String
        let counterpartPeerID: String?
        let counterpartNoisePublicKeyHex: String?
        let displayName: String
        let unread: Bool
        let messageCount: Int
        let messages: [AutomationMessageSnapshot]
    }

    struct AutomationMessageSnapshot: Codable {
        let id: String
        let sender: String
        let content: String
        let timestamp: Date
        let senderPeerID: String?
        let deliveryStatus: String?
    }

    func resolveAutomationTarget(_ rawTarget: String) -> PeerID? {
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let peer = allPeers.first(where: {
            $0.peerID.id.caseInsensitiveCompare(trimmed) == .orderedSame ||
            $0.noisePublicKey.hexEncodedString().caseInsensitiveCompare(trimmed) == .orderedSame ||
            $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame ||
            $0.nickname.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return PeerID(hexData: peer.noisePublicKey)
        }

        let candidate = PeerID(str: trimmed)
        if let noiseKey = candidate.noiseKey {
            if FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey) != nil {
                return candidate
            }
            if allPeers.contains(where: { $0.noisePublicKey == noiseKey }) {
                return candidate
            }
            if privateChats[candidate] != nil {
                return candidate
            }
            return nil
        }

        if candidate.isShort {
            if allPeers.contains(where: { $0.peerID == candidate }) {
                return candidate
            }
            return nil
        }

        return nil
    }

    func automationPeer(matching target: PeerID) -> BitchatPeer? {
        if let noiseKey = target.noiseKey {
            return allPeers.first(where: { $0.noisePublicKey == noiseKey || $0.peerID == target })
        }
        return allPeers.first(where: { $0.peerID == target })
    }

    func automationSnapshot() -> AutomationSnapshot {
        let noiseHex = meshService.getNoiseService().getStaticPublicKeyData().hexEncodedString()
        let nostrPublicKey = try? idBridge.getCurrentNostrIdentity()?.npub
        let peers = allPeers
            .sorted { lhs, rhs in
                if lhs.displayName != rhs.displayName {
                    return lhs.displayName < rhs.displayName
                }
                return lhs.peerID < rhs.peerID
            }
            .map { peer in
                let encryptionStatus = getEncryptionStatus(for: peer.peerID)
                let doubleRatchet = doubleRatchetDebugInfo(for: peer.peerID)
                return AutomationPeerSnapshot(
                    peerID: peer.peerID.id,
                    noisePublicKeyHex: peer.noisePublicKey.hexEncodedString(),
                    nickname: peer.nickname,
                    displayName: peer.displayName,
                    isConnected: peer.isConnected,
                    isReachable: peer.isReachable,
                    isFavorite: peer.isFavorite,
                    theyFavoritedUs: peer.theyFavoritedUs,
                    isMutualFavorite: peer.isMutualFavorite,
                    nostrPublicKey: peer.nostrPublicKey,
                    encryptionStatus: encryptionStatus.description,
                    encryptionIcon: encryptionStatus.icon,
                    doubleRatchetEnabled: doubleRatchet.enabled,
                    doubleRatchetStatus: doubleRatchet.status.rawValue,
                    doubleRatchetStatusDetail: doubleRatchet.statusDetail,
                    doubleRatchetPeerPubkeyHex: doubleRatchet.peerPubkeyHex,
                    doubleRatchetSessionStateJson: doubleRatchet.sessionStateJson
                )
            }

        let privateChats = privateChats
            .map { key, messages in
                let counterpartPeer = unifiedPeerService.getPeer(by: key)
                let counterpartNoiseKey = key.noiseKey?.hexEncodedString() ?? counterpartPeer?.noisePublicKey.hexEncodedString()
                let fallbackFavoriteName: String? = {
                    guard let counterpartNoiseKey,
                          let noiseKey = Data(hexString: counterpartNoiseKey) else {
                        return nil
                    }
                    return FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey)?.peerNickname
                }()
                let displayName = counterpartPeer?.displayName ??
                    fallbackFavoriteName ??
                    messages.last(where: { $0.senderPeerID != meshService.myPeerID })?.sender ??
                    key.id

                return AutomationConversationSnapshot(
                    conversationKey: key.id,
                    counterpartPeerID: counterpartPeer?.peerID.id,
                    counterpartNoisePublicKeyHex: counterpartNoiseKey,
                    displayName: displayName,
                    unread: unreadPrivateMessages.contains(key),
                    messageCount: messages.count,
                    messages: Array(messages.suffix(20)).map { message in
                        AutomationMessageSnapshot(
                            id: message.id,
                            sender: message.sender,
                            content: message.content,
                            timestamp: message.timestamp,
                            senderPeerID: message.senderPeerID?.id,
                            deliveryStatus: message.deliveryStatus?.displayText
                        )
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.displayName != rhs.displayName {
                    return lhs.displayName < rhs.displayName
                }
                return lhs.conversationKey < rhs.conversationKey
            }

        return AutomationSnapshot(
            updatedAt: Date(),
            hostName: ProcessInfo.processInfo.hostName,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "chat.bitchat",
            nickname: nickname,
            myPeerID: meshService.myPeerID.id,
            myNoisePublicKeyHex: noiseHex,
            myNostrPublicKey: nostrPublicKey,
            bluetoothState: automationBluetoothStateName(bluetoothState),
            activeChannel: automationChannelName(activeChannel),
            selectedPrivateChatPeerID: selectedPrivateChatPeer?.id,
            peers: peers,
            privateChats: privateChats
        )
    }

    private func automationBluetoothStateName(_ state: CBManagerState) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .resetting:
            return "resetting"
        case .unsupported:
            return "unsupported"
        case .unauthorized:
            return "unauthorized"
        case .poweredOff:
            return "poweredOff"
        case .poweredOn:
            return "poweredOn"
        @unknown default:
            return "unknown(\(state.rawValue))"
        }
    }

    private func automationChannelName(_ channel: ChannelID) -> String {
        switch channel {
        case .mesh:
            return "mesh"
        case .location(let geohash):
            return "location:\(geohash.geohash)"
        }
    }
}
#endif

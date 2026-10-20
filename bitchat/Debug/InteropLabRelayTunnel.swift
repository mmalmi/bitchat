#if DEBUG && BITCHAT_INTEROP_LAB && os(iOS)
import Foundation
import Network

/// Byte-preserving USB transport for the ordinary local WebSocket client.
/// The host initiates authenticated pipes through usbmux; no LAN is required.
final class InteropLabRelayTunnel {
    private let queue = DispatchQueue(label: "chat.bitchat.lab-relay-tunnel")
    private let clientListener: NWListener
    private let tunnelListener: NWListener
    private let token: Data
    private var clients: [NWConnection] = []
    private var tunnels: [NWConnection] = []
    private var active: [UUID: (NWConnection, NWConnection)] = [:]

    init() throws {
        guard let secret = ProcessInfo.processInfo.environment["BITCHAT_LAB_CONTROL_TOKEN"],
              secret.count >= 32 else { throw CocoaError(.coderInvalidValue) }
        token = Data((secret + "\n").utf8)
        func listener(_ port: UInt16) throws -> NWListener {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            return try NWListener(using: parameters)
        }
        clientListener = try listener(18762)
        tunnelListener = try listener(18765)
        clientListener.newConnectionHandler = { [weak self] connection in
            guard let self, self.clients.count < 4 else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.clients.append(connection)
            self.pair()
        }
        tunnelListener.newConnectionHandler = { [weak self] connection in
            guard let self, self.tunnels.count < 4 else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.authenticate(connection, bytes: Data())
        }
        clientListener.start(queue: queue)
        tunnelListener.start(queue: queue)
    }

    private func authenticate(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128) { [weak self] data, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var received = bytes
            if let data { received.append(data) }
            guard received.count <= self.token.count,
                  self.token.starts(with: received) else { connection.cancel(); return }
            if received == self.token {
                self.tunnels.append(connection)
                self.pair()
            } else if !done {
                self.authenticate(connection, bytes: received)
            } else {
                connection.cancel()
            }
        }
    }

    private func pair() {
        while !clients.isEmpty && !tunnels.isEmpty {
            let client = clients.removeFirst()
            let tunnel = tunnels.removeFirst()
            let id = UUID()
            active[id] = (client, tunnel)
            tunnel.send(content: Data("OK".utf8), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                guard error == nil else { self.finish(id); return }
                self.copy(from: client, to: tunnel, id: id)
                self.copy(from: tunnel, to: client, id: id)
            })
        }
    }

    private func copy(from source: NWConnection, to destination: NWConnection, id: UUID) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty else { self.finish(id); return }
            destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard let self else { return }
                if sendError != nil || done { self.finish(id) }
                else { self.copy(from: source, to: destination, id: id) }
            })
        }
    }

    private func finish(_ id: UUID) {
        guard let pair = active.removeValue(forKey: id) else { return }
        pair.0.cancel()
        pair.1.cancel()
    }
}
#endif

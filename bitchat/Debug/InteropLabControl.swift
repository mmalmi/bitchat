#if DEBUG && BITCHAT_INTEROP_LAB
import Foundation
import Network

/// Bounded private loopback control. The launch token never enters build artifacts.
@MainActor
final class InteropLabControl {
    private let listener: NWListener
    private let token: String
    private let execute: ([String: Any]) -> [String: Any]

    init(execute: @escaping ([String: Any]) -> [String: Any]) throws {
        guard let token = ProcessInfo.processInfo.environment["BITCHAT_LAB_CONTROL_TOKEN"], token.count >= 32 else {
            throw CocoaError(.coderInvalidValue)
        }
        self.token = token
        self.execute = execute
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 18761)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                connection.start(queue: .main)
                self.read(connection, accumulated: Data())
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { connection.cancel() }
            }
        }
        listener.start(queue: .main)
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, error == nil else { connection.cancel(); return }
                var bytes = accumulated
                if let data { bytes.append(data) }
                guard bytes.count <= 16384 else { self.respond(connection, ["error": "request_too_large"], status: 413); return }
                guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)),
                      let header = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else {
                    if done { connection.cancel() } else { self.read(connection, accumulated: bytes) }
                    return
                }
                let lines = header.components(separatedBy: "\r\n")
                let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }?
                    .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                guard authorization == "Bearer \(self.token)" else { self.respond(connection, ["error": "unauthorized"], status: 401); return }
                let lengthLine = lines.first { $0.lowercased().hasPrefix("content-length:") }
                let length = lengthLine?.split(separator: ":", maxSplits: 1).last
                    .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
                guard (0...8192).contains(length), !lines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }) else {
                    self.respond(connection, ["error": "invalid_length"], status: 400); return
                }
                let body = bytes[boundary.upperBound...]
                guard body.count >= length else {
                    if done { connection.cancel() } else { self.read(connection, accumulated: bytes) }
                    return
                }
                if lines.first == "GET /status HTTP/1.1" {
                    self.respond(connection, self.execute(["op": "status"]))
                } else if lines.first == "POST /command HTTP/1.1",
                          let command = try? JSONSerialization.jsonObject(with: Data(body.prefix(length))) as? [String: Any] {
                    self.respond(connection, self.execute(command))
                } else { self.respond(connection, ["error": "invalid_request"], status: 400) }
            }
        }
    }

    private func respond(_ connection: NWConnection, _ object: [String: Any], status: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 \(status) Result\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif

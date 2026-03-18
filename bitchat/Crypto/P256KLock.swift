import Foundation

/// The `swift-secp256k1` (P256K) wrapper may use shared global state underneath.
/// To keep Nostr keygen/sign/encrypt operations safe under concurrent test runs
/// (Swift Testing may execute tests in parallel), we serialize P256K entrypoints.
enum P256KLock {
    private static let lock = NSLock()

    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}


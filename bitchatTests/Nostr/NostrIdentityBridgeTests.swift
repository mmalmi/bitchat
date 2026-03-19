import Foundation
import Testing
@testable import bitchat

struct NostrIdentityBridgeTests {

    @Test("Current Nostr identity stays stable in-memory when custom keychain persistence is unavailable")
    func currentIdentity_staysStableWhenCustomKeychainPersistenceIsUnavailable() throws {
        let keychain = EphemeralCustomServiceKeychain()
        let bridge = NostrIdentityBridge(keychain: keychain)

        let first = try #require(try bridge.getCurrentNostrIdentity())
        let second = try #require(try bridge.getCurrentNostrIdentity())

        #expect(first.publicKeyHex == second.publicKeyHex)
        #expect(keychain.customLoadCount == 1)
        #expect(keychain.customSaveCount == 1)
    }
}

private final class EphemeralCustomServiceKeychain: KeychainManagerProtocol {
    private(set) var customLoadCount = 0
    private(set) var customSaveCount = 0

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool { true }
    func getIdentityKey(forKey key: String) -> Data? { nil }
    func deleteIdentityKey(forKey key: String) -> Bool { true }
    func deleteAllKeychainData() -> Bool { true }

    func secureClear(_ data: inout Data) {
        data = Data()
    }

    func secureClear(_ string: inout String) {
        string = ""
    }

    func verifyIdentityKeyExists() -> Bool { false }

    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        .itemNotFound
    }

    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        .success
    }

    func save(key: String, data: Data, service: String, accessible: CFString?) {
        customSaveCount += 1
    }

    func load(key: String, service: String) -> Data? {
        customLoadCount += 1
        return nil
    }

    func delete(key: String, service: String) {}
}

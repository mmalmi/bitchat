//
// InMemoryKeychainManager.swift
// bitchat
//
// Used to keep unit/integration tests hermetic by avoiding writes to the user's keychain.
//

import Foundation

/// Minimal in-memory `KeychainManagerProtocol` implementation.
///
/// This is NOT a secure storage mechanism and must never be used for production persistence.
final class InMemoryKeychainManager: KeychainManagerProtocol {
    private var storage: [String: Data] = [:]
    private var serviceStorage: [String: [String: Data]] = [:]

    // MARK: - Identity Keys

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        storage[key] = keyData
        return true
    }

    func getIdentityKey(forKey key: String) -> Data? {
        storage[key]
    }

    func deleteIdentityKey(forKey key: String) -> Bool {
        storage.removeValue(forKey: key)
        return true
    }

    func deleteAllKeychainData() -> Bool {
        storage.removeAll()
        serviceStorage.removeAll()
        return true
    }

    func secureClear(_ data: inout Data) {
        data = Data()
    }

    func secureClear(_ string: inout String) {
        string = ""
    }

    func verifyIdentityKeyExists() -> Bool {
        // Mirrors the test mock behavior; callers should treat this as a best-effort check.
        storage["identity_noiseStaticKey"] != nil
    }

    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        if let data = storage[key] {
            return .success(data)
        }
        return .itemNotFound
    }

    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        storage[key] = keyData
        return .success
    }

    // MARK: - Generic Data Storage

    func save(key: String, data: Data, service: String, accessible: CFString?) {
        if serviceStorage[service] == nil {
            serviceStorage[service] = [:]
        }
        serviceStorage[service]?[key] = data
    }

    func load(key: String, service: String) -> Data? {
        serviceStorage[service]?[key]
    }

    func delete(key: String, service: String) {
        serviceStorage[service]?.removeValue(forKey: key)
    }
}


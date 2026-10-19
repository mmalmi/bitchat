#if DEBUG && BITCHAT_INTEROP_LAB
import BitFoundation
import Foundation
import CoreLocation

/// Only compiled into the disposable, sandboxed interop app.
enum InteropLabStorage {
    static let root: URL = {
        precondition(Bundle.main.bundleIdentifier == "chat.bitchat.ndrlab")
        precondition(NSHomeDirectory().contains("/Containers/chat.bitchat.ndrlab/Data"))
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("interop-lab", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }()
    static let keychain = InteropLabKeychain(root: root)
}

/// Persistent synthetic test keys. Never calls the OS keychain.
final class InteropLabKeychain: KeychainManagerProtocol {
    private let lock = NSRecursiveLock()
    private let url: URL
    private var values: [String: [String: Data]] = [:]
    private var readable = true

    init(root: URL) {
        url = root.appendingPathComponent("keys.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { values = try JSONDecoder().decode([String: [String: Data]].self, from: Data(contentsOf: url)) }
            catch { readable = false }
        }
    }

    private func mutate(_ change: (inout [String: [String: Data]]) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard readable else { return false }
        var next = values
        change(&next)
        do {
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            values = next
            return true
        } catch { return false }
    }

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        mutate { $0["identity", default: [:]][key] = keyData }
    }
    func getIdentityKey(forKey key: String) -> Data? { load(key: key, service: "identity") }
    func deleteIdentityKey(forKey key: String) -> Bool { mutate { $0["identity"]?[key] = nil } }
    func deleteAllKeychainData() -> Bool { mutate { $0.removeAll() } }
    func secureClear(_ data: inout Data) { data.resetBytes(in: data.indices); data.removeAll() }
    func secureClear(_ string: inout String) { string = "" }
    func verifyIdentityKeyExists() -> Bool { getIdentityKey(forKey: "identity_noiseStaticKey") != nil }
    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        loadWithResult(key: key, service: "identity")
    }
    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        saveIdentityKey(keyData, forKey: key) ? .success : .otherError(-1)
    }
    func save(key: String, data: Data, service: String, accessible: CFString?) {
        _ = mutate { $0[service, default: [:]][key] = data }
    }
    func load(key: String, service: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return readable ? values[service]?[key] : nil
    }
    func loadWithResult(key: String, service: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        guard readable else { return .otherError(-1) }
        return values[service]?[key].map(KeychainReadResult.success) ?? .itemNotFound
    }
    func delete(key: String, service: String) { _ = mutate { $0[service]?[key] = nil } }
    func deleteAll(service: String) { _ = mutate { $0[service] = nil } }
}

/// No CoreLocation object is constructed and no location API is queried.
final class InteropLabNoLocation: LocationStateManaging {
    weak var delegate: CLLocationManagerDelegate?
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var authorizationStatus: CLAuthorizationStatus { .denied }
    func requestWhenInUseAuthorization() {}
    func requestLocation() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
}
final class InteropLabNoGeocoder: LocationStateGeocoding {
    func cancelGeocode() {}
    func reverseGeocodeLocation(_ location: CLLocation, completionHandler: @escaping ([CLPlacemark]?, Error?) -> Void) {
        completionHandler([], nil)
    }
}
#endif

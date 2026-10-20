import Foundation

/// Rollout gate for the cross-platform double-ratchet transport.
///
/// Compatible mutual favorites negotiate this transport over authenticated Noise.
/// Peers without the capability retain the existing relay envelope.
enum DoubleRatchetFeature {
    #if DEBUG && BITCHAT_INTEROP_LAB
    static let isEnabled = ProcessInfo.processInfo.environment["BITCHAT_LAB_GATE_OFF"] != "1"
    #elseif BITCHAT_DISABLE_NDR
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif
}

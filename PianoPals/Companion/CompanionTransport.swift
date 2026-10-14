import CryptoKit
import Foundation
import Network
import OSLog
import Security

/// Pairing code ↔ encrypted connection. Both devices derive the same TLS pre-shared key from the 8-digit code the iPhone
/// shows, so nothing without the code can connect, and everything on the link is encrypted.
let companionLog = Logger(subsystem: "com.example.PianoPals", category: "companion")

enum CompanionSecurity {
    static let bonjourType = "_pianopals-cam._tcp"
    private static let identity = "pianopals"

    static func makeCode() -> String {
        String((0..<8).map { _ in String(Int.random(in: 0...9)) }.joined())
    }

    /// "12345678" → "1234 5678".
    static func display(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return code.prefix(4) + " " + code.suffix(4)
    }

    /// Digits only, so "1234 5678" or "1234-5678" typed by a person works.
    static func normalize(_ typed: String) -> String { typed.filter(\.isNumber) }

    static func isValid(_ code: String) -> Bool { code.count == 8 && code.allSatisfy(\.isNumber) }

    static func presharedKey(for code: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("pianopals-companion-v1".utf8), using: SymmetricKey(data: Data(code.utf8)))
        return Data(mac)
    }

    /// Debug only: `-debugInterface wifi|loopback` pins connections to one interface (two simulators on one Mac can otherwise
    /// pick the USB network of a connected device and stall).
    static func applyDebugInterface(to parameters: NWParameters) {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "debugInterface") {
        case "wifi": parameters.requiredInterfaceType = .wifi
        case "loopback": parameters.requiredInterfaceType = .loopback
        default: break
        }
        #endif
    }

    /// TLS 1.2 PSK parameters (AES-128-GCM) for a given pairing code.
    static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = presharedKey(for: code).withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        applyDebugInterface(to: parameters)
        return parameters
    }
}

/// A TCP connection that sends and receives whole `CompanionMessage`s (4-byte length prefix + JSON).
final class FramedConnection: @unchecked Sendable {
    static let maxMessageBytes = 1_000_000
    /// If this many sends are still waiting to leave, droppable messages (frames, previews) are skipped so latency stays low.
    static let maxQueuedSends = 3

    let connection: NWConnection
    var onMessage: (@Sendable (CompanionMessage) -> Void)?
    var onState: (@Sendable (NWConnection.State) -> Void)?
    private let queue: DispatchQueue
    private let queued = Locked(0)

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            companionLog.info("connection state: \(String(describing: state), privacy: .public)")
            self?.onState?(state)
            if case .ready = state { self?.receiveHeader() }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    static func frame(_ message: CompanionMessage) throws -> Data {
        let payload = try message.encoded()
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }

    func send(_ message: CompanionMessage, droppable: Bool = false) {
        if droppable, queued.current >= Self.maxQueuedSends { return }
        guard let data = try? Self.frame(message) else { return }
        queued.withLock { $0 += 1 }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.queued.withLock { $0 -= 1 } })
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, data.count == 4, error == nil else { if isComplete || error != nil { self.connection.cancel() }; return }
            let length = Int(UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard length > 0, length <= Self.maxMessageBytes else { self.connection.cancel(); return }
            self.receiveBody(length)
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, data.count == length, error == nil else { if isComplete || error != nil { self.connection.cancel() }; return }
            if let message = try? CompanionMessage.decode(data) { self.onMessage?(message) }
            self.receiveHeader()
        }
    }
}

/// Keychain wrapper for pairing codes. Uses the iOS-style data-protection keychain on every platform (on a Mac the default would
/// be the legacy login keychain, which prompts). If the keychain refuses (e.g. an unsigned test build without keychain
/// entitlements), falls back to a local-only preference so pairing still works.
enum PairingKeychain {
    private static let service = "PianoPals.companion"
    private static func fallbackKey(_ account: String) -> String { "pairing.fallback.\(account)" }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    static func save(_ secret: String, account: String) {
        SecItemDelete(base(account) as CFDictionary)
        var item = base(account)
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey(account))
        } else {
            UserDefaults.standard.set(secret, forKey: fallbackKey(account))
        }
    }

    static func load(account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        return UserDefaults.standard.string(forKey: fallbackKey(account))
    }

    static func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(account))
    }
}

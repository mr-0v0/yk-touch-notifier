import Foundation

// Predicate and message patterns ported from yubikey-touch-detector (ISC),
// detector/watcher_darwin.go. Keep every Apple log string in this file.
public let logPredicate = #"(processImagePath == "/kernel" AND senderImagePath ENDSWITH "IOHIDFamily") OR (subsystem CONTAINS "CryptoTokenKit")"#
let cardBusyMessage = "Time extension received"

public enum Source: String, CaseIterable {
    case card = "CARD", fido = "FIDO"
}

public enum Signal: Equatable {
    case busy(Source), end(Source)
}

/// Turns unified-log ndjson entries into busy/end signals. Reads only the
/// process/sender paths, subsystem and message; nothing is stored.
public struct LogParser {
    var fidoClients: [String: Bool] = [:]  // IOHIDLibUserClient -> opened a Yubico device
    var activeClients: Set<String> = []
    let isYubico: (String) -> Bool

    public init(isYubico: @escaping (String) -> Bool) { self.isYubico = isYubico }

    public mutating func signals(line: Data) -> [Signal] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        return signals(
            process: obj["processImagePath"] as? String ?? "",
            sender: obj["senderImagePath"] as? String ?? "",
            subsystem: obj["subsystem"] as? String ?? "",
            message: obj["eventMessage"] as? String ?? "")
    }

    mutating func signals(process: String, sender: String, subsystem: String, message: String) -> [Signal] {
        if process == "/kernel" && sender.hasSuffix("IOHIDFamily") {
            return fido(message)
        }
        if process.hasSuffix("usbsmartcardreaderd") && subsystem.hasSuffix("CryptoTokenKit") {
            return [message == cardBusyMessage ? .busy(.card) : .end(.card)]
        }
        return []
    }

    mutating func fido(_ message: String) -> [Signal] {
        if let (device, client) = hidConnection(message, " open by ") {
            fidoClients[client] = isYubico(device)
        }
        if let (_, client) = hidConnection(message, " close by ") {
            fidoClients[client] = nil
            return deactivate(client)
        }
        let fields = message.split(separator: " ").map(String.init)
        guard fields.count >= 2, fidoClients[fields[0]] == true else { return [] }
        switch fields.last {
        case "startQueue":
            let wasIdle = activeClients.isEmpty
            activeClients.insert(fields[0])
            return wasIdle ? [.busy(.fido)] : []
        case "stopQueue":
            return deactivate(fields[0])
        default:
            return []
        }
    }

    mutating func deactivate(_ client: String) -> [Signal] {
        guard activeClients.remove(client) != nil, activeClients.isEmpty else { return [] }
        return [.end(.fido)]
    }

    func hidConnection(_ message: String, _ separator: String) -> (String, String)? {
        guard let r = message.range(of: separator) else { return nil }
        let device = message[..<r.lowerBound]
        let prefix = "AppleUserUSBHostHIDDevice:"
        guard device.hasPrefix(prefix),
              let client = message[r.upperBound...].split(separator: " ").first else { return nil }
        return (String(device.dropFirst(prefix.count)), String(client))
    }
}

/// idle -> pending (first busy) -> notified (still pending after threshold) -> idle
/// (end signal, or for the card: no time extension for `gap` seconds).
public struct TouchTracker {
    struct Pending { var since: Double; var last: Double; var notified = false }
    var pending: [Source: Pending] = [:]
    let threshold: Double
    let gap: Double

    public init(threshold: Double, gap: Double) {
        self.threshold = threshold
        self.gap = gap
    }

    /// Returns (source, on) for each notification that must be shown (true) or removed (false).
    public mutating func handle(_ signal: Signal, at t: Double) -> [(Source, Bool)] {
        switch signal {
        case .busy(let s):
            pending[s, default: Pending(since: t, last: t)].last = t
            return tick(at: t)
        case .end(let s):
            return pending.removeValue(forKey: s)?.notified == true ? [(s, false)] : []
        }
    }

    public mutating func tick(at t: Double) -> [(Source, Bool)] {
        var out: [(Source, Bool)] = []
        for (s, p) in pending {
            // FIDO only logs startQueue once, so it has no gap; it waits for stopQueue/close.
            if s == .card && t - p.last >= gap {
                pending[s] = nil
                if p.notified { out.append((s, false)) }
            } else if !p.notified && t - p.since >= threshold {
                pending[s]?.notified = true
                out.append((s, true))
            }
        }
        return out
    }
}

/// `ioreg` output -> registry id -> is a Yubico (VID 0x1050) device.
public func parseYubicoDevices(_ output: String) -> [String: Bool] {
    var devices: [String: Bool] = [:]
    var device = ""
    for line in output.split(separator: "\n") {
        let fields = line.split(separator: " ")
        if let i = fields.firstIndex(of: "id"), i + 1 < fields.count {
            device = String(fields[i + 1].trimmingCharacters(in: [","]))
        }
        if !device.isEmpty && line.contains(#""VendorID" = "#) {
            devices[device] = line.contains(#""VendorID" = 0x1050"#)
        }
    }
    return devices
}

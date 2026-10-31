import AppKit
import Foundation
import os
import UserNotifications
import YKTouchCore

let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yk-touch-notifier", category: "main")

// MARK: flags

var thresholdMs = 600.0
var gapMs = 1500.0
var fido = true
var stdoutMode = false
var verbose = false

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--threshold-ms": thresholdMs = args.next().flatMap(Double.init) ?? thresholdMs
    case "--gap-ms": gapMs = args.next().flatMap(Double.init) ?? gapMs
    case "--no-fido": fido = false
    case "--stdout": stdoutMode = true
    case "--verbose": verbose = true
    default:
        print("""
            usage: yk-touch-notifier [--threshold-ms N] [--gap-ms N] [--no-fido] [--stdout] [--verbose]
              --threshold-ms  wait this long before notifying (default 600)
              --gap-ms        card counts as idle after this long without a time extension (default 1500)
              --no-fido       ignore FIDO2/U2F
              --stdout        print CARD_1/CARD_0/FIDO_1/FIDO_0 instead of posting notifications
              --verbose       print raw matched log lines to stderr (debug only)
            """)
        exit(arg == "-h" || arg == "--help" ? 0 : 2)
    }
}

// Read-only check: without disable-ccid, scdaemon bypasses CryptoTokenKit and nothing is logged.
let gnupgHome = ProcessInfo.processInfo.environment["GNUPGHOME"] ?? NSHomeDirectory() + "/.gnupg"
let scdConf = (try? String(contentsOfFile: gnupgHome + "/scdaemon.conf", encoding: .utf8)) ?? ""
if !scdConf.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "disable-ccid" }) {
    log.warning("disable-ccid not found in scdaemon.conf; gpg/SSH touches will not be detected")
    FileHandle.standardError.write(Data("warning: disable-ccid not in \(gnupgHome)/scdaemon.conf; gpg/SSH touches will not be detected\n".utf8))
}

// MARK: output

let center: UNUserNotificationCenter? = stdoutMode ? nil : UNUserNotificationCenter.current()

final class Delegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }
}
let delegate = Delegate()
center?.delegate = delegate
center?.requestAuthorization(options: [.alert, .sound]) { ok, err in
    if !ok { log.error("notification permission denied: \(String(describing: err), privacy: .public)") }
}

func show(_ source: Source, _ on: Bool) {
    if stdoutMode {
        print("\(source.rawValue)_\(on ? 1 : 0)")
        fflush(stdout)
        return
    }
    let id = source.rawValue
    guard on else {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
        center?.removePendingNotificationRequests(withIdentifiers: [id])
        return
    }
    let content = UNMutableNotificationContent()
    content.title = "Touch your YubiKey"
    content.body = source == .card ? "gpg / SSH is waiting for a touch" : "A security key (FIDO2) request is waiting for a touch"
    content.sound = .default
    content.interruptionLevel = .timeSensitive
    center?.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
}

// MARK: detection (all state lives on the main queue)

var tracker = TouchTracker(threshold: thresholdMs / 1000, gap: gapMs / 1000)
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func apply(_ changes: [(Source, Bool)]) { for (s, on) in changes { show(s, on) } }

var yubicoDevices: [String: Bool] = [:]
var yubicoCheckedAt = -Double.infinity
func isYubico(_ device: String) -> Bool {
    if yubicoDevices[device] == nil || now() - yubicoCheckedAt > 5 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-k", "VendorID", "-l", "-w0", "-x"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        yubicoDevices = parseYubicoDevices(String(decoding: data, as: UTF8.self))
        yubicoCheckedAt = now()
    }
    return yubicoDevices[device] ?? false
}
var parser = LogParser(isYubico: isYubico)

var restartDelay = 1.0
func startLogStream() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    p.arguments = ["stream", "--level", "debug", "--style", "ndjson", "--predicate", logPredicate]
    let pipe = Pipe()
    p.standardOutput = pipe
    var buffer = Data()
    pipe.fileHandleForReading.readabilityHandler = { h in
        let chunk = h.availableData
        DispatchQueue.main.async {
            restartDelay = 1
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                for signal in parser.signals(line: Data(line)) {
                    if !fido, signal == .busy(.fido) || signal == .end(.fido) { continue }
                    if verbose { FileHandle.standardError.write(line + Data("\n".utf8)) }
                    apply(tracker.handle(signal, at: now()))
                }
            }
        }
    }
    p.terminationHandler = { _ in
        pipe.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.async {
            log.error("log stream exited; restarting in \(restartDelay, privacy: .public)s")
            // Drop any shown notification: we can't know whether the card is still waiting.
            for s in Source.allCases { apply(tracker.handle(.end(s), at: now())) }
            DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay, execute: startLogStream)
            restartDelay = min(restartDelay * 2, 60)
        }
    }
    do { try p.run() } catch {
        log.error("cannot start log stream: \(error.localizedDescription, privacy: .public)")
        p.terminationHandler?(p)
    }
}

startLogStream()
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in apply(tracker.tick(at: now())) }
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler {
    center?.removeAllDeliveredNotifications()
    exit(0)
}
term.resume()
log.info("started (threshold \(thresholdMs, privacy: .public) ms, gap \(gapMs, privacy: .public) ms)")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()

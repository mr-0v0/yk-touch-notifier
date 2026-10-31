import Foundation
import YKTouchCore

// Assert-based checks: CommandLineTools ships no swift-testing macro plugin, so `swift test` needs Xcode.
// ponytail: synthetic lines in the shape upstream matches; replace with recorded
// captures once they have been made with a real touch.
func line(_ process: String, sender: String = "", subsystem: String = "", _ message: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "processImagePath": process, "senderImagePath": sender,
        "subsystem": subsystem, "eventMessage": message,
    ])
}
func check(_ ok: Bool, _ l: UInt = #line) { if !ok { print("FAIL line \(l)"); failed = true } }
var failed = false
let ctk = "com.apple.CryptoTokenKit"
let reader = "/System/Library/CryptoTokenKit/usbsmartcardreaderd.slotd/Contents/MacOS/usbsmartcardreaderd"
func hid(_ m: String) -> Data { line("/kernel", sender: "/System/Library/Extensions/IOHIDFamily.kext/IOHIDFamily", m) }

func cardSignals() {
    var p = LogParser(isYubico: { _ in true })
    check(p.signals(line: line(reader, subsystem: ctk, "Time extension received")) == [.busy(.card)])
    check(p.signals(line: line(reader, subsystem: ctk, "APDU -> ...")) == [.end(.card)])
    check(p.signals(line: line("/usr/libexec/ctkd", subsystem: ctk, "Time extension received")) == [])
    check(p.signals(line: Data("not json".utf8)) == [])
}

func fidoOnlyForYubicoClients() {
    var p = LogParser(isYubico: { $0 == "0x1" })
    var got: [Signal] = []
    for m in [
        "AppleUSBTopCaseHIDDriver:0x1 open by IOHIDLibUserClient:0x2 (0x1)",
        "IOHIDLibUserClient:0x2 startQueue",
        "AppleUserUSBHostHIDDevice:0x9 open by IOHIDLibUserClient:0x4 (0x1)",
        "IOHIDLibUserClient:0x4 startQueue",
        "AppleUserUSBHostHIDDevice:0x1 open by IOHIDLibUserClient:0x3 (0x1)",
        "IOHIDLibUserClient:0x3 startQueue",
        "IOHIDLibUserClient:0x3 startQueue",
        "IOHIDLibUserClient:0x3 stopQueue",
        "AppleUserUSBHostHIDDevice:0x1 open by IOHIDLibUserClient:0x5 (0x1)",
        "IOHIDLibUserClient:0x5 startQueue",
        "AppleUserUSBHostHIDDevice:0x1 close by IOHIDLibUserClient:0x5 (0x1)",
    ] { got += p.signals(line: hid(m)) }
    check(got == [.busy(.fido), .end(.fido), .busy(.fido), .end(.fido)])
}

func fastOperationNeverNotifies() {
    var t = TouchTracker(threshold: 0.6, gap: 1.5)
    check(t.handle(.busy(.card), at: 0).isEmpty)
    check(t.tick(at: 0.3).isEmpty)
    check(t.handle(.end(.card), at: 0.4).isEmpty)
    check(t.tick(at: 5).isEmpty)
}

func touchNotifiesThenClearsOnEnd() {
    var t = TouchTracker(threshold: 0.6, gap: 1.5)
    _ = t.handle(.busy(.card), at: 0)
    check(t.tick(at: 0.5).isEmpty)
    let on = t.tick(at: 0.7)
    check(on.count == 1 && on[0] == (.card, true))
    check(t.handle(.busy(.card), at: 1.0).isEmpty)  // repeated time extension: no re-notify
    let off = t.handle(.end(.card), at: 3)
    check(off.count == 1 && off[0] == (.card, false))
}

func cardClearsAfterGapFidoDoesNot() {
    var t = TouchTracker(threshold: 0.6, gap: 1.5)
    _ = t.handle(.busy(.card), at: 0)
    _ = t.handle(.busy(.fido), at: 0)
    check(t.tick(at: 1).count == 2)
    let off = t.tick(at: 1.6)
    check(off.count == 1 && off[0] == (.card, false))
    check(t.tick(at: 60).isEmpty)  // FIDO waits for stopQueue
    check(t.handle(.end(.fido), at: 61).count == 1)
}

func ioregParsing() {
    let out = """
        +-o AppleUserUSBHostHIDDevice  <class AppleUserUSBHostHIDDevice, id 0x100000abc, registered, matched, active>
          |   "VendorID" = 0x1050
        +-o AppleUserUSBHostHIDDevice  <class AppleUserUSBHostHIDDevice, id 0x100000def, registered, matched, active>
          |   "VendorID" = 0x5ac
        """
    check(parseYubicoDevices(out) == ["0x100000abc": true, "0x100000def": false])
}

cardSignals(); fidoOnlyForYubicoClients(); fastOperationNeverNotifies()
touchNotifiesThenClearsOnEnd(); cardClearsAfterGapFidoDoesNot(); ioregParsing()
print(failed ? "FAILED" : "all checks passed")
exit(failed ? 1 : 0)

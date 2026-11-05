import Cocoa
import Carbon
final class InputSourceManager { var switches = 0; func toggleInputSource() { switches += 1 } }
enum Diagnostics { static func log(_ message: String) {} }
final class FnHIDMonitor {
 static var current: FnHIDMonitor!
 init() { Self.current = self }
 var onOtherKey: (() -> Void)?
 var onState: ((UInt64, Bool) -> Void)?
 var onDeviceRemoved: ((UInt64) -> Void)?
 var heldKeyCount = 0
 var keyStateAgeMs = 0
 var hasOtherKeysDown: Bool { heldKeyCount > 0 }
 var confirmedReleased = false
 func reconcile() { if confirmedReleased { heldKeyCount = 0 } }
 func logSnapshot(reason: String) {}
 func start() {}
 func stop() {}
}
precondition(!IsSecureEventInputEnabled(), "Run without Secure Input")
UserDefaults.standard.set(true, forKey: "switchOnRelease")
let source = InputSourceManager()
let monitor = KeyMonitor(inputSourceManager: source)
monitor.start()
let hid = FnHIDMonitor.current!
func tap() { hid.onState?(1, true); hid.onState?(1, false) }
tap(); precondition(source.switches == 1)
hid.heldKeyCount = 1
tap(); precondition(source.switches == 1, "Held key must block")
hid.confirmedReleased = true
tap(); precondition(source.switches == 2, "Confirmed release must recover")
hid.onState?(1, true)
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
hid.onState?(1, false)
precondition(source.switches == 2, "Wake must cancel old gesture")
tap(); precondition(source.switches == 3)
hid.onState?(1, true); hid.onDeviceRemoved?(1); hid.onState?(1, false)
precondition(source.switches == 3, "Removal must cancel gesture")
tap(); precondition(source.switches == 4)
monitor.stop()
print("PASS: normal Fn, held chord, released-key recovery, wake and removal cancellation")

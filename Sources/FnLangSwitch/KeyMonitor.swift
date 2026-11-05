import Cocoa
import Carbon

final class KeyMonitor {
    private let inputSourceManager: InputSourceManager
    private let hid = FnHIDMonitor()
    private var monitor: Any?
    private var localMonitor: Any?
    private var heldDevices = Set<UInt64>()
    private var otherKeyPressed = false
    private var cancellationReasons = Set<String>()
    private var workspaceObservers = [NSObjectProtocol]()
    private var recoveryTimer: Timer?
    private var secureInputWasEnabled = false
    var onStatus: ((Bool, Bool) -> Void)?
    private var heartbeat: Timer?
    private var wakeChecks = [DispatchWorkItem]()
    private var lastHeartbeat: Date?
    private var lastLifecycle = "none"
    private var lastLifecycleTime: Date?
    private var eventCount = 0
    private var lastEventTime: TimeInterval?
    private var pressTime: TimeInterval = 0
    private var switchOnRelease: Bool { UserDefaults.standard.bool(forKey: "switchOnRelease") }
    private let blockingModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    init(inputSourceManager: InputSourceManager) { self.inputSourceManager = inputSourceManager }

    func start() {
        Diagnostics.log("monitor.start accessibility=\(AXIsProcessTrusted()) secureInput=\(IsSecureEventInputEnabled()) releaseMode=\(switchOnRelease) backend=HID diagnosticsVersion=4 pid=\(ProcessInfo.processInfo.processIdentifier)")
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp, .systemDefined]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] in self?.handleEvent($0) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
            return event
        }
        hid.onState = { [weak self] device, down in self?.handleFn(device: device, down: down) }
        hid.onOtherKey = { [weak self] in
            guard let self, !self.heldDevices.isEmpty else { return }
            self.otherKeyPressed = true
            self.cancellationReasons.insert("hardwareChord")
            Diagnostics.log("tap.cancel reason=hardwareChord \(self.diagnosticState())")
        }
        hid.onDeviceRemoved = { [weak self] device in
            guard let self else { return }
            if self.heldDevices.contains(device) { self.cancelGesture(reason: "deviceRemoved") }
        }
        hid.start()
        secureInputWasEnabled = IsSecureEventInputEnabled()
        let recovery = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateRecovery() }
        recoveryTimer = recovery
        RunLoop.main.add(recovery, forMode: .common)
        updateRecovery()
        logSnapshot(reason: "start")
        lastHeartbeat = Date()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            let gap = self.lastHeartbeat.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
            self.lastHeartbeat = now
            self.logSnapshot(reason: "heartbeat_gapMs_\(gap)")
        }
        heartbeat = timer
        RunLoop.main.add(timer, forMode: .common)
        let center = NSWorkspace.shared.notificationCenter
        for (name, label) in [(NSWorkspace.willSleepNotification, "willSleep"),
                              (NSWorkspace.didWakeNotification, "didWake"),
                              (NSWorkspace.sessionDidResignActiveNotification, "sessionInactive"),
                              (NSWorkspace.sessionDidBecomeActiveNotification, "sessionActive"),
                              (NSWorkspace.screensDidSleepNotification, "screensSleep"),
                              (NSWorkspace.screensDidWakeNotification, "screensWake")] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.cancelGesture(reason: label)
                self.hid.reconcile()
                self.lastLifecycle = label
                self.lastLifecycleTime = Date()
                self.logSnapshot(reason: label)
                if label == "willSleep" || label == "didWake" {
                    self.wakeChecks.forEach { $0.cancel() }
                    self.wakeChecks.removeAll()
                }
                if label == "didWake" {
                    for delay in [1, 5, 30] {
                        let work = DispatchWorkItem { [weak self] in
                            self?.logSnapshot(reason: "didWake_plus\(delay)s")
                        }
                        self.wakeChecks.append(work)
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
                    }
                }
            })
        }
    }

    func stop() {
        Diagnostics.log("monitor.stop \(diagnosticState())")
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        heartbeat?.invalidate()
        heartbeat = nil
        wakeChecks.forEach { $0.cancel() }
        wakeChecks.removeAll()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        hid.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
        heldDevices.removeAll()
    }

    private func handleEvent(_ event: NSEvent) {
        eventCount += 1
        lastEventTime = ProcessInfo.processInfo.systemUptime
        guard !heldDevices.isEmpty else { return }
        // Fn's own flagsChanged event is not a chord. All other input cancels a tap.
        if event.type == .flagsChanged && event.keyCode == 63 { return }
        otherKeyPressed = true
        cancellationReasons.insert("eventType_\(event.type.rawValue)")
        Diagnostics.log("tap.cancel eventType=\(event.type.rawValue) \(diagnosticState())")
    }

    private func handleFn(device: UInt64, down: Bool) {
        updateRecovery()
        if down { hid.reconcile() }
        Diagnostics.log("hid.fn down=\(down) releaseMode=\(switchOnRelease)")
        if down {
            guard heldDevices.insert(device).inserted else {
                Diagnostics.log("hid.fn.ignored reason=duplicateDown")
                return
            }
            guard heldDevices.count == 1 else {
                otherKeyPressed = true
                cancellationReasons.insert("overlappingFnDevices")
                Diagnostics.log("tap.cancel reason=overlappingFnDevices \(diagnosticState())")
                return
            }
            cancellationReasons.removeAll()
            pressTime = ProcessInfo.processInfo.systemUptime
            let keysHeld = hid.hasOtherKeysDown
            let modifiersHeld = !CGEventSource.flagsState(.combinedSessionState).intersection(blockingModifiers).isEmpty
            let secureInput = IsSecureEventInputEnabled()
            otherKeyPressed = keysHeld || modifiersHeld || secureInput
            if keysHeld { cancellationReasons.insert("keysHeldAtPress") }
            if modifiersHeld {
                cancellationReasons.insert("modifiersAtPress")
            }
            if secureInput { cancellationReasons.insert("secureInputAtPress") }
            Diagnostics.log("tap.press reasons=\(reasonSummary) \(diagnosticState())")
            if keysHeld { hid.logSnapshot(reason: "keysHeldAtPress") }
            if !switchOnRelease && !otherKeyPressed { inputSourceManager.toggleInputSource() }
        } else {
            guard heldDevices.remove(device) != nil, heldDevices.isEmpty else {
                Diagnostics.log("hid.fn.ignored reason=unmatchedReleaseOrOtherFnHeld \(diagnosticState())")
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - pressTime
            let secureInput = IsSecureEventInputEnabled()
            let modifiersHeld = !CGEventSource.flagsState(.combinedSessionState).intersection(blockingModifiers).isEmpty
            let blocked = otherKeyPressed || secureInput || modifiersHeld
            if secureInput { cancellationReasons.insert("secureInputAtRelease") }
            if modifiersHeld {
                cancellationReasons.insert("modifiersAtRelease")
            }
            // Preserve the switching rules; record the duration limit separately from cancellation.
            let outcome = !switchOnRelease ? "pressMode" : blocked ? "blocked" : elapsed >= 0.4 ? "longHold" : "switch"
            Diagnostics.log("tap.release durationMs=\(Int(elapsed * 1000)) cancelled=\(blocked) outcome=\(outcome) reasons=\(reasonSummary) \(diagnosticState())")
            if switchOnRelease && !blocked && elapsed < 0.4 { inputSourceManager.toggleInputSource() }
        }
    }
    private func cancelGesture(reason: String) {
        heldDevices.removeAll()
        otherKeyPressed = true
        cancellationReasons = [reason]
        Diagnostics.log("tap.reset reason=\(reason)")
    }

    private func updateRecovery() {
        let secure = IsSecureEventInputEnabled()
        if secure != secureInputWasEnabled {
            secureInputWasEnabled = secure
            cancelGesture(reason: secure ? "secureInputEnabled" : "secureInputDisabled")
            if !secure { hid.reconcile() }
            Diagnostics.log("monitor.secureInput enabled=\(secure)")
        }
        onStatus?(secure, CGPreflightListenEventAccess())
    }

    private var reasonSummary: String {
        cancellationReasons.isEmpty ? "none" : cancellationReasons.sorted().joined(separator: ",")
    }

    private func logSnapshot(reason: String) {
        let lifecycleAge = lastLifecycleTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        let eventAge = lastEventTime.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) } ?? -1
        Diagnostics.log("monitor.snapshot reason=\(reason) pid=\(ProcessInfo.processInfo.processIdentifier) uptimeMs=\(Int(ProcessInfo.processInfo.systemUptime * 1000)) lastLifecycle=\(lastLifecycle) lifecycleAgeMs=\(lifecycleAge) appEvents=\(eventCount) lastAppEventAgeMs=\(eventAge) inputMonitoring=\(CGPreflightListenEventAccess()) accessibility=\(AXIsProcessTrusted()) \(diagnosticState())")
        hid.logSnapshot(reason: reason)
    }

    private func diagnosticState() -> String {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var modifiers = [String]()
        for (flag, name) in [(CGEventFlags.maskShift, "shift"), (.maskControl, "control"),
                             (.maskAlternate, "option"), (.maskCommand, "command")] {
            if flags.contains(flag) { modifiers.append(name) }
        }
        return "heldFnDevices=\(heldDevices.count) heldKeys=\(hid.heldKeyCount) keyStateAgeMs=\(hid.keyStateAgeMs) modifiers=\(modifiers.isEmpty ? "none" : modifiers.joined(separator: ",")) secureInput=\(IsSecureEventInputEnabled())"
    }
    deinit { stop() }
}

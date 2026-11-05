import Cocoa
import IOKit.hid

/// Fn state plus transient keyboard state for chord cancellation. No text is decoded or logged.
final class FnHIDMonitor {
    private var manager: IOHIDManager?
    private var heldKeys = Set<String>()
    private struct HeldKey {
        let element: IOHIDElement
        let since: TimeInterval
    }
    private var heldDetails = [String: HeldKey]()
    // Aliases exist only in this process. Never log registry IDs, cookies or key usages.
    private var deviceAliases = [UInt64: Int]()
    private var connectedDevices = Set<UInt64>()
    private var nextAlias = 1
    private var callbackCount = 0
    private var callbackErrors = 0
    private var keyDownCount = 0
    private var keyUpCount = 0
    private var duplicateDownCount = 0
    private var unmatchedUpCount = 0
    private var lastCallback: TimeInterval?
    private var lastKeyStateChange: TimeInterval?

    private func alias(for id: UInt64) -> Int {
        if let alias = deviceAliases[id] { return alias }
        let alias = nextAlias
        nextAlias += 1
        deviceAliases[id] = alias
        return alias
    }

    private func deviceEvent(_ device: IOHIDDevice, added: Bool, result: IOReturn) {
        var id: UInt64 = 0
        let identityResult = IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        guard identityResult == kIOReturnSuccess else {
            Diagnostics.log("hid.device.identityError result=\(identityResult)")
            return
        }
        if added { connectedDevices.insert(id) } else { connectedDevices.remove(id) }
        let held = heldKeys.filter { $0.hasPrefix("\(id):") }.count
        Diagnostics.log("hid.device event=\(added ? "added" : "removed") alias=\(alias(for: id)) result=\(result) connected=\(connectedDevices.count) heldKeys=\(held)")
        if !added {
            let stale = heldKeys.filter { $0.hasPrefix("\(id):") }
            for key in stale { heldKeys.remove(key); heldDetails.removeValue(forKey: key) }
            onDeviceRemoved?(id)
        }
    }

    func logSnapshot(reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        var cachedDown = 0
        var cachedUp = 0
        var readErrors = 0
        var oldestMs = 0
        for detail in heldDetails.values {
            oldestMs = max(oldestMs, Int((now - detail.since) * 1000))
            let value = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
            defer { value.deallocate() }
            // Read IOKit's cached state only; no forced device report or state reset.
            let result = IOHIDDeviceGetValueWithOptions(IOHIDElementGetDevice(detail.element),
                detail.element, value, IOHIDDeviceGetValueOptions.withoutUpdate.rawValue)
            if result == kIOReturnSuccess {
                if IOHIDValueGetIntegerValue(value.pointee.takeUnretainedValue()) == 0 {
                    cachedUp += 1
                } else { cachedDown += 1 }
            } else { readErrors += 1 }
        }
        let lastAge = lastCallback.map { Int((now - $0) * 1000) } ?? -1
        Diagnostics.log("hid.snapshot reason=\(reason) connected=\(connectedDevices.count) callbacks=\(callbackCount) errors=\(callbackErrors) lastCallbackAgeMs=\(lastAge) keyDowns=\(keyDownCount) keyUps=\(keyUpCount) duplicateDowns=\(duplicateDownCount) unmatchedUps=\(unmatchedUpCount) heldKeys=\(heldKeys.count) oldestHeldMs=\(oldestMs) cachedDown=\(cachedDown) cachedUp=\(cachedUp) readErrors=\(readErrors)")
    }
    /// Remove only keys that IOKit confirms are released. Read errors stay blocked.
    func reconcile() {
        var released = [String]()
        for (identity, detail) in heldDetails {
            let value = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
            defer { value.deallocate() }
            let result = IOHIDDeviceGetValueWithOptions(IOHIDElementGetDevice(detail.element),
                detail.element, value, IOHIDDeviceGetValueOptions.withoutUpdate.rawValue)
            if result == kIOReturnSuccess && IOHIDValueGetIntegerValue(value.pointee.takeUnretainedValue()) == 0 {
                released.append(identity)
            }
        }
        for identity in released { heldKeys.remove(identity); heldDetails.removeValue(forKey: identity) }
        if !released.isEmpty { Diagnostics.log("hid.reconcile released=\(released.count) remaining=\(heldKeys.count)") }
    }

    var heldKeyCount: Int { heldKeys.count }
    var keyStateAgeMs: Int {
        guard let lastKeyStateChange else { return -1 }
        return Int((ProcessInfo.processInfo.systemUptime - lastKeyStateChange) * 1000)
    }
    var hasOtherKeysDown: Bool { !heldKeys.isEmpty }
    var onDeviceRemoved: ((UInt64) -> Void)?
    var onOtherKey: (() -> Void)?
    var onState: ((UInt64, Bool) -> Void)?

    func start() {
        let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = hid
        IOHIDManagerSetDeviceMatching(hid, nil)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(hid, { context, result, _, device in
            guard let context else { return }
            Unmanaged<FnHIDMonitor>.fromOpaque(context).takeUnretainedValue()
                .deviceEvent(device, added: true, result: result)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(hid, { context, result, _, device in
            guard let context else { return }
            Unmanaged<FnHIDMonitor>.fromOpaque(context).takeUnretainedValue()
                .deviceEvent(device, added: false, result: result)
        }, context)
        let matches: [[String: Int]] = [
            [kIOHIDElementUsagePageKey: 0x07],
            [kIOHIDElementUsagePageKey: 0xFF, kIOHIDElementUsageKey: 3],
            [kIOHIDElementUsagePageKey: 0xFF01, kIOHIDElementUsageKey: 3],
            [kIOHIDElementUsagePageKey: 0x0C, kIOHIDElementUsageKey: 0x029D],
        ]
        IOHIDManagerSetInputValueMatchingMultiple(hid, matches as CFArray)
        IOHIDManagerRegisterInputValueCallback(hid, { context, result, _, value in
            guard let context else { return }
            let owner = Unmanaged<FnHIDMonitor>.fromOpaque(context).takeUnretainedValue()
            owner.callbackCount += 1
            owner.lastCallback = ProcessInfo.processInfo.systemUptime
            guard result == kIOReturnSuccess else {
                owner.callbackErrors += 1
                Diagnostics.log("hid.callback.error result=\(result)")
                return
            }
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let device = IOHIDElementGetDevice(element)
            // Registry identity prevents two keyboards from corrupting each other's press state.
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
            let down = IOHIDValueGetIntegerValue(value) != 0
            if page == 0x07 {
                // Ignore HID error/rollover values; retain only temporary pressed-state identity.
                guard usage > 3 else { return }
                let identity = "\(id):\(IOHIDElementGetCookie(element))"
                owner.lastKeyStateChange = ProcessInfo.processInfo.systemUptime
                if down {
                    owner.keyDownCount += 1
                    if owner.heldKeys.insert(identity).inserted {
                        owner.heldDetails[identity] = HeldKey(element: element, since: ProcessInfo.processInfo.systemUptime)
                    } else { owner.duplicateDownCount += 1 }
                    owner.onOtherKey?()
                } else {
                    owner.keyUpCount += 1
                    if owner.heldKeys.remove(identity) == nil { owner.unmatchedUpCount += 1 }
                    owner.heldDetails.removeValue(forKey: identity)
                }
                return
            }
            guard (page == 0xFF && usage == 3) || (page == 0xFF01 && usage == 3)
                || (page == 0x0C && usage == 0x029D) else { return }
            Diagnostics.log("hid.fn.source alias=\(owner.alias(for: id)) page=\(page) usage=\(usage)")
            owner.onState?(id, down)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        Diagnostics.log("hid.open result=\(result) inputMonitoring=\(CGPreflightListenEventAccess())")
    }

    func stop() {
        if let hid = manager {
            IOHIDManagerUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        heldKeys.removeAll()
        heldDetails.removeAll()
        connectedDevices.removeAll()
    }
    deinit { stop() }
}

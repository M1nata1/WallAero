import AppKit
import IOKit.ps

struct DisplayInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

extension NSScreen {
    var displayNumber: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Identifies the physical display across reconnections and reboots, unlike the display number.
    var stableID: String {
        if let number = displayNumber, let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return localizedName
    }
}

/// Battery state, read through IOKit because AppKit has no notification for it.
enum PowerSource {
    static let didChangeNotification = Notification.Name("WallAeroEnginePowerSourceDidChange")

    private static var runLoopSource: CFRunLoopSource?

    static var isOnBattery: Bool {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else {
            return false
        }
        return (type as String) == kIOPSBatteryPowerValue
    }

    /// Posts `didChangeNotification` on the main thread whenever the power source changes.
    static func startMonitoring() {
        guard runLoopSource == nil else { return }
        let callback: IOPowerSourceCallbackType = { _ in
            NotificationCenter.default.post(name: PowerSource.didChangeNotification, object: nil)
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }
}

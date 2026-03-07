#if canImport(UIKit)
import UIKit
import Foundation

final class DeviceSignalCollector: @unchecked Sendable {

    func collect(appAttestToken: String? = nil) -> IOSIntegritySignals {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true

        let screen = UIScreen.main
        let screenRes = "\(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height))"

        let batteryInfo: BatteryInfo?
        if device.batteryState != .unknown {
            let stateStr: String
            switch device.batteryState {
            case .unplugged: stateStr = "unplugged"
            case .charging: stateStr = "charging"
            case .full: stateStr = "full"
            default: stateStr = "unknown"
            }
            batteryInfo = BatteryInfo(level: device.batteryLevel, state: stateStr)
        } else {
            batteryInfo = nil
        }

        return IOSIntegritySignals(
            isSimulator: isRunningOnSimulator(),
            isJailbroken: checkJailbroken(),
            isDebuggerAttached: checkDebugger(),
            appAttestToken: appAttestToken,
            bundleId: Bundle.main.bundleIdentifier ?? "unknown",
            deviceModel: deviceModelIdentifier(),
            osVersion: device.systemVersion,
            screenResolution: screenRes,
            processorCount: ProcessInfo.processInfo.processorCount,
            physicalMemoryMB: Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)),
            battery: batteryInfo,
            connection: ConnectionInfo(type: "unknown"),
            timezone: TimeZone.current.identifier,
            locale: Locale.current.identifier
        )
    }

    private func isRunningOnSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private func checkJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let paths = [
            "/Applications/Cydia.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/bin/bash",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/private/var/lib/apt/"
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) { return true }
        }
        if let _ = try? String(contentsOfFile: "/private/jailbreak.txt", encoding: .utf8) { return true }
        return false
        #endif
    }

    private func checkDebugger() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    private func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }
}
#endif

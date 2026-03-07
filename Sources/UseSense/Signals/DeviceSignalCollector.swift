#if canImport(UIKit)
import Foundation
import UIKit
#if canImport(CoreMotion)
import CoreMotion
#endif

final class DeviceSignalCollector: @unchecked Sendable {
    #if canImport(CoreMotion)
    private let motionManager = CMMotionManager()
    #endif
    private var accelerometerSamples: [[String: Any]] = []
    private var gyroscopeSamples: [[String: Any]] = []
    private var captureStartTime: Date?
    private let sampleQueue = OperationQueue()

    init() {
        sampleQueue.maxConcurrentOperationCount = 1
    }

    func startSensorCapture() {
        captureStartTime = Date()
        accelerometerSamples = []
        gyroscopeSamples = []

        #if canImport(CoreMotion)
        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 0.5
            motionManager.startAccelerometerUpdates(to: sampleQueue) { [weak self] data, _ in
                guard let self = self, let data = data, let start = self.captureStartTime else { return }
                let t = Int(Date().timeIntervalSince(start) * 1000)
                self.accelerometerSamples.append([
                    "t": t,
                    "x": round(data.acceleration.x * 1000) / 1000,
                    "y": round(data.acceleration.y * 1000) / 1000,
                    "z": round(data.acceleration.z * 1000) / 1000
                ])
            }
        }

        if motionManager.isGyroAvailable {
            motionManager.gyroUpdateInterval = 0.5
            motionManager.startGyroUpdates(to: sampleQueue) { [weak self] data, _ in
                guard let self = self, let data = data, let start = self.captureStartTime else { return }
                let t = Int(Date().timeIntervalSince(start) * 1000)
                self.gyroscopeSamples.append([
                    "t": t,
                    "x": round(data.rotationRate.x * 10000) / 10000,
                    "y": round(data.rotationRate.y * 10000) / 10000,
                    "z": round(data.rotationRate.z * 10000) / 10000
                ])
            }
        }
        #endif
    }

    func stopSensorCapture() {
        #if canImport(CoreMotion)
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        #endif
    }

    func collectSignals() -> [String: Any] {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true

        let screen = UIScreen.main
        var signals: [String: Any] = [
            "platform": "ios",
            "sdk_version": UseSense.sdkVersion,
            "device_model": deviceModel(),
            "device_manufacturer": "Apple",
            "os_version": "iOS \(device.systemVersion)",
            "system_version": device.systemVersion,
            "screen_width": Int(screen.nativeBounds.width),
            "screen_height": Int(screen.nativeBounds.height),
            "screen_scale": screen.nativeScale,
            "camera_facing": "front",
            "camera_resolution": "640x480",
            "battery_level": device.batteryLevel,
            "battery_charging": device.batteryState == .charging || device.batteryState == .full,
            "battery_state": batteryStateString(device.batteryState),
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "timezone_offset": TimeZone.current.secondsFromGMT() / 60,
            "app_bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "is_simulator": Self.isSimulator(),
            "is_jailbroken": Self.isJailbroken(),
            "is_debugger_attached": Self.isDebuggerAttached(),
            "camera_permission_granted": true,
            "hardware_model": hardwareModel(),
            "cpu_architecture": cpuArchitecture(),
            "total_ram_mb": ProcessInfo.processInfo.physicalMemory / (1024 * 1024),
            "uptime_seconds": Int(ProcessInfo.processInfo.systemUptime)
        ]

        if !accelerometerSamples.isEmpty {
            signals["accelerometer_data"] = accelerometerSamples
        }
        if !gyroscopeSamples.isEmpty {
            signals["gyroscope_data"] = gyroscopeSamples
        }

        return signals
    }

    func collectDeviceTelemetry() -> [String: Any] {
        var telemetry: [String: Any] = [
            "cpu_type": cpuArchitecture(),
            "processor_count": ProcessInfo.processInfo.processorCount,
            "active_processor_count": ProcessInfo.processInfo.activeProcessorCount,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled
        ]

        let thermalState: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalState = "nominal"
        case .fair: thermalState = "fair"
        case .serious: thermalState = "serious"
        case .critical: thermalState = "critical"
        @unknown default: thermalState = "unknown"
        }
        telemetry["thermal_state"] = thermalState

        return telemetry
    }

    // MARK: - Simulator Detection

    static func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        #endif
    }

    // MARK: - Jailbreak Detection

    static func isJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let jailbreakPaths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/bin/bash",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/usr/bin/ssh",
            "/private/var/lib/apt/",
            "/private/var/lib/cydia",
            "/private/var/mobile/Library/SBSettings/Themes",
            "/private/var/stash",
            "/var/cache/apt",
            "/var/lib/cydia"
        ]

        for path in jailbreakPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }

        let testPath = "/private/jailbreak_test_\(UUID().uuidString)"
        do {
            try "test".write(toFile: testPath, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(atPath: testPath)
            return true
        } catch {
            // Expected on non-jailbroken device
        }

        if let url = URL(string: "cydia://package/com.example.package"),
           UIApplication.shared.canOpenURL(url) {
            return true
        }

        return false
        #endif
    }

    // MARK: - Debugger Detection

    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    // MARK: - Helpers

    private func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private func hardwareModel() -> String {
        deviceModel()
    }

    private func cpuArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func batteryStateString(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unknown"
        }
    }
}
#endif

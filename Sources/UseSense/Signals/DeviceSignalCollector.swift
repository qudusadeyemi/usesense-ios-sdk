#if canImport(UIKit)
import UIKit
import Foundation
import CoreMotion
import AVFoundation
import Network

struct SensorSample: Codable, Sendable {
    let t: Int64  // ms since sensor start
    let x: Double
    let y: Double
    let z: Double
}

final class DeviceSignalCollector: @unchecked Sendable {

    private let motionManager = CMMotionManager()
    private var accelerometerData: [SensorSample] = []
    private var gyroscopeData: [SensorSample] = []
    private var sensorStartTime: Date?
    private let lock = NSLock()
    private let maxSamples = 20
    private let sampleInterval: TimeInterval = 0.5 // ~2Hz

    private var cameraFacing: String = "front"
    private var cameraResolution: String = "1280x720"

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.usesense.network-monitor")
    private var resolvedNetworkType: String = "unknown"

    func setCaptureInfo(facing: String, resolution: String) {
        cameraFacing = facing
        cameraResolution = resolution
    }

    // MARK: - Sensor Collection

    func startSensorCollection() {
        lock.lock()
        accelerometerData.removeAll()
        gyroscopeData.removeAll()
        sensorStartTime = Date()
        lock.unlock()

        startNetworkMonitor()

        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = sampleInterval
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.accelerometerData.count < self.maxSamples else { return }
                let t = Int64((Date().timeIntervalSince(self.sensorStartTime ?? Date())) * 1000)
                self.accelerometerData.append(SensorSample(
                    t: t, x: data.acceleration.x, y: data.acceleration.y, z: data.acceleration.z
                ))
            }
        }

        if motionManager.isGyroAvailable {
            motionManager.gyroUpdateInterval = sampleInterval
            motionManager.startGyroUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.gyroscopeData.count < self.maxSamples else { return }
                let t = Int64((Date().timeIntervalSince(self.sensorStartTime ?? Date())) * 1000)
                self.gyroscopeData.append(SensorSample(
                    t: t, x: data.rotationRate.x, y: data.rotationRate.y, z: data.rotationRate.z
                ))
            }
        }
    }

    func stopSensorCollection() {
        if motionManager.isAccelerometerActive { motionManager.stopAccelerometerUpdates() }
        if motionManager.isGyroActive { motionManager.stopGyroUpdates() }
        pathMonitor.cancel()
    }

    // MARK: - Channel Integrity Signals

    /// Collect all channel integrity signals for the server's DeepSense scorer.
    /// Maps to the `channel_integrity` object in the metadata payload.
    func collectChannelIntegrity(attestFields: [String: Any] = [:]) -> [String: Any] {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true

        let screen = UIScreen.main
        var signals: [String: Any] = [:]

        // Platform
        signals["platform"] = "ios"
        signals["channel_type"] = "ios"
        signals["sdk_version"] = UseSenseAPIClient.sdkVersion

        // Device info
        signals["device_model"] = deviceModelIdentifier()
        signals["device_manufacturer"] = "Apple"
        signals["os_version"] = "iOS \(device.systemVersion)"
        signals["device_name"] = device.name

        // Screen
        signals["screen_width"] = Int(screen.nativeBounds.width)
        signals["screen_height"] = Int(screen.nativeBounds.height)
        signals["screen_density"] = Int(screen.scale)

        // Camera
        signals["camera_facing"] = cameraFacing
        signals["camera_resolution"] = cameraResolution

        // Battery
        if device.batteryState != .unknown {
            signals["battery_level"] = device.batteryLevel
            signals["battery_charging"] = device.batteryState == .charging || device.batteryState == .full
        }

        // Network
        lock.lock()
        let networkType = resolvedNetworkType
        lock.unlock()
        signals["network_type"] = networkType

        // Locale/timezone
        signals["locale"] = Locale.current.identifier
        signals["timezone"] = TimeZone.current.identifier
        signals["timezone_offset"] = TimeZone.current.secondsFromGMT() / 60

        // App info
        signals["app_package"] = Bundle.main.bundleIdentifier ?? "unknown"

        // Device integrity
        signals["is_simulator"] = isRunningOnSimulator()
        signals["is_jailbroken"] = checkJailbroken()
        signals["is_debugger_attached"] = checkDebugger()

        // App Attest fields (attestation + assertion + key_id + nonce_used)
        for (key, value) in attestFields {
            signals[key] = value
        }

        // Permissions
        signals["camera_permission_granted"] = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        signals["microphone_permission_granted"] = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        // Uptime
        signals["uptime_ms"] = Int64(ProcessInfo.processInfo.systemUptime * 1000)

        // Sensor data
        lock.lock()
        let accelData = accelerometerData
        let gyroData = gyroscopeData
        lock.unlock()

        signals["accelerometer_data"] = accelData.map { ["t": $0.t, "x": $0.x, "y": $0.y, "z": $0.z] }
        signals["gyroscope_data"] = gyroData.map { ["t": $0.t, "x": $0.x, "y": $0.y, "z": $0.z] }

        return signals
    }

    /// Collect device telemetry (supplementary hardware info).
    func collectDeviceTelemetry() -> [String: Any] {
        var telemetry: [String: Any] = [:]

        #if arch(arm64)
        telemetry["cpu_abi"] = "arm64"
        #elseif arch(x86_64)
        telemetry["cpu_abi"] = "x86_64"
        #else
        telemetry["cpu_abi"] = "unknown"
        #endif

        telemetry["processor_count"] = ProcessInfo.processInfo.processorCount
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        telemetry["total_ram_mb"] = Int(totalRAM / (1024 * 1024))
        telemetry["available_ram_mb"] = Int(os_proc_available_memory() / (1024 * 1024))

        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSize = attrs[.systemFreeSize] as? Int64 {
            telemetry["storage_available_mb"] = Int(freeSize / (1024 * 1024))
        }

        telemetry["os_build"] = ProcessInfo.processInfo.operatingSystemVersionString

        return telemetry
    }

    func release() {
        stopSensorCollection()
        lock.lock()
        accelerometerData.removeAll()
        gyroscopeData.removeAll()
        lock.unlock()
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let type: String
            if path.status != .satisfied {
                type = "none"
            } else if path.usesInterfaceType(.wifi) {
                type = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                type = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                type = "ethernet"
            } else if path.usesInterfaceType(.loopback) {
                type = "loopback"
            } else if path.usesInterfaceType(.other) {
                type = "other"
            } else {
                type = "unknown"
            }
            self.lock.lock()
            self.resolvedNetworkType = type
            self.lock.unlock()
        }
        pathMonitor.start(queue: monitorQueue)
    }

    // MARK: - Device Integrity Checks

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

//
//  LocationFixer.swift
//  UseSense
//
//  CoreLocation wrapper for address capture. Everything decidable without a
//  device lives in LocationCapture.swift; this file is the IO.
//
//  Foreground only. `requestWhenInUseAuthorization` is the only authorization
//  this ever asks for, and nothing here requests `authorizedAlways`. The
//  location capture contract covers foreground capture; passive home inference
//  is a separate, separately consented instrument and will get its own surface.
//

import Foundation
#if canImport(CoreLocation)
import CoreLocation

/// Acquires a single position fix, then stops.
///
/// Every failure path resolves rather than throwing, because the caller must
/// submit either way: a denied permission still advances the step with the
/// descriptors alone. There is no error case to propagate, only a state to
/// report.
final class LocationFixer: NSObject, CLLocationManagerDelegate {

    /// Called exactly once, on the main queue, with whatever we ended up with.
    private var completion: ((LocationFix?, LocationCaptureState) -> Void)?
    private let manager: CLLocationManager
    private var timeoutWork: DispatchWorkItem?
    private var finished = false

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        // Ten metres is plenty. The dwelling-level question we are answering
        // sits well above the accuracy consumer hardware can deliver, and
        // asking for best-for-navigation only drains battery and time.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Starts acquisition. `timeoutMs` bounds the whole attempt, including the
    /// permission prompt, so a subject who ignores the dialog is not stuck.
    func start(timeoutMs: Int, completion: @escaping (LocationFix?, LocationCaptureState) -> Void) {
        self.completion = completion

        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = manager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }

        guard CLLocationManager.locationServicesEnabled() else {
            finish(nil, .unavailable)
            return
        }

        switch status {
        case .denied, .restricted:
            // Do not re-prompt. iOS will not show the dialog again anyway, and
            // pretending otherwise wastes the subject's time.
            finish(nil, .denied)
            return
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }

        let work = DispatchWorkItem { [weak self] in
            // Timed out. Whatever the reason, the subject continues without a
            // position rather than being held here.
            self?.finish(nil, .unavailable)
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: work)

        manager.requestLocation()
    }

    func cancel() {
        finish(nil, .unavailable)
    }

    private func finish(_ fix: LocationFix?, _ state: LocationCaptureState) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        timeoutWork = nil
        manager.stopUpdatingLocation()
        let done = completion
        completion = nil
        DispatchQueue.main.async { done?(fix, state) }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let best = locations.last else {
            finish(nil, .unavailable)
            return
        }
        // A negative horizontalAccuracy is CoreLocation's way of saying the
        // coordinate is invalid, and it is easy to miss because the reading
        // still carries plausible-looking numbers.
        guard let fix = LocationCapture.fix(from: best, attested: false) else {
            finish(nil, .unavailable)
            return
        }
        finish(fix, .ready)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as NSError).code == CLError.denied.rawValue
        finish(nil, denied ? .denied : .unavailable)
    }

    @available(iOS 14.0, *)
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            finish(nil, .denied)
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }
}
#endif

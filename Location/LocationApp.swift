import CoreLocation
import Foundation
import ObjCInterop
import SwiftUI

// Where the device is, from Core Location: position, accuracy, altitude,
// speed and course as they update, and the compass heading where there's a
// magnetometer. Everything goes through the CoreLocation module generated
// from the SDK's headers, with the delegate written in Swift.

@main
struct LocationApp: App {
    let store = LocationStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                LocationView()
            }
            .environmentObject(store)
        }
    }
}

struct Fact: Identifiable, Equatable {
    let id: String
    let value: String
}

final class LocationStore: ObservableObject {
    let manager = CLLocationManager()
    /// The Objective-C delegate, which the manager doesn't retain.
    let delegate: ObjCValue

    @Published var isUpdating = false
    @Published var authorization = CLLocationManager.authorizationStatus()
    @Published var location: CLLocation?
    @Published var heading: CLHeading?
    @Published var updates = 0
    @Published var error: String?

    init() {
        let bridge = LocationDelegate()
        delegate = LocationDelegate.objcClass.new()
        bridge.attach(to: delegate)
        bridge.store = self
        manager.delegate = delegate
        manager.desiredAccuracy = -1  // kCLLocationAccuracyBest
        manager.purpose = "Shows where this device is."
    }

    func setUpdating(_ on: Bool) {
        if on {
            error = nil
            manager.startUpdatingLocation()
            if manager.headingAvailable { manager.startUpdatingHeading() }
        } else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
        }
        isUpdating = on
    }

    var facts: [Fact] {
        var facts = [Fact(id: "Location services", value: manager.locationServicesEnabled ? "On" : "Off"),
                     Fact(id: "Permission", value: authorizationName(authorization))]
        if let location {
            let coordinate = location.coordinate
            facts += [
                Fact(id: "Latitude", value: degrees(coordinate.latitude, positive: "N", negative: "S")),
                Fact(id: "Longitude", value: degrees(coordinate.longitude, positive: "E", negative: "W")),
                Fact(id: "Accuracy", value: location.horizontalAccuracy < 0 ? "Unknown" : "± \(fixed(location.horizontalAccuracy, 0)) m"),
                Fact(id: "Altitude", value: location.verticalAccuracy < 0 ? "Unknown"
                     : "\(fixed(location.altitude, 0)) m (± \(fixed(location.verticalAccuracy, 0)) m)"),
                Fact(id: "Speed", value: location.speed < 0 ? "Unknown" : "\(fixed(location.speed * 3.6, 1)) km/h"),
                Fact(id: "Course", value: location.course < 0 ? "Unknown" : "\(fixed(location.course, 0))°"),
                Fact(id: "Updates", value: "\(updates)"),
            ]
        } else if isUpdating {
            facts.append(Fact(id: "Position", value: "Locating…"))
        }
        if let heading {
            facts.append(Fact(id: "Heading", value: "\(fixed(heading.magneticHeading, 0))° magnetic"))
        } else {
            facts.append(Fact(id: "Compass", value: manager.headingAvailable ? (isUpdating ? "Waiting…" : "Off") : "Not available"))
        }
        if let error { facts.append(Fact(id: "Error", value: error)) }
        return facts
    }
}

/// The CLLocationManagerDelegate, implemented in Swift. The types are given
/// by the Swift signatures (the runtime may not know the protocol).
@ObjCImplementation("SwiftLocationDelegate")
final class LocationDelegate {
    var store: LocationStore?

    init() {}

    /// iOS 6 and later: the newest location is last.
    @ObjCMethod("locationManager:didUpdateLocations:")
    func didUpdateLocations(_ manager: ObjCValue, locations: NSArray) {
        guard let store, locations.count > 0 else { return }
        store.location = CLLocation(locations.objectAtIndex(locations.count - 1))
        store.updates += 1
    }

    @ObjCMethod("locationManager:didUpdateHeading:")
    func didUpdateHeading(_ manager: ObjCValue, heading: CLHeading) {
        store?.heading = heading
    }

    @ObjCMethod("locationManager:didFailWithError:")
    func didFail(_ manager: ObjCValue, error: NSError) {
        // kCLErrorLocationUnknown (0) is temporary: Core Location keeps trying.
        guard error.code != 0 else { return }
        store?.error = error.code == 1 ? "Permission denied" : "Error \(error.code)"
    }

    @ObjCMethod("locationManager:didChangeAuthorizationStatus:")
    func didChangeAuthorization(_ manager: ObjCValue, status: Int) {
        store?.authorization = status
    }
}

struct LocationView: View {
    @EnvironmentObject var store: LocationStore

    var body: some View {
        List {
            Toggle("Update location", isOn: Binding(get: { store.isUpdating }, set: { store.setUpdating($0) }))
            ForEach(store.facts) { fact in
                HStack {
                    Text(fact.id)
                    Spacer()
                    Text(fact.value)
                        .foregroundColor(.gray)
                }
            }
        }
        .navigationTitle("Location")
    }
}

func authorizationName(_ status: Int) -> String {
    switch status {
    case 0: return "Not asked yet"
    case 1: return "Restricted"
    case 2: return "Denied"
    case 3: return "Allowed"
    default: return "Unknown (\(status))"
    }
}

/// 40.7128° N, from a signed value in degrees.
func degrees(_ value: Double, positive: String, negative: String) -> String {
    "\(fixed(value < 0 ? -value : value, 5))° \(value < 0 ? negative : positive)"
}

/// A number with a fixed number of decimal places. (Embedded Swift doesn't
/// print floating-point numbers.)
func fixed(_ value: Double, _ places: Int) -> String {
    var scale = 1.0
    for _ in 0..<places { scale *= 10 }
    let negative = value < 0
    let scaled = Int64((negative ? -value : value) * scale + 0.5)
    let whole = scaled / Int64(scale)
    var text = "\(negative && scaled > 0 ? "-" : "")\(whole)"
    if places > 0 {
        var fraction = "\(scaled % Int64(scale))"
        while fraction.utf8.count < places { fraction = "0" + fraction }
        text += "." + fraction
    }
    return text
}

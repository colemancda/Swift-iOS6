import CoreMotion
import Foundation
import ObjCInterop
import SwiftUI

// The device's motion from Core Motion: attitude (roll, pitch, yaw), gravity,
// the user's acceleration and the rotation rate, from the accelerometer and
// gyroscope. Updates arrive through a block on the main queue: the handler is
// a Swift closure, which the generated CoreMotion module wraps in an
// Objective-C block.

@main
struct MotionApp: App {
    let store = MotionStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                MotionView()
            }
            .environmentObject(store)
        }
    }
}

struct Vector: Equatable {
    var x = 0.0
    var y = 0.0
    var z = 0.0
}

final class MotionStore: ObservableObject {
    let manager = CMMotionManager()

    @Published var isRunning = false
    @Published var usesDeviceMotion = false
    @Published var roll = 0.0
    @Published var pitch = 0.0
    @Published var yaw = 0.0
    @Published var gravity = Vector()
    @Published var acceleration = Vector()
    @Published var rotation = Vector()
    @Published var updates = 0
    @Published var error: String?

    /// Updates per second, measured.
    @Published var rate = 0
    var windowStart = 0.0
    var windowCount = 0

    func setRunning(_ on: Bool) {
        if on {
            error = nil
            updates = 0
            windowStart = NSDate.date().timeIntervalSinceReferenceDate
            windowCount = 0
            let queue = NSOperationQueue.mainQueue()
            if manager.deviceMotionAvailable {
                // Attitude, gravity and user acceleration, fusing the gyroscope and accelerometer.
                usesDeviceMotion = true
                manager.deviceMotionUpdateInterval = 0.2  // 5 per second: each update renders the list
                // The store lives as long as the app, so the handler can hold it.
                manager.startDeviceMotionUpdatesToQueue(queue) { motion, error in
                    self.received(motion, error)
                }
            } else if manager.accelerometerAvailable {
                usesDeviceMotion = false
                manager.accelerometerUpdateInterval = 0.2
                manager.startAccelerometerUpdatesToQueue(queue) { data, error in
                    if let data {
                        let a = data.acceleration
                        self.gravity = Vector(x: a.x, y: a.y, z: a.z)
                        self.counted()
                    }
                    if let error { self.error = "Error \(error.code)" }
                }
            } else {
                error = "No accelerometer"
                return
            }
        } else {
            manager.stopDeviceMotionUpdates()
            manager.stopAccelerometerUpdates()
        }
        isRunning = on
    }

    func received(_ motion: CMDeviceMotion?, _ failure: NSError?) {
        if let failure { error = "Error \(failure.code)" }
        guard let motion else { return }
        let attitude = motion.attitude
        roll = attitude.roll
        pitch = attitude.pitch
        yaw = attitude.yaw
        let g = motion.gravity, a = motion.userAcceleration, r = motion.rotationRate
        gravity = Vector(x: g.x, y: g.y, z: g.z)
        acceleration = Vector(x: a.x, y: a.y, z: a.z)
        rotation = Vector(x: r.x, y: r.y, z: r.z)
        counted()
    }

    func counted() {
        updates += 1
        windowCount += 1
        let now = NSDate.date().timeIntervalSinceReferenceDate
        if now - windowStart >= 1 {
            rate = Int(Double(windowCount) / (now - windowStart) + 0.5)
            windowStart = now
            windowCount = 0
        }
    }
}

struct MotionView: View {
    @EnvironmentObject var store: MotionStore

    var body: some View {
        List {
            Toggle("Measure motion", isOn: Binding(get: { store.isRunning }, set: { store.setRunning($0) }))
            Fact(name: "Sensors", value: sensors(store.manager))
            if let error = store.error {
                Text(error)
                    .foregroundColor(.red)
            }
            if store.isRunning || store.updates > 0 {
                Fact(name: "Updates", value: "\(store.updates) (\(store.rate) per second)")
                if store.usesDeviceMotion {
                    Meter(name: "Roll", value: store.roll, limit: 3.1416, text: angle(store.roll))
                    Meter(name: "Pitch", value: store.pitch, limit: 1.5708, text: angle(store.pitch))
                    Meter(name: "Yaw", value: store.yaw, limit: 3.1416, text: angle(store.yaw))
                }
                Meter(name: "Gravity x", value: store.gravity.x, limit: 1, text: "\(fixed(store.gravity.x, 2)) g")
                Meter(name: "Gravity y", value: store.gravity.y, limit: 1, text: "\(fixed(store.gravity.y, 2)) g")
                Meter(name: "Gravity z", value: store.gravity.z, limit: 1, text: "\(fixed(store.gravity.z, 2)) g")
                if store.usesDeviceMotion {
                    Fact(name: "Acceleration", value: vector(store.acceleration, "g"))
                    Fact(name: "Rotation", value: vector(store.rotation, "rad/s"))
                }
            }
        }
        .navigationTitle("Motion")
    }
}

struct Fact: View {
    let name: String
    let value: String

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(value)
                .foregroundColor(.gray)
        }
    }
}

/// A value from -limit to limit as a bar from the middle, with its text.
struct Meter: View {
    let name: String
    let value: Double
    let limit: Double
    let text: String

    var body: some View {
        let half = 60.0
        let length = min(half, max(-half, value / limit * half))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text(text)
                    .foregroundColor(.gray)
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: half + min(0, length), height: 6)
                Color.blue.frame(width: max(1, length < 0 ? -length : length), height: 6)
                Color.clear.frame(width: half - max(0, length), height: 6)
                Spacer()
            }
        }
    }
}

func sensors(_ manager: CMMotionManager) -> String {
    var names: [String] = []
    if manager.accelerometerAvailable { names.append("accelerometer") }
    if manager.gyroAvailable { names.append("gyroscope") }
    if manager.magnetometerAvailable { names.append("magnetometer") }
    return names.isEmpty ? "None" : names.joined(separator: ", ")
}

func angle(_ radians: Double) -> String {
    "\(fixed(radians * 180 / 3.14159265, 0))°"
}

func vector(_ v: Vector, _ unit: String) -> String {
    "\(fixed(v.x, 2)), \(fixed(v.y, 2)), \(fixed(v.z, 2)) \(unit)"
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

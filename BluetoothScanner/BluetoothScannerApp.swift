import CBluetooth
import SwiftUI

// A Bluetooth Classic scanner for iOS 6: lists paired devices and every
// discoverable device nearby (phones and computers included, which Settings
// hides), with a switch to turn Bluetooth on or off and a detail screen per
// device.

@main
struct BluetoothScannerApp: App {
    let store = BluetoothStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                DeviceList()
            }
            .environmentObject(store)
        }
    }
}

struct Device: Identifiable, Equatable {
    let id: String
    let name: String
    let majorClass: Int
    let minorClass: Int
    let isPaired: Bool
    let isConnected: Bool
    let isNearby: Bool

    var displayName: String { name.isEmpty ? id : name }

    var type: String {
        switch majorClass {
        case Int(BTMajorClassComputer): return "Computer"
        case Int(BTMajorClassPhone): return "Phone"
        case Int(BTMajorClassNetwork): return "Network"
        case Int(BTMajorClassAudioVideo): return "Audio"
        case Int(BTMajorClassPeripheral): return "Peripheral"
        case Int(BTMajorClassImaging): return "Imaging"
        case Int(BTMajorClassWearable): return "Wearable"
        case Int(BTMajorClassToy): return "Toy"
        case Int(BTMajorClassHealth): return "Health"
        default: return "Other"
        }
    }

    /// The minor class, for the major classes people meet most.
    var kind: String? {
        switch (majorClass, minorClass) {
        case (Int(BTMajorClassComputer), 0x04): return "Desktop"
        case (Int(BTMajorClassComputer), 0x08): return "Server"
        case (Int(BTMajorClassComputer), 0x0C): return "Laptop"
        case (Int(BTMajorClassComputer), 0x10), (Int(BTMajorClassComputer), 0x14): return "Handheld"
        case (Int(BTMajorClassComputer), 0x1C): return "Tablet"
        case (Int(BTMajorClassPhone), 0x04): return "Cell phone"
        case (Int(BTMajorClassPhone), 0x08): return "Cordless phone"
        case (Int(BTMajorClassPhone), 0x0C): return "Smartphone"
        case (Int(BTMajorClassPhone), 0x10): return "Modem"
        case (Int(BTMajorClassAudioVideo), 0x04): return "Headset"
        case (Int(BTMajorClassAudioVideo), 0x08): return "Hands-free"
        case (Int(BTMajorClassAudioVideo), 0x14): return "Speaker"
        case (Int(BTMajorClassAudioVideo), 0x18): return "Headphones"
        case (Int(BTMajorClassAudioVideo), 0x1C): return "Portable audio"
        case (Int(BTMajorClassAudioVideo), 0x20): return "Car audio"
        case (Int(BTMajorClassPeripheral), 0x40): return "Keyboard"
        case (Int(BTMajorClassPeripheral), 0x80): return "Mouse"
        case (Int(BTMajorClassPeripheral), 0xC0): return "Keyboard and mouse"
        case (Int(BTMajorClassPeripheral), 0x08): return "Game controller"
        default: return nil
        }
    }

    var description: String { kind ?? type }

    var state: String? {
        if isConnected { return "Connected" }
        if isPaired { return "Paired" }
        if !isNearby { return "Not nearby" }
        return nil
    }
}

final class BluetoothStore: ObservableObject {
    @Published var devices: [Device] = []
    @Published var isPowered = false
    @Published var status = "Starting Bluetooth…"

    private var isOpen = false

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = bt_open({ context, devices, count in
            let store = Unmanaged<BluetoothStore>.fromOpaque(context!).takeUnretainedValue()
            store.update(devices, count: count)
        }, context)
        isOpen = error == 0
        if isOpen {
            bt_set_scanning(1)
        } else {
            status = "BluetoothManager unavailable (error \(error))"
        }
    }

    func setPower(_ on: Bool) {
        guard isOpen, bt_is_available() != 0 else { return }
        bt_set_power(on ? 1 : 0)
        isPowered = on
    }

    /// Publishes only what changed: BTServer reports often (every discovery
    /// cycle), and each publish re-renders the screen.
    private func update(_ infos: UnsafePointer<BTDeviceInfo>?, count: Int) {
        var found: [Device] = []
        if let infos {
            for index in 0..<count {
                let info = infos[index]
                found.append(Device(
                    id: String(cString: info.address),
                    name: String(cString: info.name),
                    majorClass: info.majorClass,
                    minorClass: info.minorClass,
                    isPaired: info.paired != 0,
                    isConnected: info.connected != 0,
                    isNearby: info.nearby != 0
                ))
            }
        }
        let powered = bt_get_power() != 0
        let newStatus: String
        if bt_is_available() == 0 {
            newStatus = "Starting Bluetooth…"
        } else if !powered {
            newStatus = "Bluetooth is off"
        } else if found.isEmpty {
            newStatus = "Searching…"
        } else {
            newStatus = found.count == 1 ? "1 device" : "\(found.count) devices"
        }

        if found != devices { devices = found }
        if powered != isPowered { isPowered = powered }
        if newStatus != status { status = newStatus }
    }
}

struct DeviceList: View {
    @EnvironmentObject var store: BluetoothStore

    var body: some View {
        List {
            Toggle("Bluetooth", isOn: Binding(get: { store.isPowered }, set: { store.setPower($0) }))
            Text(store.status)
                .font(.subheadline)
                .foregroundColor(.gray)
            ForEach(store.devices) { device in
                NavigationLink(destination: DeviceDetail(device: device)) {
                    DeviceRow(device: device)
                }
            }
        }
        .navigationTitle("Bluetooth")
    }
}

struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.headline)
                Text("\(device.description) · \(device.id)")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            Spacer()
            if let state = device.state {
                Text(state)
                    .font(.subheadline)
                    .foregroundColor(device.isConnected ? .blue : .gray)
            }
        }
    }
}

struct DeviceDetail: View {
    let device: Device

    var body: some View {
        List {
            Text("Name: \(device.name.isEmpty ? "Unknown" : device.name)")
            Text("Address: \(device.id)")
            Text("Type: \(device.type)")
            if let kind = device.kind {
                Text("Kind: \(kind)")
            }
            Text("Class: major 0x\(hex(device.majorClass)), minor 0x\(hex(device.minorClass))")
            Text("Paired: \(device.isPaired ? "Yes" : "No")")
            Text("Connected: \(device.isConnected ? "Yes" : "No")")
            Text("Nearby: \(device.isNearby ? "Yes" : "No")")
        }
        .navigationTitle(device.displayName)
    }
}

/// Uppercase hexadecimal, such as 512 as "200".
func hex(_ value: Int) -> String {
    let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
    if value == 0 { return "0" }
    var result = ""
    var remaining = value
    while remaining > 0 {
        result = String(digits[remaining % 16]) + result
        remaining /= 16
    }
    return result
}

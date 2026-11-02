import CoreBluetooth
import Foundation
import ObjCInterop
import SwiftUI

// Scans for Bluetooth Low Energy devices with Core Bluetooth (iOS 5 and
// later): each device's name, signal strength and advertisement. Core
// Bluetooth needs Bluetooth 4.0 hardware, like the iPhone 4S's; on an iPod
// touch 4 (Bluetooth 2.1) it reports "Unsupported". Everything goes through
// the CoreBluetooth module generated from the SDK's headers, with the
// delegate written in Swift.

@main
struct BLEScannerApp: App {
    let store = ScannerStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                DeviceList()
            }
            .environmentObject(store)
        }
    }
}

struct Device: Identifiable {
    /// The CBPeripheral's address: Core Bluetooth keeps one object per device.
    let id: UInt
    var name: String
    var rssi: Int
    var advertisement: [Fact]
    var sightings: Int
}

struct Fact: Identifiable, Equatable {
    let id: String
    let value: String
}

final class ScannerStore: ObservableObject {
    /// The Objective-C delegate, which the manager doesn't retain.
    let delegate: ObjCValue
    let central: CBCentralManager

    @Published var state = 0
    @Published var isScanning = false
    @Published var devices: [Device] = []

    init() {
        let bridge = CentralDelegate()
        delegate = CentralDelegate.objcClass.new()
        bridge.attach(to: delegate)
        // The delegate is called on the main queue (queue nil).
        central = CBCentralManager(delegate: delegate, queue: nil)
        bridge.store = self
        state = central.state
    }

    func setScanning(_ on: Bool) {
        if on {
            // Report every advertisement, not just the first, so RSSI stays current.
            let options = NSMutableDictionary.dictionary()
            options.setObject(NSNumber.numberWithBool(true).object, forKey: ObjCValue("kCBScanOptionAllowDuplicates"))
            central.scanForPeripheralsWithServices(nil, options: options.as(NSDictionary.self))
        } else {
            central.stopScan()
        }
        isScanning = on
    }

    func discovered(_ peripheral: CBPeripheral, advertisement: NSDictionary, rssi: Int) {
        let id = UInt(bitPattern: peripheral.object.asObject?.pointer)
        let advertisedName = advertisement.objectForKey(ObjCValue("kCBAdvDataLocalName")).asString
        let name = peripheral.name ?? advertisedName ?? "Unnamed"
        var facts: [Fact] = []
        let keys = advertisement.allKeys
        for index in 0..<keys.count {
            let key = keys.objectAtIndex(index)
            let value = advertisement.objectForKey(key)
            let text = value.send("description").asString ?? "?"
            facts.append(Fact(id: shortKey(key.asString ?? "?"), value: text))
        }
        facts.sort { $0.id < $1.id }
        // RSSI 127 means "not available".
        let strength = rssi == 127 ? (devices.first { $0.id == id }?.rssi ?? 0) : rssi
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].name = name
            devices[index].rssi = strength
            devices[index].advertisement = facts
            devices[index].sightings += 1
        } else {
            devices.append(Device(id: id, name: name, rssi: strength, advertisement: facts, sightings: 1))
        }
        devices.sort { $0.rssi > $1.rssi }
    }
}

/// The CBCentralManagerDelegate, implemented in Swift.
@ObjCImplementation("SwiftCentralDelegate")
final class CentralDelegate {
    var store: ScannerStore?

    init() {}

    @ObjCMethod("centralManagerDidUpdateState:")
    func didUpdateState(_ central: CBCentralManager) {
        guard let store else { return }
        store.state = central.state
        if central.state != 5 { store.isScanning = false }
    }

    @ObjCMethod("centralManager:didDiscoverPeripheral:advertisementData:RSSI:")
    func didDiscover(_ central: ObjCValue, peripheral: CBPeripheral, advertisementData: NSDictionary, rssi: NSNumber) {
        store?.discovered(peripheral, advertisement: advertisementData, rssi: rssi.intValue)
    }
}

struct DeviceList: View {
    @EnvironmentObject var store: ScannerStore

    var body: some View {
        List {
            HStack {
                Text("Bluetooth")
                Spacer()
                Text(stateName(store.state))
                    .foregroundColor(.gray)
            }
            if store.state == 5 {
                Toggle("Scan", isOn: Binding(get: { store.isScanning }, set: { store.setScanning($0) }))
            }
            if store.state == 5 && store.isScanning && store.devices.isEmpty {
                Text("Looking for devices…")
                    .foregroundColor(.gray)
            }
            ForEach(store.devices) { device in
                NavigationLink(destination: DeviceDetail(device: device)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.headline)
                            Text(device.advertisement.isEmpty ? "No advertisement data"
                                 : "\(device.advertisement.count) advertised values")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Text("\(device.rssi) dBm")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .navigationTitle("BLE Scanner")
    }
}

struct DeviceDetail: View {
    let device: Device

    var body: some View {
        List {
            Fact(id: "Signal", value: "\(device.rssi) dBm").row
            Fact(id: "Advertisements", value: "\(device.sightings)").row
            ForEach(device.advertisement) { fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.id)
                        .font(.headline)
                    Text(fact.value)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }
        }
        .navigationTitle(device.name)
    }
}

extension Fact {
    var row: some View {
        HStack {
            Text(id)
            Spacer()
            Text(value)
                .foregroundColor(.gray)
        }
    }
}

/// CBCentralManagerState.
func stateName(_ state: Int) -> String {
    switch state {
    case 1: return "Resetting"
    case 2: return "Unsupported"
    case 3: return "Unauthorized"
    case 4: return "Off"
    case 5: return "On"
    default: return "Starting…"
    }
}

/// "Local name" for kCBAdvDataLocalName.
func shortKey(_ key: String) -> String {
    switch key {
    case "kCBAdvDataLocalName": return "Local name"
    case "kCBAdvDataManufacturerData": return "Manufacturer data"
    case "kCBAdvDataServiceUUIDs": return "Services"
    case "kCBAdvDataServiceData": return "Service data"
    case "kCBAdvDataTxPowerLevel": return "Transmit power"
    case "kCBAdvDataIsConnectable": return "Connectable"
    case "kCBAdvDataOverflowServiceUUIDs": return "Overflow services"
    case "kCBAdvDataSolicitedServiceUUIDs": return "Solicited services"
    case "kCBAdvDataChannel": return "Channel"
    default: return key
    }
}

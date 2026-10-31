import CWiFi
import SwiftUI

// A Wi-Fi scanner for iOS 6: lists nearby networks from MobileWiFi, strongest
// first, rescanning every few seconds, with a switch to turn Wi-Fi on or off
// and a detail screen per network.

@main
struct WiFiScannerApp: App {
    let store = WiFiStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                NetworkList()
            }
            .environmentObject(store)
        }
    }
}

struct Network: Identifiable {
    let id: String
    let ssid: String
    let rssi: Int
    let channel: Int
    let security: Int
    let isCurrent: Bool

    var name: String { ssid.isEmpty ? "Hidden network" : ssid }

    var securityName: String {
        switch security {
        case Int(WiFiSecurityWEP): return "WEP"
        case Int(WiFiSecurityWPA): return "WPA"
        case Int(WiFiSecurityEnterprise): return "WPA Enterprise"
        default: return "Open"
        }
    }

    var quality: String {
        if rssi >= -55 { return "Excellent" }
        if rssi >= -67 { return "Good" }
        if rssi >= -80 { return "Fair" }
        return "Weak"
    }

    var band: String { channel > 14 ? "5 GHz" : "2.4 GHz" }
}

final class WiFiStore: ObservableObject {
    @Published var networks: [Network] = []
    @Published var isPowered = false
    @Published var status = "Scanning…"

    private var isOpen = false
    private var isScanning = false

    init() {
        let error = wifi_open()
        isOpen = error == 0
        if isOpen {
            isPowered = wifi_get_power() != 0
        } else {
            status = "MobileWiFi unavailable (error \(error))"
        }
    }

    func setPower(_ on: Bool) {
        guard isOpen else { return }
        wifi_set_power(on ? 1 : 0)
        isPowered = on
        if on {
            status = "Scanning…"
        } else {
            networks = []
            status = "Wi-Fi is off"
        }
    }

    func scan() {
        guard isOpen, isPowered, !isScanning else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        let error = wifi_scan({ context, networks, count, error in
            let store = Unmanaged<WiFiStore>.fromOpaque(context!).takeRetainedValue()
            store.receive(networks, count: count, error: error)
        }, context)
        if error == 0 {
            isScanning = true
        } else {
            Unmanaged<WiFiStore>.fromOpaque(context).release()
        }
    }

    private func receive(_ results: UnsafePointer<WiFiNetworkInfo>?, count: Int, error: Int) {
        isScanning = false
        guard error == 0, let results else {
            status = "Scan failed (error \(error))"
            return
        }
        var found: [Network] = []
        for index in 0..<count {
            let info = results[index]
            found.append(Network(
                id: String(cString: info.bssid),
                ssid: String(cString: info.ssid),
                rssi: info.rssi,
                channel: info.channel,
                security: info.security,
                isCurrent: info.current != 0
            ))
        }
        // The joined network first, then strongest first.
        found.sort { a, b in
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            return a.rssi > b.rssi
        }
        networks = found
        status = found.count == 1 ? "1 network" : "\(found.count) networks"
    }
}

struct NetworkList: View {
    @EnvironmentObject var store: WiFiStore

    var body: some View {
        List {
            Toggle("Wi-Fi", isOn: Binding(get: { store.isPowered }, set: { store.setPower($0) }))
            Text(store.status)
                .font(.subheadline)
                .foregroundColor(.gray)
            ForEach(store.networks) { network in
                NavigationLink(destination: NetworkDetail(network: network)) {
                    NetworkRow(network: network)
                }
            }
        }
        .navigationTitle("Wi-Fi")
        .navigationBarItems(trailing: refreshButton)
        .task {
            while true {
                store.scan()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return // cancelled: the list disappeared
                }
            }
        }
    }

    var refreshButton: some View {
        Button(action: { store.scan() }) {
            Image(systemName: "arrow.clockwise")
                .font(.title2)
        }
    }
}

struct NetworkRow: View {
    let network: Network

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if network.isCurrent {
                        Image(systemName: "checkmark")
                            .foregroundColor(.blue)
                    }
                    Text(network.name)
                        .font(.headline)
                }
                Text("\(network.securityName) · Channel \(network.channel)")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            Spacer()
            Text("\(network.rssi) dBm")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
    }
}

struct NetworkDetail: View {
    let network: Network

    var body: some View {
        List {
            Text("Network: \(network.name)")
            Text("BSSID: \(network.id)")
            Text("Signal: \(network.rssi) dBm (\(network.quality))")
            Text("Channel: \(network.channel) (\(network.band))")
            Text("Security: \(network.securityName)")
            if network.isCurrent {
                Text("Connected")
                    .foregroundColor(.blue)
            }
        }
        .navigationTitle(network.name)
    }
}

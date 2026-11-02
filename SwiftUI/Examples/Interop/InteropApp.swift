import ObjCInterop
import SwiftUI

// UIKit and Foundation from Swift, with no Objective-C file: every value and
// action here is an Objective-C message, through the typed declarations in
// UIKit.swift (written with ObjCInterop's macros).

@main
struct InteropApp: App {
    let store = DeviceStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                DeviceView()
            }
            .environmentObject(store)
        }
    }
}

struct Fact: Identifiable, Equatable {
    let id: String
    let value: String
}

final class DeviceStore: ObservableObject {
    let device = UIDevice.currentDevice()
    let screen = UIScreen.mainScreen()
    let application = UIApplication.sharedApplication()

    @Published var facts: [Fact] = []
    @Published var keepAwake = false
    @Published var monitorsBattery = false

    init() {
        keepAwake = application.idleTimerDisabled
        monitorsBattery = device.batteryMonitoringEnabled
        refresh()
    }

    func refresh() {
        let scale = screen.scale
        let width = Int(screen.bounds.size.width * scale)
        let height = Int(screen.bounds.size.height * scale)

        var found = [
            Fact(id: "Name", value: device.name),
            Fact(id: "Model", value: device.model),
            Fact(id: "System", value: "\(device.systemName) \(device.systemVersion)"),
            Fact(id: "Screen", value: "\(width) × \(height) at \(Int(scale))×"),
            Fact(id: "Brightness", value: "\(Int(screen.brightness * 100))%"),
            Fact(id: "Locale", value: NSLocale.currentLocale().localeIdentifier),
            Fact(id: "Time zone", value: NSTimeZone.localTimeZone().name),
            Fact(id: "App version", value: NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleShortVersionString") ?? "?"),
        ]
        if let vendor = device.identifierForVendor {
            found.append(Fact(id: "Vendor ID", value: vendor.uuidString))
        }
        if monitorsBattery {
            let level = device.batteryLevel
            let states = ["Unknown", "On battery", "Charging", "Full"]
            let state = device.batteryState
            found.append(Fact(id: "Battery", value: level < 0 ? "Unknown" : "\(Int(level * 100))%"))
            found.append(Fact(id: "Battery state", value: state >= 0 && state < states.count ? states[state] : "?"))
        }
        if found != facts { facts = found }
    }

    func setKeepAwake(_ on: Bool) {
        application.idleTimerDisabled = on
        keepAwake = application.idleTimerDisabled
    }

    func setMonitorsBattery(_ on: Bool) {
        device.batteryMonitoringEnabled = on
        monitorsBattery = device.batteryMonitoringEnabled
        refresh()
    }

    func changeBrightness(by step: Float) {
        screen.brightness = min(1, max(0, screen.brightness + step))
        refresh()
    }

    func openWebsite() {
        _ = application.open(NSURL.URLWithString("http://www.apple.com"))
    }
}

struct DeviceView: View {
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        List {
            ForEach(store.facts) { fact in
                HStack {
                    Text(fact.id)
                    Spacer()
                    Text(fact.value)
                        .foregroundColor(.gray)
                }
            }
            Toggle("Keep screen awake", isOn: Binding(get: { store.keepAwake }, set: { store.setKeepAwake($0) }))
            Toggle("Battery monitoring", isOn: Binding(get: { store.monitorsBattery }, set: { store.setMonitorsBattery($0) }))
            HStack(spacing: 24) {
                Button("Dimmer") { store.changeBrightness(by: -0.1) }
                Button("Brighter") { store.changeBrightness(by: 0.1) }
                Spacer()
                Button("Open apple.com") { store.openWebsite() }
            }
        }
        .navigationTitle("UIKit Interop")
        .task {
            while true {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                store.refresh()
            }
        }
    }
}

import ObjCInterop
import SwiftUI

// UIKit and Foundation from Swift, with no Objective-C file: every value and
// action here is an Objective-C message sent through ObjCInterop.

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
    let device = ObjC.UIDevice.currentDevice()
    let screen = ObjC.UIScreen.mainScreen()
    let application = ObjC.UIApplication.sharedApplication()

    @Published var facts: [Fact] = []
    @Published var keepAwake = false
    @Published var monitorsBattery = false

    init() {
        keepAwake = application.isIdleTimerDisabled().asBool ?? false
        monitorsBattery = device.isBatteryMonitoringEnabled().asBool ?? false
        refresh()
    }

    func refresh() {
        let bounds = screen.bounds().asStruct
        let scale = screen.scale().asDouble ?? 1
        let width = Int(Double(bounds?.float(at: 2) ?? 0) * scale)
        let height = Int(Double(bounds?.float(at: 3) ?? 0) * scale)
        let version = ObjC.NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleShortVersionString")

        var found = [
            Fact(id: "Name", value: device.name().asString ?? "?"),
            Fact(id: "Model", value: device.model().asString ?? "?"),
            Fact(id: "System", value: "\(device.systemName().asString ?? "?") \(device.systemVersion().asString ?? "?")"),
            Fact(id: "Screen", value: "\(width) × \(height) at \(Int(scale))×"),
            Fact(id: "Brightness", value: "\(Int((screen.brightness().asDouble ?? 0) * 100))%"),
            Fact(id: "Locale", value: ObjC.NSLocale.currentLocale().localeIdentifier().asString ?? "?"),
            Fact(id: "Time zone", value: ObjC.NSTimeZone.localTimeZone().name().asString ?? "?"),
            Fact(id: "App version", value: version.asString ?? "?"),
        ]
        // identifierForVendor is iOS 6 and later.
        if device.responds(to: "identifierForVendor") {
            found.append(Fact(id: "Vendor ID", value: device.identifierForVendor().UUIDString().asString ?? "?"))
        }
        if monitorsBattery {
            let level = device.batteryLevel().asDouble ?? -1
            let states = ["Unknown", "On battery", "Charging", "Full"]
            let state = device.batteryState().asInt ?? 0
            found.append(Fact(id: "Battery", value: level < 0 ? "Unknown" : "\(Int(level * 100))%"))
            found.append(Fact(id: "Battery state", value: state < states.count ? states[state] : "?"))
        }
        if found != facts { facts = found }
    }

    func setKeepAwake(_ on: Bool) {
        application.setIdleTimerDisabled(on)
        keepAwake = application.isIdleTimerDisabled().asBool ?? on
    }

    func setMonitorsBattery(_ on: Bool) {
        device.setBatteryMonitoringEnabled(on)
        monitorsBattery = device.isBatteryMonitoringEnabled().asBool ?? on
        refresh()
    }

    func changeBrightness(by step: Double) {
        let current = screen.brightness().asDouble ?? 0.5
        screen.setBrightness(min(1, max(0, current + step)))
        refresh()
    }

    func openWebsite() {
        application.openURL(ObjC.NSURL.URLWithString("http://www.apple.com"))
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

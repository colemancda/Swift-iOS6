import CSystemInfo
import SwiftUI

// System and hardware information for iOS 6, in the spirit of AIDA64: device,
// operating system, CPU, memory, storage, battery, display, features and
// processes, from sysctl, Mach, MobileGestalt and IOKit. Live values refresh
// every two seconds.

@main
struct SystemInfoApp: App {
    let store = SystemStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                CategoryList()
            }
            .environmentObject(store)
        }
    }
}

// MARK: - Model

struct InfoRow: Identifiable, Equatable {
    let id: String
    let value: String
}

struct Category: Identifiable, Equatable {
    let id: String
    let summary: String
    let rows: [InfoRow]
}

struct Process: Identifiable, Equatable {
    let id: Int
    let name: String
    let parentPID: Int
    let uid: Int
    let startTime: Int

    var user: String {
        switch uid {
        case 0: return "root"
        case 501: return "mobile"
        default: return "uid \(uid)"
        }
    }
}

/// What the hardware is, by product type, where iOS doesn't say.
struct Product {
    let name: String
    let chip: String
    let core: String
    /// Nominal CPU clock in MHz; iOS 6 has no hw.cpufrequency.
    let clock: Int
    let screen: String

    static func named(_ type: String) -> Product? {
        switch type {
        case "iPod4,1": return Product(name: "iPod touch (4th generation)", chip: "Apple A4", core: "ARM Cortex-A8", clock: 800, screen: "3.5 inch")
        case "iPod5,1": return Product(name: "iPod touch (5th generation)", chip: "Apple A5", core: "ARM Cortex-A9", clock: 800, screen: "4 inch")
        case "iPhone3,1", "iPhone3,2", "iPhone3,3": return Product(name: "iPhone 4", chip: "Apple A4", core: "ARM Cortex-A8", clock: 800, screen: "3.5 inch")
        case "iPhone4,1": return Product(name: "iPhone 4S", chip: "Apple A5", core: "ARM Cortex-A9", clock: 800, screen: "3.5 inch")
        case "iPhone5,1", "iPhone5,2": return Product(name: "iPhone 5", chip: "Apple A6", core: "Apple Swift", clock: 1300, screen: "4 inch")
        case "iPad1,1": return Product(name: "iPad", chip: "Apple A4", core: "ARM Cortex-A8", clock: 1000, screen: "9.7 inch")
        case "iPad2,1", "iPad2,2", "iPad2,3", "iPad2,4": return Product(name: "iPad 2", chip: "Apple A5", core: "ARM Cortex-A9", clock: 1000, screen: "9.7 inch")
        default: return nil
        }
    }
}

// MARK: - Reading the system

/// Calls `body` with `string` as a NUL-terminated C string.
func withCString<Result>(_ string: String, _ body: (UnsafePointer<CChar>) -> Result) -> Result {
    var bytes: [CChar] = []
    for byte in string.utf8 {
        bytes.append(CChar(bitPattern: byte))
    }
    bytes.append(0)
    return bytes.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// Reads a string from a C function that fills a buffer and returns its length or -1.
func readString(_ key: String, _ read: (UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, Int) -> Int) -> String? {
    var buffer = [CChar](repeating: 0, count: 512)
    let length = withCString(key) { key in
        buffer.withUnsafeMutableBufferPointer { read(key, $0.baseAddress!, $0.count) }
    }
    guard length >= 0 else { return nil }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

func gestalt(_ key: String) -> String? {
    readString(key) { si_gestalt_string($0, $1, $2) }
}

func sysctlString(_ name: String) -> String? {
    readString(name) { si_sysctl_string($0, $1, $2) }
}

func sysctlNumber(_ name: String) -> Int? {
    let value = withCString(name) { si_sysctl_number($0) }
    return value >= 0 ? value : nil
}

// MARK: - Formatting

/// A value in tenths, such as 215 as "21.5".
func tenths(_ value: Int) -> String {
    let sign = value < 0 ? "-" : ""
    let magnitude = value < 0 ? -value : value
    return "\(sign)\(magnitude / 10).\(magnitude % 10)"
}

func kilobytes(_ kb: Int) -> String {
    if kb >= 1024 * 1024 { return "\(tenths(kb * 10 / (1024 * 1024))) GB" }
    if kb >= 1024 { return "\(kb / 1024) MB" }
    return "\(kb) KB"
}

func megabytes(_ mb: Int) -> String {
    mb >= 1024 ? "\(tenths(mb * 10 / 1024)) GB" : "\(mb) MB"
}

func percent(_ part: Int, of whole: Int) -> String {
    whole > 0 ? "\(part * 100 / whole)%" : "–"
}

func duration(_ seconds: Int) -> String {
    let days = seconds / 86400
    let hours = seconds % 86400 / 3600
    let minutes = seconds % 3600 / 60
    if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m \(seconds % 60)s"
}

func frequency(_ hertz: Int) -> String {
    hertz >= 1_000_000 ? "\(hertz / 1_000_000) MHz" : "\(hertz / 1000) kHz"
}

func yesNo(_ value: String?) -> String? {
    guard let value else { return nil }
    return value == "1" ? "Yes" : "No"
}

// MARK: - Store

final class SystemStore: ObservableObject {
    @Published var categories: [Category] = []
    @Published var processes: [Process] = []

    private var previousTicks: SICPUTicks?
    private var cpuUsage: (user: Int, system: Int, idle: Int)?

    init() {
        refresh()
    }

    /// Re-reads everything. Publishes only what changed, since each publish
    /// re-renders the screen.
    func refresh() {
        var ticks = SICPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        if si_cpu_ticks(&ticks) == 0 {
            if let previous = previousTicks {
                let user = ticks.user - previous.user + ticks.nice - previous.nice
                let system = ticks.system - previous.system
                let idle = ticks.idle - previous.idle
                let total = user + system + idle
                if total > 0 {
                    cpuUsage = (user * 100 / total, system * 100 / total, idle * 100 / total)
                }
            }
            previousTicks = ticks
        }

        let fresh = [device(), system(), cpu(), memory(), storage(), battery(), display(), features()]
        if fresh != categories { categories = fresh }

        var found: [Process] = []
        let context = withUnsafeMutablePointer(to: &found) { UnsafeMutableRawPointer($0) }
        si_processes({ context, pid, parentPID, uid, name, startTime in
            let list = context!.assumingMemoryBound(to: [Process].self)
            list.pointee.append(Process(id: pid, name: String(cString: name!), parentPID: parentPID, uid: uid, startTime: startTime))
        }, context)
        found.sort { $0.id < $1.id }
        if found != processes { processes = found }
    }

    private func rows(_ pairs: [(String, String?)]) -> [InfoRow] {
        var result: [InfoRow] = []
        for (label, value) in pairs {
            if let value { result.append(InfoRow(id: label, value: value)) }
        }
        return result
    }

    private var productType: String { gestalt("ProductType") ?? sysctlString("hw.machine") ?? "Unknown" }

    private func device() -> Category {
        let product = Product.named(productType)
        let model = gestalt("ModelNumber").map { model in model + (gestalt("RegionInfo") ?? "") }
        return Category(id: "Device", summary: product?.name ?? productType, rows: rows([
            ("Name", sysctlString("kern.hostname")),
            ("Kind", gestalt("DeviceName")),
            ("Model", product?.name),
            ("Product type", productType),
            ("Model number", model),
            ("Board", sysctlString("hw.model")),
            ("Platform", gestalt("HardwarePlatform")),
            ("Color", gestalt("DeviceColor")),
            ("Serial number", gestalt("SerialNumber")),
            ("UDID", gestalt("UniqueDeviceID")),
            ("Wi-Fi address", gestalt("WifiAddress")),
            ("Bluetooth address", gestalt("BluetoothAddress")),
        ]))
    }

    private func system() -> Category {
        let version = gestalt("ProductVersion") ?? "?"
        let build = gestalt("BuildVersion") ?? sysctlString("kern.osversion")
        let boot = si_boot_time()
        let uptime = boot > 0 ? duration(si_now() - boot) : nil
        return Category(id: "Operating System", summary: "iOS \(version)", rows: rows([
            ("iOS", version),
            ("Build", build),
            ("Kernel", sysctlString("kern.osrelease").map { "Darwin \($0)" }),
            ("Kernel version", sysctlString("kern.version")),
            ("Host name", sysctlString("kern.hostname")),
            ("Uptime", uptime),
            ("Processes", "\(processes.count)"),
            ("Max processes", sysctlNumber("kern.maxproc").map { "\($0)" }),
            ("Max open files", sysctlNumber("kern.maxfiles").map { "\($0)" }),
        ]))
    }

    private func cpu() -> Category {
        let product = Product.named(productType)
        let cores = sysctlNumber("hw.ncpu") ?? 1
        let usage = cpuUsage.map { "\($0.user + $0.system)%" }
        let cache: (String) -> String? = { name in sysctlNumber(name).flatMap { $0 > 0 ? kilobytes($0 / 1024) : nil } }
        return Category(id: "CPU", summary: "\(product?.chip ?? "ARM") · \(usage ?? "–") busy", rows: rows([
            ("Processor", product?.chip),
            ("Core", product?.core),
            ("Architecture", gestalt("CPUArchitecture")),
            ("Cores", "\(cores)"),
            ("Frequency", sysctlNumber("hw.cpufrequency").flatMap { $0 > 0 ? frequency($0) : nil }
                ?? product.map { "\($0.clock) MHz (nominal)" }),
            ("Bus frequency", sysctlNumber("hw.busfrequency").flatMap { $0 > 0 ? frequency($0) : nil }),
            ("Timebase", sysctlNumber("hw.tbfrequency").flatMap { $0 > 0 ? frequency($0) : nil }),
            ("L1 instruction cache", cache("hw.l1icachesize")),
            ("L1 data cache", cache("hw.l1dcachesize")),
            ("L2 cache", cache("hw.l2cachesize")),
            ("Cache line", sysctlNumber("hw.cachelinesize").map { "\($0) bytes" }),
            ("Usage", usage),
            ("User", cpuUsage.map { "\($0.user)%" }),
            ("System", cpuUsage.map { "\($0.system)%" }),
            ("Idle", cpuUsage.map { "\($0.idle)%" }),
        ]))
    }

    private func memory() -> Category {
        var memory = SIMemory(totalKB: 0, freeKB: 0, activeKB: 0, inactiveKB: 0, wiredKB: 0, pageSize: 0)
        guard si_memory(&memory) == 0 else { return Category(id: "Memory", summary: "–", rows: []) }
        let used = memory.activeKB + memory.wiredKB
        return Category(id: "Memory", summary: "\(kilobytes(used)) of \(kilobytes(memory.totalKB)) used", rows: rows([
            ("Total", kilobytes(memory.totalKB)),
            ("Used", "\(kilobytes(used)) (\(percent(used, of: memory.totalKB)))"),
            ("Free", kilobytes(memory.freeKB)),
            ("Active", kilobytes(memory.activeKB)),
            ("Inactive", kilobytes(memory.inactiveKB)),
            ("Wired", kilobytes(memory.wiredKB)),
            ("Page size", "\(memory.pageSize / 1024) KB"),
        ]))
    }

    private func storage() -> Category {
        var system = SIDisk(totalMB: 0, freeMB: 0)
        var data = SIDisk(totalMB: 0, freeMB: 0)
        let hasSystem = withCString("/") { si_disk($0, &system) } == 0
        let hasData = withCString("/private/var") { si_disk($0, &data) } == 0
        let describe: (SIDisk) -> String = { disk in "\(megabytes(disk.freeMB)) free of \(megabytes(disk.totalMB))" }
        return Category(id: "Storage", summary: hasData ? describe(data) : "–", rows: rows([
            ("Capacity", hasSystem && hasData ? megabytes(system.totalMB + data.totalMB) : nil),
            ("System", hasSystem ? describe(system) : nil),
            ("Data", hasData ? describe(data) : nil),
            ("Data used", hasData ? percent(data.totalMB - data.freeMB, of: data.totalMB) : nil),
        ]))
    }

    private func battery() -> Category {
        var battery = SIBattery(currentCapacity: -1, maxCapacity: -1, designCapacity: -1, cycleCount: -1, voltage: -1,
                                amperage: -1, temperature: -1, isCharging: -1, externalConnected: -1, fullyCharged: -1)
        guard si_battery(&battery) == 0 else { return Category(id: "Battery", summary: "–", rows: []) }
        let level = battery.maxCapacity > 0 ? battery.currentCapacity * 100 / battery.maxCapacity : -1
        let state: String
        if battery.fullyCharged == 1 {
            state = "Charged"
        } else if battery.isCharging == 1 {
            state = "Charging"
        } else if battery.externalConnected == 1 {
            state = "Plugged in, not charging"
        } else {
            state = "On battery"
        }
        let known: (Int) -> Int? = { $0 >= 0 ? $0 : nil }
        return Category(id: "Battery", summary: level >= 0 ? "\(level)% · \(state)" : state, rows: rows([
            ("Level", level >= 0 ? "\(level)%" : nil),
            ("State", state),
            ("Charge", known(battery.currentCapacity).map { "\($0) mAh" }),
            ("Full charge", known(battery.maxCapacity).map { "\($0) mAh" }),
            ("Design capacity", known(battery.designCapacity).map { "\($0) mAh" }),
            ("Health", battery.designCapacity > 0 && battery.maxCapacity > 0 ? percent(battery.maxCapacity, of: battery.designCapacity) : nil),
            ("Cycle count", known(battery.cycleCount).map { "\($0)" }),
            ("Voltage", known(battery.voltage).map { "\($0 / 1000).\(String($0 % 1000 / 10 + 100).dropFirst()) V" }),
            ("Current", battery.amperage != -1 ? "\(battery.amperage) mA" : nil),
            ("Temperature", known(battery.temperature).map { "\(tenths($0 / 10)) °C" }),
        ]))
    }

    private func display() -> Category {
        let product = Product.named(productType)
        let width = gestalt("main-screen-width")
        let height = gestalt("main-screen-height")
        let resolution = width.flatMap { w in height.map { h in "\(w) × \(h)" } }
        return Category(id: "Display", summary: resolution ?? "–", rows: rows([
            ("Resolution", resolution),
            ("Scale", gestalt("main-screen-scale").map { "\($0)×" }),
            ("Pixel density", gestalt("main-screen-pitch").map { "\($0) ppi" }),
            ("Size", product?.screen),
        ]))
    }

    private func features() -> Category {
        let found = rows([
            ("Wi-Fi", yesNo(gestalt("wifi"))),
            ("Bluetooth", yesNo(gestalt("bluetooth"))),
            ("Bluetooth Low Energy", yesNo(gestalt("bluetooth-le"))),
            ("Cellular", yesNo(gestalt("telephony"))),
            ("GPS", yesNo(gestalt("gps"))),
            ("Accelerometer", yesNo(gestalt("accelerometer"))),
            ("Gyroscope", yesNo(gestalt("gyroscope"))),
            ("Compass", yesNo(gestalt("magnetometer"))),
            ("Camera", yesNo(gestalt("still-camera"))),
            ("Rear camera", yesNo(gestalt("rear-facing-camera"))),
            ("Front camera", yesNo(gestalt("front-facing-camera"))),
            ("Autofocus", yesNo(gestalt("auto-focus-camera"))),
            ("Camera flash", yesNo(gestalt("camera-flash"))),
            ("Video recording", yesNo(gestalt("video-camera"))),
            ("Microphone", yesNo(gestalt("microphone"))),
        ])
        var available = 0
        for row in found where row.value == "Yes" { available += 1 }
        return Category(id: "Features", summary: "\(available) of \(found.count) available", rows: found)
    }
}

// MARK: - Views

struct CategoryList: View {
    @EnvironmentObject var store: SystemStore

    var body: some View {
        List {
            ForEach(store.categories) { category in
                NavigationLink(destination: CategoryDetail(category: category)) {
                    SummaryRow(title: category.id, summary: category.summary)
                }
            }
            NavigationLink(destination: ProcessList()) {
                SummaryRow(title: "Processes", summary: "\(store.processes.count) running")
            }
        }
        .navigationTitle("System Info")
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

struct SummaryRow: View {
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(summary)
                .font(.subheadline)
                .foregroundColor(.gray)
        }
    }
}

struct CategoryDetail: View {
    let category: Category

    var body: some View {
        List {
            ForEach(category.rows) { row in
                InfoRowView(row: row)
            }
        }
        .navigationTitle(category.id)
    }
}

/// A label and its value: side by side when the value is short, stacked
/// when it would wrap (an address or a kernel version).
struct InfoRowView: View {
    let row: InfoRow

    var body: some View {
        if row.value.utf8.count + row.id.utf8.count > 30 {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.id)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                Text(row.value)
            }
        } else {
            HStack {
                Text(row.id)
                Spacer()
                Text(row.value)
                    .foregroundColor(.gray)
            }
        }
    }
}

struct ProcessList: View {
    @EnvironmentObject var store: SystemStore

    var body: some View {
        List {
            ForEach(store.processes) { process in
                NavigationLink(destination: ProcessDetail(process: process)) {
                    SummaryRow(title: process.name, summary: "PID \(process.id) · \(process.user)")
                }
            }
        }
        .navigationTitle("Processes")
    }
}

struct ProcessDetail: View {
    let process: Process

    var body: some View {
        List {
            InfoRowView(row: InfoRow(id: "Name", value: process.name))
            InfoRowView(row: InfoRow(id: "PID", value: "\(process.id)"))
            InfoRowView(row: InfoRow(id: "Parent PID", value: "\(process.parentPID)"))
            InfoRowView(row: InfoRow(id: "User", value: process.user))
            InfoRowView(row: InfoRow(id: "Running for", value: duration(si_now() - process.startTime)))
        }
        .navigationTitle(process.name)
    }
}

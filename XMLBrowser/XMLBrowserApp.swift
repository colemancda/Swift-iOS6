import ObjCInterop
import SwiftUI
import XML

// Browses XML files as trees: samples bundled with the app, and the XML
// plists on the device. The XML module parses them with NSXMLParser.

@main
struct XMLBrowserApp: App {
    let library = Library()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                FileList()
            }
            .environmentObject(library)
        }
    }
}

struct XMLFile: Identifiable {
    /// The path.
    let id: String
    let name: String
    let size: Int
}

/// A parsed file, or why it couldn't be parsed.
struct Parsed {
    let document: XMLDocument?
    let error: XMLParserError?
    let milliseconds: Int
}

final class Library: ObservableObject {
    @Published var samples: [XMLFile] = []
    @Published var deviceFiles: [XMLFile] = []
    @Published var isSearching = true
    @Published var parsed: [String: Parsed] = [:]

    let files = NSFileManager.defaultManager()

    init() {
        let resources = NSBundle.mainBundle().resourcePath
        for name in ["feed.xml", "books.xml", "badge.svg"] {
            let path = resources + "/" + name
            samples.append(XMLFile(id: path, name: name, size: files.size(of: path) ?? 0))
        }
    }

    /// Finds XML plists: the system version, launch daemons and apps' Info.plist.
    func search() {
        guard isSearching else { return }
        var found: [XMLFile] = []
        func add(_ path: String, name: String) {
            if let size = files.size(of: path), files.isXML(path) {
                found.append(XMLFile(id: path, name: name, size: size))
            }
        }
        ObjC.autoreleasepool {
            add("/System/Library/CoreServices/SystemVersion.plist", name: "SystemVersion.plist")
            for name in files.names(in: "/System/Library/LaunchDaemons") where name.hasSuffix(".plist") {
                add("/System/Library/LaunchDaemons/" + name, name: name)
            }
            for name in files.names(in: "/Applications") where name.hasSuffix(".app") {
                add("/Applications/\(name)/Info.plist", name: "\(name)/Info.plist")
            }
        }
        deviceFiles = found
        isSearching = false
    }

    func load(_ file: XMLFile) {
        guard parsed[file.id] == nil else { return }
        let start = NSDate.timeIntervalSinceReferenceDate()
        let result: Parsed = ObjC.autoreleasepool {
            do throws(XMLParserError) {
                let document = try XMLDocument(contentsOfFile: file.id, options: .keepComments)
                return Parsed(document: document, error: nil, milliseconds: elapsed(since: start))
            } catch {
                return Parsed(document: nil, error: error, milliseconds: elapsed(since: start))
            }
        }
        parsed[file.id] = result
    }
}

func elapsed(since start: Double) -> Int {
    Int((NSDate.timeIntervalSinceReferenceDate() - start) * 1000)
}

struct FileList: View {
    @EnvironmentObject var library: Library

    var body: some View {
        List {
            Heading(text: "Samples")
            ForEach(library.samples) { file in
                FileRow(file: file)
            }
            Heading(text: "On this device")
            if library.isSearching {
                Text("Searching…")
                    .foregroundColor(.gray)
            } else if library.deviceFiles.isEmpty {
                Text("No XML files found")
                    .foregroundColor(.gray)
            }
            ForEach(library.deviceFiles) { file in
                FileRow(file: file)
            }
        }
        .navigationTitle("XML Browser")
        // After the first screen is up: reading the directories takes a moment.
        // (Not .task: releasing a finished Task crashes on armv7 for now.)
        .onAppear { library.search() }
    }
}

struct Heading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.gray)
    }
}

struct FileRow: View {
    let file: XMLFile

    var body: some View {
        NavigationLink(destination: DocumentView(file: file)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.headline)
                Text(byteCount(file.size))
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
        }
    }
}

struct DocumentView: View {
    @EnvironmentObject var library: Library
    let file: XMLFile

    var body: some View {
        List {
            if let parsed = library.parsed[file.id] {
                if let document = parsed.document {
                    Text("\(document.root.descendantCount + 1) elements, parsed in \(parsed.milliseconds) ms")
                        .font(.footnote)
                        .foregroundColor(.gray)
                    ForEach(document.prolog.indices) { index in
                        NodeRow(node: document.prolog[index])
                    }
                    ElementRow(element: document.root)
                } else if let error = parsed.error {
                    Text(error.message)
                        .font(.headline)
                    Text("Line \(error.line), column \(error.column) (code \(error.code))")
                        .foregroundColor(.gray)
                }
            } else {
                Text("Parsing…")
                    .foregroundColor(.gray)
            }
        }
        .navigationTitle(file.name)
        .onAppear { library.load(file) }
    }
}

/// An element's attributes and children, one per row.
struct ElementView: View {
    let element: XMLElement

    var body: some View {
        List {
            if element.name == "dict" {
                // A plist dictionary: <key> elements, each followed by its value.
                ForEach(dictionaryEntries(element)) { entry in
                    ValueRow(title: entry.key, value: entry.value)
                }
            } else {
                ForEach(element.attributeNames.indices) { index in
                    let name = element.attributeNames[index]
                    AttributeRow(name: name, value: element.attributes[name] ?? "")
                }
                ForEach(shownChildren(element).indices) { index in
                    NodeRow(node: element.children[index])
                }
                if element.children.count > maxRows {
                    Text("\(element.children.count - maxRows) more")
                        .foregroundColor(.gray)
                }
            }
        }
        .navigationTitle(element.name)
    }
}

/// Long lists are cut short: every row is a view, laid out on each render.
let maxRows = 150

func shownChildren(_ element: XMLElement) -> ArraySlice<XMLNode> {
    element.children.prefix(maxRows)
}

struct NodeRow: View {
    let node: XMLNode

    var body: some View {
        switch node {
        case .element(let element):
            ElementRow(element: element)
        case .text(let text):
            Text(trimmed(text))
        case .cdata(let text):
            ValueText(title: "CDATA", detail: trimmed(text))
        case .comment(let text):
            ValueText(title: "Comment", detail: trimmed(text))
        case .processingInstruction(let target, let data):
            ValueText(title: "<?\(target)?>", detail: data)
        }
    }
}

/// An element: a link to its contents, or just its text if that's all it has.
struct ElementRow: View {
    let element: XMLElement

    var body: some View {
        ValueRow(title: element.name, value: element)
    }
}

/// A title and a summary of an element, linking to it if it has more to show.
struct ValueRow: View {
    let title: String
    let value: XMLElement

    var body: some View {
        if hasDetail(value) {
            NavigationLink(destination: ElementView(element: value)) {
                ValueText(title: title, detail: summary(value))
            }
        } else {
            ValueText(title: title, detail: summary(value))
        }
    }
}

struct ValueText: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
        }
    }
}

struct AttributeRow: View {
    let name: String
    let value: String

    var body: some View {
        HStack {
            Text(name)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
        }
    }
}

// MARK: - Summaries

struct DictionaryEntry: Identifiable {
    let id: Int
    let key: String
    let value: XMLElement
}

func dictionaryEntries(_ dictionary: XMLElement) -> [DictionaryEntry] {
    let elements = dictionary.elements
    var entries: [DictionaryEntry] = []
    var index = 0
    while index + 1 < elements.count, entries.count < maxRows {
        if elements[index].name == "key" {
            entries.append(DictionaryEntry(id: index, key: elements[index].text, value: elements[index + 1]))
            index += 2
        } else {
            index += 1
        }
    }
    return entries
}

/// Whether an element has more than fits in its row.
func hasDetail(_ element: XMLElement) -> Bool {
    !element.elements.isEmpty || !element.attributes.isEmpty || element.text.utf8.count > 60
}

/// One line about an element: its value, its title, or what it contains.
func summary(_ element: XMLElement) -> String {
    let count = element.elements.count
    switch element.name {
    case "dict": return count == 1 ? "1 entry" : "\(count / 2) entries"
    case "array": return count == 1 ? "1 item" : "\(count) items"
    case "true", "false": return element.name
    default: break
    }
    for name in ["title", "name"] {
        if let child = element[name] { return shortened(trimmed(child.text)) }
    }
    for name in ["name", "id", "title"] {
        if let value = element.attribute(name) { return value }
    }
    if count == 0 { return shortened(trimmed(element.text)) }
    return count == 1 ? "1 element" : "\(count) elements"
}

/// Text without the whitespace around it.
func trimmed(_ text: String) -> String {
    let bytes = Array(text.utf8)
    func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
    guard let first = bytes.firstIndex(where: { !isSpace($0) }),
          let last = bytes.lastIndex(where: { !isSpace($0) }) else { return "" }
    return String(decoding: bytes[first...last], as: UTF8.self)
}

func shortened(_ text: String) -> String {
    text.count > 60 ? String(text.prefix(57)) + "…" : text
}

func byteCount(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) bytes" }
    return "\(bytes / 1024).\(bytes % 1024 * 10 / 1024) KB"
}

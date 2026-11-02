// A document tree built from XMLParser's events, the part of KissXML and
// Foundation's XMLDocument (macOS only) that apps use to read XML.

/// An XML document: its root element, and the comments and processing
/// instructions around it.
public final class XMLDocument {
    public let root: XMLElement
    /// Comments and processing instructions before and after the root element.
    public let prolog: [XMLNode]

    public init(root: XMLElement, prolog: [XMLNode] = []) {
        self.root = root
        self.prolog = prolog
    }

    /// Parses UTF-8 text (or any encoding its XML declaration names).
    public convenience init(string: String, options: XMLDocument.Options = []) throws(XMLParserError) {
        try self.init(parser: XMLParser(string: string), options: options)
    }

    public convenience init(bytes: [UInt8], options: XMLDocument.Options = []) throws(XMLParserError) {
        try self.init(parser: XMLParser(bytes: bytes), options: options)
    }

    public convenience init(contentsOfFile path: String, options: XMLDocument.Options = []) throws(XMLParserError) {
        guard let parser = XMLParser(contentsOfFile: path) else {
            throw XMLParserError(code: XMLParserError.unreadableCode, message: XMLParserError.describe(XMLParserError.unreadableCode),
                                 line: 0, column: 0)
        }
        try self.init(parser: parser, options: options)
    }

    /// Runs `parser` and builds the tree from its events.
    public convenience init(parser: XMLParser, options: XMLDocument.Options = []) throws(XMLParserError) {
        let builder = XMLTreeBuilder(options: options)
        parser.delegate = builder
        parser.shouldProcessNamespaces = options.contains(.processNamespaces)
        let succeeded = parser.parse()
        parser.delegate = nil
        guard succeeded, let root = builder.root else {
            throw parser.parserError ?? XMLParserError(code: 4, message: XMLParserError.describe(4), line: 0, column: 0)
        }
        self.init(root: root, prolog: builder.prolog)
    }

    public struct Options: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Keep text that is only whitespace, such as the indentation between elements.
        public static let preserveWhitespace = Options(rawValue: 1)
        /// Keep comments.
        public static let keepComments = Options(rawValue: 2)
        /// Give elements their local names and namespace URIs.
        public static let processNamespaces = Options(rawValue: 4)
    }

    /// The document as XML text.
    public var xmlString: String {
        var output = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        for node in prolog {
            node.write(to: &output)
            output += "\n"
        }
        root.write(to: &output)
        return output
    }
}

/// A child of an element.
public enum XMLNode {
    case element(XMLElement)
    case text(String)
    case cdata(String)
    case comment(String)
    case processingInstruction(target: String, data: String)

    func write(to output: inout String) {
        switch self {
        case .element(let element): element.write(to: &output)
        case .text(let text): output += escaped(text, quotes: false)
        case .cdata(let text): output += "<![CDATA[\(text)]]>"
        case .comment(let text): output += "<!--\(text)-->"
        case .processingInstruction(let target, let data): output += "<?\(target)\(data.isEmpty ? "" : " " + data)?>"
        }
    }
}

public final class XMLElement {
    /// The name as written ("dc:creator"), or its local name ("creator")
    /// when namespaces are processed.
    public let name: String
    public let namespaceURI: String?
    public var attributes: [String: String]
    public var children: [XMLNode] = []

    public init(name: String, namespaceURI: String? = nil, attributes: [String: String] = [:]) {
        self.name = name
        self.namespaceURI = namespaceURI
        self.attributes = attributes
    }

    public func attribute(_ name: String) -> String? {
        attributes[name]
    }

    /// Attribute names in alphabetical order (`attributes` has no order).
    public var attributeNames: [String] {
        attributes.keys.sorted()
    }

    /// The child elements, without text and comments.
    public var elements: [XMLElement] {
        var found: [XMLElement] = []
        for child in children {
            if case .element(let element) = child { found.append(element) }
        }
        return found
    }

    /// The child elements with this name.
    public func elements(named name: String) -> [XMLElement] {
        var found: [XMLElement] = []
        for child in children {
            if case .element(let element) = child, element.name == name { found.append(element) }
        }
        return found
    }

    /// The first child element with this name.
    public subscript(name: String) -> XMLElement? {
        for child in children {
            if case .element(let element) = child, element.name == name { return element }
        }
        return nil
    }

    /// The elements at a path of names below this one, such as "channel/item".
    public func elements(atPath path: String) -> [XMLElement] {
        var current = [self]
        for name in path.split(separator: "/") {
            var next: [XMLElement] = []
            for element in current { next += element.elements(named: String(name)) }
            current = next
        }
        return current
    }

    /// All the text inside this element and its descendants, like KissXML's stringValue.
    public var text: String {
        var output = ""
        appendText(to: &output)
        return output
    }

    func appendText(to output: inout String) {
        for child in children {
            switch child {
            case .element(let element): element.appendText(to: &output)
            case .text(let text), .cdata(let text): output += text
            case .comment, .processingInstruction: break
            }
        }
    }

    /// The number of elements below this one.
    public var descendantCount: Int {
        var count = 0
        for child in children {
            if case .element(let element) = child { count += 1 + element.descendantCount }
        }
        return count
    }

    /// The element as XML text.
    public var xmlString: String {
        var output = ""
        write(to: &output)
        return output
    }

    func write(to output: inout String) {
        output += "<" + name
        for key in attributeNames {
            output += " \(key)=\"\(escaped(attributes[key] ?? "", quotes: true))\""
        }
        if children.isEmpty {
            output += "/>"
            return
        }
        output += ">"
        for child in children { child.write(to: &output) }
        output += "</\(name)>"
    }
}

/// Text with &, < and > (and " in attribute values) replaced by entities.
func escaped(_ text: String, quotes: Bool) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(text.utf8.count)
    for byte in text.utf8 {
        switch byte {
        case UInt8(ascii: "&"): bytes += Array("&amp;".utf8)
        case UInt8(ascii: "<"): bytes += Array("&lt;".utf8)
        case UInt8(ascii: ">"): bytes += Array("&gt;".utf8)
        case UInt8(ascii: "\"") where quotes: bytes += Array("&quot;".utf8)
        default: bytes.append(byte)
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Builds the tree from parser events.
final class XMLTreeBuilder: XMLParserDelegate {
    let options: XMLDocument.Options
    var root: XMLElement?
    var prolog: [XMLNode] = []
    var stack: [XMLElement] = []
    /// Text since the last tag: NSXMLParser delivers it in pieces.
    var pendingText = ""

    init(options: XMLDocument.Options) {
        self.options = options
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        flushText()
        let element = XMLElement(name: elementName, namespaceURI: namespaceURI, attributes: attributes)
        if let parent = stack.last {
            parent.children.append(.element(element))
        } else if root == nil {
            root = element
        }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        flushText()
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty { pendingText += string }
    }

    func parser(_ parser: XMLParser, foundCDATA block: [UInt8]) {
        flushText()
        stack.last?.children.append(.cdata(String(decoding: block, as: UTF8.self)))
    }

    func parser(_ parser: XMLParser, foundComment comment: String) {
        guard options.contains(.keepComments) else { return }
        flushText()
        add(.comment(comment))
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        flushText()
        add(.processingInstruction(target: target, data: data ?? ""))
    }

    func add(_ node: XMLNode) {
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            prolog.append(node)
        }
    }

    func flushText() {
        guard !pendingText.isEmpty, let parent = stack.last else { return }
        if options.contains(.preserveWhitespace) || !isWhitespace(pendingText) {
            parent.children.append(.text(pendingText))
        }
        pendingText = ""
    }
}

func isWhitespace(_ text: String) -> Bool {
    for byte in text.utf8 {
        switch byte {
        case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\t"), UInt8(ascii: "\r"): continue
        default: return false
        }
    }
    return true
}

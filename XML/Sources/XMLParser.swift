// An event-driven XML parser for Embedded Swift, shaped like Foundation's
// XMLParser, on the system's NSXMLParser (libxml2) through ObjCInterop.

import ObjCInterop

/// Receives a parser's events. Every method has an empty default, so
/// implement only the ones you need.
public protocol XMLParserDelegate: AnyObject {
    func parserDidStartDocument(_ parser: XMLParser)
    func parserDidEndDocument(_ parser: XMLParser)
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String])
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?)
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String)
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String)
    /// Text, possibly in several pieces (entities and line breaks split it).
    func parser(_ parser: XMLParser, foundCharacters string: String)
    func parser(_ parser: XMLParser, foundCDATA block: [UInt8])
    func parser(_ parser: XMLParser, foundComment comment: String)
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?)
    func parser(_ parser: XMLParser, parseErrorOccurred error: XMLParserError)
}

extension XMLParserDelegate {
    public func parserDidStartDocument(_ parser: XMLParser) {}
    public func parserDidEndDocument(_ parser: XMLParser) {}
    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                       qualifiedName: String?, attributes: [String: String]) {}
    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {}
    public func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {}
    public func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {}
    public func parser(_ parser: XMLParser, foundCharacters string: String) {}
    public func parser(_ parser: XMLParser, foundCDATA block: [UInt8]) {}
    public func parser(_ parser: XMLParser, foundComment comment: String) {}
    public func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {}
    public func parser(_ parser: XMLParser, parseErrorOccurred error: XMLParserError) {}
}

/// Why parsing failed, from NSXMLParser's NSError (NSXMLParserErrorDomain).
public struct XMLParserError: Error, Equatable {
    /// An NSXMLParserError code, which follows libxml2's error numbers.
    public let code: Int
    public let message: String
    /// Where the parser stopped, counting from 1.
    public let line: Int
    public let column: Int

    public init(code: Int, message: String, line: Int, column: Int) {
        self.code = code
        self.message = message
        self.line = line
        self.column = column
    }

    /// The delegate called `abortParsing()` (NSXMLParserDelegateAbortedParseError).
    public static let abortedCode = 512
    /// A file that couldn't be read.
    public static let unreadableCode = -1
}

/// Parses an XML document and reports what it finds to its delegate, like
/// Foundation's XMLParser. The work is NSXMLParser's; this class turns its
/// Objective-C delegate calls into Swift calls with Swift values.
public final class XMLParser {
    /// Retained, unlike Foundation's, since Embedded Swift has no weak
    /// references: a delegate that keeps its parser should set this to nil
    /// after parsing.
    public var delegate: (any XMLParserDelegate)?
    /// Report each element's local name and namespace URI, instead of its name as written.
    public var shouldProcessNamespaces = false
    /// Report namespace declarations to `didStartMappingPrefix` and `didEndMappingPrefix`.
    public var shouldReportNamespacePrefixes = false
    public var shouldResolveExternalEntities = false

    let parser: ObjCValue
    var aborted = false
    /// What failed, after `parse()` returns false.
    public private(set) var parserError: XMLParserError?

    /// Parses UTF-8 text (or any encoding its XML declaration names).
    public convenience init(string: String) {
        self.init(nsData: ObjC.NSString.stringWithString(string).dataUsingEncoding(4))
    }

    public convenience init(bytes: [UInt8]) {
        let data = bytes.withUnsafeBytes { buffer in
            ObjC.NSData.dataWithBytes(ObjCValue(storage: .pointer(UnsafeMutableRawPointer(mutating: buffer.baseAddress))),
                                      length: buffer.count)
        }
        self.init(nsData: data)
    }

    /// Reads a file, or returns nil if it can't be read.
    public convenience init?(contentsOfFile path: String) {
        let data = ObjC.NSData.dataWithContentsOfFile(path)
        if data.isNil { return nil }
        self.init(nsData: data)
    }

    /// Parses an NSData object.
    public init(nsData data: ObjCValue) {
        parser = ObjC.NSXMLParser.alloc().initWithData(data)
    }

    /// Parses the whole document, calling the delegate as it goes. Returns
    /// false, with `parserError` set, for a malformed document or an abort.
    @discardableResult
    public func parse() -> Bool {
        parserError = nil
        aborted = false
        let bridge = XMLParserBridge()
        bridge.parser = self
        let object = XMLParserBridge.objcClass.new()
        bridge.attach(to: object)
        parser.setDelegate(object)
        parser.setShouldProcessNamespaces(shouldProcessNamespaces)
        parser.setShouldReportNamespacePrefixes(shouldReportNamespacePrefixes)
        parser.setShouldResolveExternalEntities(shouldResolveExternalEntities)
        let succeeded = ObjC.autoreleasepool { parser.parse().asBool ?? false } && !aborted
        parser.setDelegate(ObjC.nil)
        bridge.parser = nil
        if aborted {
            // iOS 6's parse() can return YES, with no error, after an abort.
            parserError = XMLParserError(code: XMLParserError.abortedCode, message: "Parsing was aborted",
                                         line: lineNumber, column: columnNumber)
        } else if !succeeded, parserError == nil {
            parserError = error(from: parser.parserError())
        }
        return succeeded
    }

    /// Stops parsing after the current event; `parse()` then returns false.
    public func abortParsing() {
        aborted = true
        parser.abortParsing()
    }

    /// The parser's position, counting from 1, during or after parsing.
    public var lineNumber: Int { parser.lineNumber().asInt ?? 0 }
    public var columnNumber: Int { parser.columnNumber().asInt ?? 0 }

    func error(from nsError: ObjCValue) -> XMLParserError {
        let code = nsError.code().asInt ?? 0
        return XMLParserError(code: code, message: XMLParserError.describe(code), line: lineNumber, column: columnNumber)
    }

    func report(_ nsError: ObjCValue) {
        let error = error(from: nsError)
        parserError = error
        delegate?.parser(self, parseErrorOccurred: error)
    }
}

/// The Objective-C delegate NSXMLParser calls, implemented in Swift. Types
/// are given explicitly: the runtime may not know NSXMLParserDelegate.
@ObjCImplementation("SwiftXMLParserDelegate")
final class XMLParserBridge {
    var parser: XMLParser?

    init() {}

    @ObjCMethod("parserDidStartDocument:")
    func didStartDocument(_ object: ObjCValue) {
        guard let parser else { return }
        parser.delegate?.parserDidStartDocument(parser)
    }

    @ObjCMethod("parserDidEndDocument:")
    func didEndDocument(_ object: ObjCValue) {
        guard let parser else { return }
        parser.delegate?.parserDidEndDocument(parser)
    }

    @ObjCMethod("parser:didStartElement:namespaceURI:qualifiedName:attributes:")
    func didStartElement(_ object: ObjCValue, name: String, namespaceURI: String?, qualifiedName: String?,
                         attributes: ObjCValue) {
        guard let parser, let delegate = parser.delegate else { return }
        var values: [String: String] = [:]
        let count = attributes.count().asInt ?? 0
        let keys = count > 0 ? attributes.allKeys() : nil
        for index in 0..<count {
            let key = keys.objectAtIndex(index)
            if let name = key.asString { values[name] = attributes.objectForKey(key).asString ?? "" }
        }
        delegate.parser(parser, didStartElement: name, namespaceURI: nonEmpty(namespaceURI),
                        qualifiedName: nonEmpty(qualifiedName), attributes: values)
    }

    @ObjCMethod("parser:didEndElement:namespaceURI:qualifiedName:")
    func didEndElement(_ object: ObjCValue, name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let parser else { return }
        parser.delegate?.parser(parser, didEndElement: name, namespaceURI: nonEmpty(namespaceURI),
                                qualifiedName: nonEmpty(qualifiedName))
    }

    @ObjCMethod("parser:didStartMappingPrefix:toURI:")
    func didStartMapping(_ object: ObjCValue, prefix: String, uri: String) {
        guard let parser else { return }
        parser.delegate?.parser(parser, didStartMappingPrefix: prefix, toURI: uri)
    }

    @ObjCMethod("parser:didEndMappingPrefix:")
    func didEndMapping(_ object: ObjCValue, prefix: String) {
        guard let parser else { return }
        parser.delegate?.parser(parser, didEndMappingPrefix: prefix)
    }

    @ObjCMethod("parser:foundCharacters:")
    func foundCharacters(_ object: ObjCValue, string: String) {
        guard let parser else { return }
        parser.delegate?.parser(parser, foundCharacters: string)
    }

    @ObjCMethod("parser:foundCDATA:")
    func foundCDATA(_ object: ObjCValue, data: ObjCValue) {
        guard let parser else { return }
        var bytes: [UInt8] = []
        let length = data.length().asInt ?? 0
        if length > 0, case .pointer(let pointer?) = data.bytes().storage {
            bytes = Array(UnsafeRawBufferPointer(start: pointer, count: length))
        }
        parser.delegate?.parser(parser, foundCDATA: bytes)
    }

    @ObjCMethod("parser:foundComment:")
    func foundComment(_ object: ObjCValue, comment: String) {
        guard let parser else { return }
        parser.delegate?.parser(parser, foundComment: comment)
    }

    @ObjCMethod("parser:foundProcessingInstructionWithTarget:data:")
    func foundProcessingInstruction(_ object: ObjCValue, target: String, data: String?) {
        guard let parser else { return }
        parser.delegate?.parser(parser, foundProcessingInstructionWithTarget: target, data: data)
    }

    @ObjCMethod("parser:parseErrorOccurred:")
    func parseErrorOccurred(_ object: ObjCValue, error: ObjCValue) {
        parser?.report(error)
    }
}

/// NSXMLParser passes nil or "" for a missing namespace or qualified name, depending on its options.
func nonEmpty(_ string: String?) -> String? {
    guard let string, !string.isEmpty else { return nil }
    return string
}

extension XMLParserError {
    /// A description of the common NSXMLParserError codes, which follow
    /// libxml2's xmlParserErrors. iOS 6's own NSError description only
    /// repeats the code.
    static func describe(_ code: Int) -> String {
        switch code {
        case unreadableCode: return "The file couldn't be read"
        case 4: return "The document is empty"
        case 5: return "The document ended early, or has more after its root element"
        case 9: return "Invalid character"
        case 23: return "An entity reference is missing its semicolon"
        case 26: return "Undeclared entity"
        case 38: return "\"<\" in an attribute value"
        case 39: return "An attribute value is missing its quotes"
        case 40: return "An attribute value isn't closed"
        case 41: return "An attribute has no value"
        case 42: return "An attribute appears twice"
        case 68: return "A name was expected"
        case 73: return "\">\" was expected"
        case 76: return "An end tag doesn't match its start tag"
        case 77: return "An element isn't closed"
        default: return "XML error \(code)"
        }
    }
}

// Exercises the XML module (NSXMLParser through ObjCInterop) on the device.
// Run with `make test`; prints each check and a summary.

import ObjCInterop
import XML

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition { passed += 1 } else { failed += 1 }
    print("\(condition ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": " + detail)")
}

/// Records every event as a line of text.
final class Recorder: XMLParserDelegate {
    var events: [String] = []
    var abortAfter: String?

    func parserDidStartDocument(_ parser: XMLParser) { events.append("start") }
    func parserDidEndDocument(_ parser: XMLParser) { events.append("end") }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        var line = "<\(elementName)"
        for key in attributes.keys.sorted() { line += " \(key)=\(attributes[key] ?? "")" }
        if let namespaceURI { line += " ns=\(namespaceURI)" }
        if let qualifiedName { line += " q=\(qualifiedName)" }
        events.append(line + ">")
        if elementName == abortAfter { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        events.append("</\(elementName)>")
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        events.append("map \(prefix)=\(namespaceURI)")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Join adjacent pieces, which NSXMLParser splits at entities.
        if let last = events.last, last.hasPrefix("text ") {
            events[events.count - 1] = last + string
        } else {
            events.append("text " + string)
        }
    }

    func parser(_ parser: XMLParser, foundCDATA block: [UInt8]) {
        events.append("cdata " + String(decoding: block, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, foundComment comment: String) { events.append("comment" + comment) }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        events.append("pi \(target) \(data ?? "nil")")
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: XMLParserError) { events.append("error \(error.code)") }
}

/// Whether `text` contains `part` (String.contains(String) is in Foundation).
func contains(_ text: String, _ part: String) -> Bool {
    let bytes = Array(text.utf8), needle = Array(part.utf8)
    guard needle.count <= bytes.count else { return false }
    for start in 0...(bytes.count - needle.count) where Array(bytes[start..<start + needle.count]) == needle { return true }
    return false
}

func events(_ xml: String, configure: (XMLParser, Recorder) -> Void = { _, _ in }) -> (Bool, [String], XMLParser) {
    let recorder = Recorder()
    let parser = XMLParser(string: xml)
    parser.delegate = recorder
    configure(parser, recorder)
    let succeeded = parser.parse()
    return (succeeded, recorder.events, parser)
}

func failure(_ xml: String) -> XMLParserError? {
    do throws(XMLParserError) {
        _ = try XMLDocument(string: xml)
        return nil
    } catch {
        return error
    }
}

ObjC.autoreleasepool {
    // Events, in order.
    let (ok, simple, _) = events("<a x=\"1\"><b>hi</b><c/></a>")
    check("parse() succeeds", ok)
    check("event order", simple == ["start", "<a x=1>", "<b>", "text hi", "</b>", "<c>", "</c>", "</a>", "end"],
          simple.joined(separator: " "))

    let (_, attributes, _) = events("<item id=\"7\" name='Ünïcode &amp; more' empty=\"\"/>")
    check("attributes, entities in values", attributes.contains("<item empty= id=7 name=Ünïcode & more>"),
          attributes.joined(separator: " "))

    let (_, entities, _) = events("<t>&lt;tag&gt; &amp; &quot;q&quot; &apos;a&apos; &#65;&#x42;</t>")
    check("predefined and character entities", entities.contains("text <tag> & \"q\" 'a' AB"),
          entities.joined(separator: " "))

    let (_, unicode, _) = events("<t>café 日本 🎉</t>")
    check("UTF-8 text", unicode.contains("text café 日本 🎉"), unicode.joined(separator: " "))

    let (_, extras, _) = events("<?xml version=\"1.0\"?><?style href=\"a.css\"?><r><!-- note --><![CDATA[<raw> & stuff]]></r>")
    check("processing instruction", extras.contains("pi style href=\"a.css\""), extras.joined(separator: " "))
    check("comment", extras.contains("comment note "))
    check("CDATA bytes", extras.contains("cdata <raw> & stuff"))

    // Namespaces.
    let feed = "<feed xmlns=\"http://www.w3.org/2005/Atom\" xmlns:media=\"http://search.yahoo.com/mrss/\"><media:thumbnail url=\"x\"/></feed>"
    let (_, plain, _) = events(feed)
    check("names as written by default", plain.contains("<media:thumbnail url=x>"), plain.joined(separator: " "))
    let (_, spaced, _) = events(feed) { parser, _ in
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
    }
    check("local name and namespace URI",
          spaced.contains("<thumbnail url=x ns=http://search.yahoo.com/mrss/ q=media:thumbnail>"), spaced.joined(separator: " "))
    check("namespace prefixes reported", spaced.contains("map media=http://search.yahoo.com/mrss/"))

    // Errors and aborting.
    let (badOK, bad, badParser) = events("<a>\n  <b>\n</a>")
    check("malformed document fails", !badOK && badParser.parserError != nil)
    check("delegate told of the error", bad.contains { $0.hasPrefix("error ") }, bad.joined(separator: " "))
    if let error = badParser.parserError {
        check("error line", error.line == 3, "code \(error.code) line \(error.line) column \(error.column): \(error.message)")
    }
    let (abortOK, aborted, abortParser) = events("<a><b/><c/><d/></a>") { _, recorder in recorder.abortAfter = "b" }
    check("abortParsing() stops parsing", !abortOK && !aborted.contains("<c>"), aborted.joined(separator: " "))
    check("aborted error code", abortParser.parserError?.code == XMLParserError.abortedCode,
          "\(abortParser.parserError?.code ?? 0)")

    for (name, xml) in [("empty", ""), ("unclosed", "<a><b></a>"), ("mismatched", "<a></b>"), ("bad entity", "<a>&nope;</a>"),
                        ("no semicolon", "<a>&amp</a>"), ("duplicate attribute", "<a x=\"1\" x=\"2\"/>"),
                        ("unquoted attribute", "<a x=1/>"), ("two roots", "<a/><b/>"), ("truncated", "<a><b>text")] {
        let error = failure(xml)
        check("error: \(name)", error != nil, error.map { "\($0.code) \($0.message)" } ?? "parsed")
    }

    // Documents.
    let rss = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Embedded Swift News</title>
        <item><title>iOS 6 &amp; Swift</title><link>http://example.com/1</link></item>
        <item><title>Objective-C bridge</title><link>http://example.com/2</link></item>
        <item><title><![CDATA[XML <parsing>]]></title></item>
      </channel>
    </rss>
    """
    do throws(XMLParserError) {
        let document = try XMLDocument(string: rss)
        let root = document.root
        check("root element", root.name == "rss" && root.attribute("version") == "2.0")
        check("whitespace dropped", root.children.count == 1, "\(root.children.count)")
        check("subscript", root["channel"]?["title"]?.text == "Embedded Swift News")
        let items = root.elements(atPath: "channel/item")
        check("elements(atPath:)", items.count == 3, "\(items.count)")
        check("text with entity", items.first?["title"]?.text == "iOS 6 & Swift", items.first?["title"]?.text ?? "nil")
        check("text from CDATA", items.last?["title"]?.text == "XML <parsing>")
        check("descendantCount", root.descendantCount == 10, "\(root.descendantCount)")

        let reparsed = try XMLDocument(string: document.xmlString)
        check("xmlString round trip", reparsed.root.xmlString == root.xmlString, reparsed.root.xmlString)
        check("escaping", contains(root.xmlString, "iOS 6 &amp; Swift"))
    } catch {
        check("RSS document parses", false, "\(error.code) \(error.message)")
    }

    do throws(XMLParserError) {
        let spaced = try XMLDocument(string: "<a> <b/> text <!--c--></a>", options: [.preserveWhitespace, .keepComments])
        check("preserveWhitespace and keepComments", spaced.root.children.count == 4, "\(spaced.root.children.count)")
        let compact = try XMLDocument(string: "<a> <b/> text <!--c--></a>")
        check("default options", compact.root.children.count == 2 && compact.root.text == " text ")
        let namespaced = try XMLDocument(string: "<x:a xmlns:x=\"urn:x\"><x:b/></x:a>", options: .processNamespaces)
        check("processNamespaces option", namespaced.root.name == "a" && namespaced.root.namespaceURI == "urn:x"
              && namespaced.root["b"] != nil)
    } catch {
        check("option documents parse", false, "\(error.code) \(error.message)")
    }

    // Bytes in another encoding, named by the XML declaration.
    let latin1: [UInt8] = Array("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><t>caf".utf8) + [0xE9] + Array("</t>".utf8)
    if let document = try? XMLDocument(bytes: latin1) {
        check("ISO-8859-1 bytes", document.root.text == "café", document.root.text)
    } else {
        check("ISO-8859-1 bytes", false)
    }

    // Files: one written here, and the system's own plist.
    let path = "/tmp/xml-tests.xml"
    _ = ObjC.NSString.stringWithString(rss).writeToFile(path, atomically: true, encoding: 4, error: ObjC.nil)
    if let document = try? XMLDocument(contentsOfFile: path) {
        check("contentsOfFile", document.root.elements(atPath: "channel/item").count == 3)
    } else {
        check("contentsOfFile", false)
    }
    check("missing file", (try? XMLDocument(contentsOfFile: "/tmp/no-such-file.xml")) == nil)
    if let version = try? XMLDocument(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist") {
        let entries = version.root["dict"]?.elements ?? []
        var product = ""
        for (index, entry) in entries.enumerated() where entry.text == "ProductVersion" && index + 1 < entries.count {
            product = entries[index + 1].text
        }
        check("SystemVersion.plist", !product.isEmpty, "ProductVersion \(product)")
    } else {
        check("SystemVersion.plist", false)
    }
}

// A larger document: 2,000 elements with attributes and text, timed.
ObjC.autoreleasepool {
    var xml = "<catalog>"
    for index in 0..<500 {
        xml += "<book id=\"\(index)\"><title>Book \(index)</title><author>Author \(index % 37)</author><price>\(index % 50).99</price></book>"
    }
    xml += "</catalog>"
    let start = ObjC.NSDate.timeIntervalSinceReferenceDate().asDouble ?? 0
    do throws(XMLParserError) {
        let document = try XMLDocument(string: xml)
        let elapsed = Int(((ObjC.NSDate.timeIntervalSinceReferenceDate().asDouble ?? 0) - start) * 1000)
        let books = document.root.elements(named: "book")
        check("2,000-element document", books.count == 500 && books[499].attribute("id") == "499"
              && books[499]["title"]?.text == "Book 499", "\(xml.utf8.count / 1024) KB in \(elapsed) ms")
    } catch {
        check("2,000-element document", false, "\(error.code) \(error.message)")
    }
}

// Parsers and their Objective-C delegates are released: repeated parses don't grow memory or crash.
for _ in 0..<500 {
    ObjC.autoreleasepool {
        _ = try? XMLDocument(string: "<a><b x=\"1\">text</b></a>")
    }
}
check("500 parses", true)

print("\(passed) passed, \(failed) failed")

# XML

XML parsing for Embedded Swift on iOS 6, on the system's `NSXMLParser`
(libxml2) through [ObjCInterop](../ObjC/README.md). It has two parts:

- **An event parser.** `XMLParser` and `XMLParserDelegate` are shaped like
  Foundation's.
- **A document tree.** `XMLDocument` and `XMLElement` cover what apps use
  from KissXML, or from Foundation's `XMLDocument` (which is macOS only).

```swift
import XML

let document = try XMLDocument(contentsOfFile: path)
for item in document.root.elements(atPath: "channel/item") {
    print(item["title"]?.text ?? "", item["link"]?.text ?? "")
}
```

## The tree

- **`XMLDocument`:**
  - Created from `string:`, `bytes:` (any encoding the XML declaration
    names), `contentsOfFile:` or an `XMLParser`. It throws an
    `XMLParserError`, which has a code, message, line and column.
  - Has `root` and `prolog` (the comments and processing instructions around
    the root).
  - `xmlString` writes the document back out.
  - **Options:**
    - `.preserveWhitespace` keeps indentation text.
    - `.keepComments` keeps comments.
    - `.processNamespaces` gives local names and namespace URIs.
- **`XMLElement`:**
  - `name`, `namespaceURI`, `attributes` (`attribute(_:)`, and
    `attributeNames` in order), and `children`.
  - Lookups:
    - `elements`: the child elements.
    - `elements(named:)`.
    - `element["title"]`: the first child of that name.
    - `elements(atPath: "channel/item")`.
  - `text`: all the text below the element, CDATA included.
  - `descendantCount` and `xmlString`.
- **`XMLNode`:** a child, one of `.element`, `.text`, `.cdata`, `.comment` or
  `.processingInstruction`. Text that NSXMLParser delivers in pieces is
  joined.

## Events

```swift
final class Titles: XMLParserDelegate {
    var titles: [String] = []
    var inTitle = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        inTitle = elementName == "title"
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { titles.append(string) }
    }
}

let parser = XMLParser(string: xml)
let titles = Titles()
parser.delegate = titles
parser.parse()
```

- **Delegate methods:** start and end of document, start and end of element
  (attributes as `[String: String]`), namespace prefixes, characters, CDATA
  (as `[UInt8]`), comments, processing instructions and errors. Every method
  has an empty default.
- **Options:** `shouldProcessNamespaces`, `shouldReportNamespacePrefixes` and
  `shouldResolveExternalEntities`, as in Foundation.
- **Stopping:** `abortParsing()` stops early. `parse()` then returns false,
  and `parserError` has code 512. iOS 6's own NSXMLParser can return YES after
  an abort, so the wrapper keeps track of it itself.
- **Errors:** `XMLParserError` describes the common codes, which are
  libxml2's error numbers. iOS 6's NSError descriptions only repeat the
  number.
- **The delegate is retained.** Embedded Swift has no `weak`, so a delegate
  that also holds its parser should set `delegate` to nil after parsing.

## How it works

`XMLParser` creates an `NSXMLParser` and gives it a delegate:
`SwiftXMLParserDelegate`, an Objective-C class implemented in Swift with
`@ObjCImplementation`. Each delegate method converts its NSString,
NSDictionary and NSData arguments to Swift values and calls the Swift
delegate. The method types are spelled out because the runtime may not know
the `NSXMLParserDelegate` protocol.

## Speed

On the iPod touch 4, a 44 KB document with 2,000 elements takes about 390 ms
to become a tree. NSXMLParser alone takes 14 ms. The rest is the Objective-C
bridge: each event is a message into Swift (about 10 µs), plus about 8 µs per
argument and per NSString converted. Small files, like plists and feeds of a
few KB, parse in 3–60 ms.

## Tests

```bash
make test   # build build/xml-tests and run it on the iPod
```

43 checks, all passing on iOS 6.1.6:
- Event order, attributes, entities, UTF-8, CDATA, comments and processing
  instructions.
- Namespaces, aborting, and line numbers in errors.
- Nine kinds of malformed document.
- The tree, round trips through `xmlString`, and ISO-8859-1 input.
- Reading files, including the system's `SystemVersion.plist`.
- A timed 2,000-element document, and 500 parses in a row.

## Using it in an app

A SwiftUI app built with `../SwiftUI/Makefile` sets `LIBS=XML`, which builds
this folder as the module `XML`. [../XMLBrowser](../XMLBrowser/README.md) is
an example.

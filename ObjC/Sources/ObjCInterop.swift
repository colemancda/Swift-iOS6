import CObjCRuntime

// Objective-C messaging for Embedded Swift, which has no Objective-C interop.
//
//     let label = ObjC.UILabel.alloc().initWithFrame(.rect(x: 0, y: 0, width: 320, height: 44))
//     label.setText("Hello")
//     label.setTextColor(ObjC.UIColor.colorWithRed(0.2, green: 0.4, blue: 0.8, alpha: 1))
//     let version = ObjC.UIDevice.currentDevice().systemVersion().asString
//
// `ObjC.Name` looks up a class. On any value, `.name(...)` sends a message:
// the selector is the name, then one "label:" per argument, with the first
// argument unlabeled, so `setTitle("Go", forState: 0)` sends
// `setTitle:forState:`. Arguments are converted to the types in the
// method's type encoding (a Swift string becomes an NSString for an object
// parameter, a number becomes a float for a CGFloat parameter), and the result
// is typed from it. Arguments can be literals, Swift values of any
// ObjCConvertible type (Int, Double, Bool, String, Optional…), other ObjCValues,
// or structs such as `.rect(x:y:width:height:)`; pass `ObjC.nil` for nil. A selector that clashes with a Swift name (`init`,
// `self`, `asString`…) can be sent with `send("init")`.
//
// Objects are retained while a value holds them, following Objective-C's
// naming rules: results of alloc, new, copy and mutableCopy are already owned,
// and init… consumes its receiver.

/// The Objective-C classes, by name: `ObjC.NSString`.
public let ObjC = ObjCRuntime()

@dynamicMemberLookup
public struct ObjCRuntime {
    /// The class with this name, or nil.
    public subscript(dynamicMember name: String) -> ObjCValue {
        classNamed(name)
    }

    public func classNamed(_ name: String) -> ObjCValue {
        let pointer = withCString(name) { objcrt_class($0) }
        return ObjCValue(pointer.map { ObjCObject(retaining: $0) })
    }

    /// Loads a public or private framework by name, such as "UIKit" or
    /// "BluetoothManager", so its classes can be looked up.
    @discardableResult
    public func load(framework name: String) -> Bool {
        for directory in ["/System/Library/Frameworks/", "/System/Library/PrivateFrameworks/"] {
            if withCString(directory + name + ".framework/" + name, { objcrt_load($0) }) == 0 { return true }
        }
        return false
    }

    /// Runs `body` in an autorelease pool. Apps already have one per run loop
    /// turn; command-line tools need this.
    public func autoreleasepool<Result>(_ body: () -> Result) -> Result {
        let pool = objcrt_pool_push()
        let result = body()
        objcrt_pool_pop(pool)
        return result
    }

    /// nil, as an argument.
    public var `nil`: ObjCValue { ObjCValue(storage: .object(nil)) }

    /// A selector, for arguments of type SEL.
    public func selector(_ name: String) -> ObjCValue {
        ObjCValue(storage: .selector(withCString(name) { objcrt_selector($0) }))
    }
}

/// An Objective-C object, retained while Swift holds it.
public final class ObjCObject {
    public let pointer: UnsafeMutableRawPointer
    /// False once an init… message has consumed this reference.
    var owned = true

    init(retaining pointer: UnsafeMutableRawPointer) {
        self.pointer = pointer
        _ = objcrt_retain(pointer)
    }

    init(adopting pointer: UnsafeMutableRawPointer) {
        self.pointer = pointer
    }

    deinit {
        if owned { objcrt_release(pointer) }
    }

    public var className: String {
        String(cString: objcrt_class_name(pointer))
    }
}

/// A C struct passed by value, as 32-bit words: CGRect, CGPoint, CGSize, NSRange…
public struct ObjCStruct: Equatable {
    public var words: [UInt]

    public init(words: [UInt]) {
        self.words = words
    }

    /// CGFloat is a 32-bit float on armv7.
    public init(floats: [Float]) {
        words = []
        for value in floats { words.append(UInt(value.bitPattern)) }
    }

    public func float(at index: Int) -> Float {
        index < words.count ? Float(bitPattern: UInt32(words[index])) : 0
    }

    public func int(at index: Int) -> Int {
        index < words.count ? Int(bitPattern: words[index]) : 0
    }
}

/// A value going to or coming from Objective-C.
@dynamicMemberLookup
public struct ObjCValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                         ExpressibleByStringLiteral, ExpressibleByNilLiteral {
    public enum Storage {
        case void
        case int(Int)
        case int64(Int64)
        case double(Double)
        case bool(Bool)
        case object(ObjCObject?)
        case selector(UnsafeMutableRawPointer?)
        case string(String)
        case pointer(UnsafeMutableRawPointer?)
        case structure(ObjCStruct)
    }

    public let storage: Storage

    public init(storage: Storage) { self.storage = storage }
    public init(_ object: ObjCObject?) { storage = .object(object) }
    public init(_ value: Int) { storage = .int(value) }
    public init(_ value: Int64) { storage = .int64(value) }
    public init(_ value: Double) { storage = .double(value) }
    public init(_ value: Bool) { storage = .bool(value) }
    public init(_ value: String) { storage = .string(value) }
    public init(_ value: ObjCStruct) { storage = .structure(value) }
    public init(integerLiteral value: Int) { storage = .int(value) }
    public init(floatLiteral value: Double) { storage = .double(value) }
    public init(booleanLiteral value: Bool) { storage = .bool(value) }
    public init(stringLiteral value: String) { storage = .string(value) }
    public init(nilLiteral: ()) { storage = .object(nil) }

    /// Sends a message: `value.setTitle("Go", forState: 0)`.
    public subscript(dynamicMember name: String) -> ObjCMessage {
        ObjCMessage(receiver: self, name: name)
    }

    /// Sends the message with this full selector, such as "setTitle:forState:".
    @discardableResult
    public func send(_ selector: String, _ arguments: any ObjCConvertible...) -> ObjCValue {
        var values: [ObjCValue] = []
        for argument in arguments { values.append(argument.objcValue) }
        return ObjCValue.send(selector, to: self, values)
    }

    // MARK: Reading values

    public var asObject: ObjCObject? {
        if case .object(let object) = storage { return object }
        return nil
    }

    public var isNil: Bool {
        switch storage {
        case .object(let object): return object == nil
        case .pointer(let pointer), .selector(let pointer): return pointer == nil
        case .void: return true
        default: return false
        }
    }

    /// The contents of an NSString (or a Swift string value).
    public var asString: String? {
        switch storage {
        case .string(let string): return string
        case .object(let object?) where isKind(of: "NSString"): return String(cString: objcrt_utf8(object.pointer))
        default: return nil
        }
    }

    /// An integer result, a BOOL, or an NSNumber's value.
    public var asInt: Int? {
        switch storage {
        case .int(let value): return value
        case .int64(let value): return Int(truncatingIfNeeded: value)
        case .bool(let value): return value ? 1 : 0
        case .double(let value): return Int(value)
        case .object(_?) where isKind(of: "NSNumber"): return send("intValue").asInt
        default: return nil
        }
    }

    public var asInt64: Int64? {
        if case .int64(let value) = storage { return value }
        return asInt.map { Int64($0) }
    }

    /// A float or double result, or an NSNumber's value.
    public var asDouble: Double? {
        switch storage {
        case .double(let value): return value
        case .int(let value): return Double(value)
        case .int64(let value): return Double(value)
        case .object(_?) where isKind(of: "NSNumber"): return send("doubleValue").asDouble
        default: return nil
        }
    }

    /// A BOOL result (which Objective-C returns as a char) or an NSNumber's value.
    public var asBool: Bool? {
        switch storage {
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .object(_?) where isKind(of: "NSNumber"): return send("boolValue").asBool
        default: return nil
        }
    }

    public var asStruct: ObjCStruct? {
        if case .structure(let value) = storage { return value }
        return nil
    }

    public var className: String? { asObject?.className }

    /// Whether this is an instance of the named class or one of its subclasses.
    public func isKind(of className: String) -> Bool {
        guard let object = asObject else { return false }
        let cls = withCString(className) { objcrt_class($0) }
        return cls != nil && objcrt_is_kind(object.pointer, cls) != 0
    }

    public func responds(to selector: String) -> Bool {
        guard let object = asObject else { return false }
        var signature = ObjCRTSignature()
        return objcrt_signature(object.pointer, withCString(selector) { objcrt_selector($0) }, &signature) == 0
    }
}

/// A message waiting for its arguments: `value.setTitle` in `value.setTitle("Go", forState: 0)`.
@dynamicCallable
public struct ObjCMessage {
    let receiver: ObjCValue
    let name: String

    @discardableResult
    public func dynamicallyCall(withKeywordArguments arguments: KeyValuePairs<String, any ObjCConvertible>) -> ObjCValue {
        var selector = name
        var values: [ObjCValue] = []
        for (label, value) in arguments {
            selector += values.isEmpty ? ":" : label + ":"
            values.append(value.objcValue)
        }
        return ObjCValue.send(selector, to: receiver, values)
    }
}

// MARK: - Arguments

/// A Swift value that can be passed in a message.
public protocol ObjCConvertible {
    var objcValue: ObjCValue { get }
}

extension ObjCValue: ObjCConvertible {
    public var objcValue: ObjCValue { self }
}

extension ObjCObject: ObjCConvertible {
    public var objcValue: ObjCValue { ObjCValue(self) }
}

extension ObjCStruct: ObjCConvertible {
    public var objcValue: ObjCValue { ObjCValue(self) }
}

extension Int: ObjCConvertible {
    public var objcValue: ObjCValue { ObjCValue(self) }
}

extension Int32: ObjCConvertible {
    public var objcValue: ObjCValue { ObjCValue(Int(self)) }
}

extension UInt: ObjCConvertible {
    public var objcValue: ObjCValue { ObjCValue(Int(bitPattern: self)) }
}

extension Int64: ObjCConvertible {
    public var objcValue: ObjCValue { ObjCValue(self) }
}

extension Double: ObjCConvertible {
    public var objcValue: ObjCValue { ObjCValue(self) }
}

extension Float: ObjCConvertible {
    public var objcValue: ObjCValue { ObjCValue(Double(self)) }
}

extension Bool: ObjCConvertible {
    public var objcValue: ObjCValue { ObjCValue(self) }
}

extension String: ObjCConvertible {
    public var objcValue: ObjCValue { ObjCValue(self) }
}

extension Optional: ObjCConvertible where Wrapped: ObjCConvertible {
    public var objcValue: ObjCValue { self?.objcValue ?? ObjCValue(storage: .object(nil)) }
}

/// Structs by value, written like `.rect(x: 0, y: 0, width: 320, height: 44)`.
extension ObjCConvertible where Self == ObjCValue {
    public static func rect(x: Float, y: Float, width: Float, height: Float) -> ObjCValue {
        ObjCValue(ObjCStruct(floats: [x, y, width, height]))
    }

    public static func point(x: Float, y: Float) -> ObjCValue {
        ObjCValue(ObjCStruct(floats: [x, y]))
    }

    public static func size(width: Float, height: Float) -> ObjCValue {
        ObjCValue(ObjCStruct(floats: [width, height]))
    }

    public static func range(location: Int, length: Int) -> ObjCValue {
        ObjCValue(ObjCStruct(words: [UInt(bitPattern: location), UInt(bitPattern: length)]))
    }
}

// MARK: - Sending

extension ObjCValue {
    static func send(_ selectorName: String, to receiver: ObjCValue, _ arguments: [ObjCValue]) -> ObjCValue {
        // Messages to nil return nil, as in Objective-C.
        guard let target = receiver.asObject else { return nil }
        let selector = withCString(selectorName) { objcrt_selector($0) }
        var signature = ObjCRTSignature()
        guard objcrt_signature(target.pointer, selector, &signature) == 0 else {
            fatalError("-[\(target.className) \(selectorName)]: unrecognized selector")
        }
        guard signature.argumentCount == arguments.count else {
            fatalError("-[\(target.className) \(selectorName)] takes \(signature.argumentCount) arguments, not \(arguments.count)")
        }

        // C strings passed as char * live until the message returns.
        var buffers: [UnsafeMutablePointer<CChar>] = []
        defer { for buffer in buffers { buffer.deallocate() } }

        var words: [UInt] = []
        for (index, argument) in arguments.enumerated() {
            let type = byte(signature.argumentTypes, index)
            let size = long(signature.argumentSizes, index)
            argument.appendWords(to: &words, type: type, size: size, buffers: &buffers, selector: selectorName)
        }
        guard words.count <= ObjCRTMaxWords else {
            fatalError("-[\(target.className) \(selectorName)]: too many argument words")
        }
        // objcrt_send always reads all 16 words.
        while words.count < ObjCRTMaxWords { words.append(0) }

        let returnType = signature.returnType
        let returnSize = signature.returnSize
        var structWords = [UInt](repeating: 0, count: max(1, (returnSize + 3) / 4))
        let usesStructReturn = returnType == ascii("{") && returnSize > 4

        var result: (UInt, UInt) = (0, 0)
        words.withUnsafeBufferPointer { wordBuffer in
            structWords.withUnsafeMutableBufferPointer { structBuffer in
                var message = ObjCRTMessage(
                    receiver: target.pointer,
                    selector: selector,
                    words: wordBuffer.baseAddress,
                    wordCount: words.count,
                    structResult: usesStructReturn ? UnsafeMutableRawPointer(structBuffer.baseAddress) : nil,
                    result: (0, 0)
                )
                _ = objcrt_send(&message)
                result = message.result
            }
        }

        // init… consumes the receiver's reference and returns an owned one.
        let family = MethodFamily(selectorName)
        if family == .initializer { target.owned = false }
        return ObjCValue(returnType: returnType, size: returnSize, result: result,
                         structWords: usesStructReturn ? structWords : nil, owned: family != .other)
    }

    /// Converts this argument to the words a parameter of `type` takes.
    func appendWords(to words: inout [UInt], type: CChar, size: Int, buffers: inout [UnsafeMutablePointer<CChar>],
                     selector: String) {
        switch type {
        case ascii("f"):
            words.append(UInt(Float(asDouble ?? 0).bitPattern))
        case ascii("d"):
            let bits = (asDouble ?? 0).bitPattern
            words.append(UInt(truncatingIfNeeded: bits))
            words.append(UInt(truncatingIfNeeded: bits >> 32))
        case ascii("q"), ascii("Q"):
            let value = UInt64(bitPattern: asInt64 ?? 0)
            words.append(UInt(truncatingIfNeeded: value))
            words.append(UInt(truncatingIfNeeded: value >> 32))
        case ascii("@"), ascii("#"):
            switch storage {
            case .string(let string):
                // An autoreleased NSString.
                words.append(UInt(bitPattern: withCString(string) { objcrt_string($0) }))
            default:
                words.append(UInt(bitPattern: rawPointer))
            }
        case ascii(":"):
            if case .string(let name) = storage {
                words.append(UInt(bitPattern: withCString(name) { objcrt_selector($0) }))
            } else {
                words.append(UInt(bitPattern: rawPointer))
            }
        case ascii("*"):
            if case .string(let string) = storage {
                let utf8 = Array(string.utf8)
                let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count + 1)
                for (index, byte) in utf8.enumerated() { buffer[index] = CChar(bitPattern: byte) }
                buffer[utf8.count] = 0
                buffers.append(buffer)
                words.append(UInt(bitPattern: buffer))
            } else {
                words.append(UInt(bitPattern: rawPointer))
            }
        case ascii("^"):
            words.append(UInt(bitPattern: rawPointer))
        case ascii("{"), ascii("("):
            guard let value = asStruct, value.words.count * 4 >= size else {
                fatalError("\(selector): expected a struct of \(size) bytes")
            }
            words.append(contentsOf: value.words.prefix((size + 3) / 4))
        default:
            // char, BOOL, short, int, long and their unsigned forms: one word.
            words.append(UInt(bitPattern: asInt ?? 0))
        }
    }

    /// An object, selector or pointer argument's address.
    var rawPointer: UnsafeMutableRawPointer? {
        switch storage {
        case .object(let object): return object?.pointer
        case .selector(let pointer), .pointer(let pointer): return pointer
        default: return nil
        }
    }

    /// A message's result, typed from the method's return type.
    init(returnType: CChar, size: Int, result: (UInt, UInt), structWords: [UInt]?, owned: Bool) {
        let (low, high) = result
        switch returnType {
        case ascii("v"):
            storage = .void
        case ascii("@"), ascii("#"):
            let pointer = UnsafeMutableRawPointer(bitPattern: low)
            storage = .object(pointer.map { owned ? ObjCObject(adopting: $0) : ObjCObject(retaining: $0) })
        case ascii(":"):
            storage = .selector(UnsafeMutableRawPointer(bitPattern: low))
        case ascii("*"), ascii("^"):
            storage = .pointer(UnsafeMutableRawPointer(bitPattern: low))
        case ascii("B"):
            storage = .bool(low & 0xFF != 0)
        case ascii("c"):
            storage = .int(Int(Int8(truncatingIfNeeded: low)))
        case ascii("C"):
            storage = .int(Int(UInt8(truncatingIfNeeded: low)))
        case ascii("s"):
            storage = .int(Int(Int16(truncatingIfNeeded: low)))
        case ascii("S"):
            storage = .int(Int(UInt16(truncatingIfNeeded: low)))
        case ascii("q"), ascii("Q"):
            storage = .int64(Int64(bitPattern: UInt64(high) << 32 | UInt64(low)))
        case ascii("f"):
            storage = .double(Double(Float(bitPattern: UInt32(truncatingIfNeeded: low))))
        case ascii("d"):
            storage = .double(Double(bitPattern: UInt64(high) << 32 | UInt64(low)))
        case ascii("{"), ascii("("):
            storage = .structure(ObjCStruct(words: structWords ?? [low]))
        default:
            storage = .int(Int(bitPattern: low))
        }
    }
}

/// Objective-C's memory management families, from a selector's first word.
enum MethodFamily {
    case owning, initializer, other

    init(_ selector: String) {
        var name = Substring(selector)
        while name.hasPrefix("_") { name = name.dropFirst() }
        func starts(_ word: String) -> Bool {
            guard name.hasPrefix(word) else { return false }
            // The word must end there: "newline" isn't in the new family.
            let rest = name.dropFirst(word.utf8.count)
            guard let next = rest.utf8.first else { return true }
            return !(next >= UInt8(ascii: "a") && next <= UInt8(ascii: "z"))
        }
        if starts("init") {
            self = .initializer
        } else if starts("alloc") || starts("new") || starts("copy") || starts("mutableCopy") {
            self = .owning
        } else {
            self = .other
        }
    }
}

// MARK: - Helpers

func ascii(_ character: Unicode.Scalar) -> CChar {
    CChar(bitPattern: UInt8(ascii: character))
}

func byte<T>(_ tuple: T, _ index: Int) -> CChar {
    withUnsafeBytes(of: tuple) { CChar(bitPattern: $0[index]) }
}

func long<T>(_ tuple: T, _ index: Int) -> Int {
    withUnsafeBytes(of: tuple) { $0.load(fromByteOffset: index * MemoryLayout<Int>.size, as: Int.self) }
}

/// Calls `body` with `string` as a NUL-terminated C string.
func withCString<Result>(_ string: String, _ body: (UnsafePointer<CChar>) -> Result) -> Result {
    var bytes: [CChar] = []
    for byte in string.utf8 { bytes.append(CChar(bitPattern: byte)) }
    bytes.append(0)
    return bytes.withUnsafeBufferPointer { body($0.baseAddress!) }
}

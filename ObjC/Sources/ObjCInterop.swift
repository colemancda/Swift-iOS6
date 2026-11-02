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
//
// Swift can also define Objective-C classes, for delegates, targets and
// overrides:
//
//     let target = ObjC.defineClass("Target", superclass: "NSObject") { cls in
//         cls.method("fire:") { call in print("fired by \(call[0].className ?? "?")") }
//     }

/// The Objective-C classes, by name: `ObjC.NSString`.
public let ObjC = ObjCRuntime()

@dynamicMemberLookup
public struct ObjCRuntime {
    /// The class with this name, or nil.
    public subscript(dynamicMember name: String) -> ObjCValue {
        classNamed(name)
    }

    public func classNamed(_ name: String) -> ObjCValue {
        ObjCValue(object: ObjCCache.classNamed(name))
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

    /// Doesn't retain or release: for `self` in dealloc.
    init(borrowing pointer: UnsafeMutableRawPointer) {
        self.pointer = pointer
        owned = false
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
    /// Wraps (and retains) an object pointer, such as one C code returned.
    public init(object pointer: UnsafeMutableRawPointer?) { storage = .object(pointer.map { ObjCObject(retaining: $0) }) }
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
        return ObjCCache.signature(object.pointer, ObjCCache.selector(selector)) != nil
    }

    /// Sends `selector` to the implementation in the superclass of `cls`, for
    /// a method of a class defined from Swift.
    @discardableResult
    public func sendSuper(_ selector: String, from cls: ObjCValue, _ arguments: [any ObjCConvertible]) -> ObjCValue {
        var values: [ObjCValue] = []
        for argument in arguments { values.append(argument.objcValue) }
        return ObjCValue.send(selector, to: self, values, superclass: cls.asObject?.pointer)
    }

    /// objc_setAssociatedObject (retained): keeps `value` alive as long as this object.
    public func setAssociated(_ value: ObjCValue, for key: ObjCAssociationKey) {
        guard let object = asObject else { return }
        objcrt_set_associated(object.pointer, key.pointer, value.rawPointer)
    }

    public func associated(_ key: ObjCAssociationKey) -> ObjCValue {
        guard let object = asObject else { return nil }
        return ObjCValue(object: objcrt_get_associated(object.pointer, key.pointer))
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
    static func send(_ selectorName: String, to receiver: ObjCValue, _ arguments: [ObjCValue],
                     superclass: UnsafeMutableRawPointer? = nil) -> ObjCValue {
        // Messages to nil return nil, as in Objective-C.
        guard let target = receiver.asObject else { return nil }
        let selector = ObjCCache.selector(selectorName)
        guard let signature = ObjCCache.signature(target.pointer, selector) else {
            fatalError("-[\(target.className) \(selectorName)]: unrecognized selector")
        }
        guard signature.types.count == arguments.count else {
            fatalError("-[\(target.className) \(selectorName)] takes \(signature.types.count) arguments, not \(arguments.count)")
        }

        // C strings passed as char * live until the message returns.
        var buffers: [UnsafeMutablePointer<CChar>] = []
        defer { for buffer in buffers { buffer.deallocate() } }

        var words: [UInt] = []
        for index in 0..<arguments.count {
            arguments[index].appendWords(to: &words, type: signature.types[index], size: signature.sizes[index],
                                         buffers: &buffers, selector: selectorName)
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
                    superclass: superclass,
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

// MARK: - Caches

/// A method's argument and return types, from objcrt_signature.
struct ObjCSignature {
    let returnType: CChar
    let returnSize: Int
    let types: [CChar]
    let sizes: [Int]
}

/// Selectors, classes and method signatures, looked up once: layout code
/// sends thousands of messages per render.
enum ObjCCache {
    static var selectors: [String: UnsafeMutableRawPointer] = [:]
    static var classes: [String: UnsafeMutableRawPointer] = [:]
    static var signatures: [UInt64: ObjCSignature] = [:]

    static func selector(_ name: String) -> UnsafeMutableRawPointer {
        if let selector = selectors[name] { return selector }
        let selector = withCString(name) { objcrt_selector($0) }!
        selectors[name] = selector
        return selector
    }

    static func classNamed(_ name: String) -> UnsafeMutableRawPointer? {
        if let cls = classes[name] { return cls }
        guard let cls = withCString(name, { objcrt_class($0) }) else { return nil }
        classes[name] = cls
        return cls
    }

    static func key(_ cls: UnsafeMutableRawPointer, _ selector: UnsafeMutableRawPointer) -> UInt64 {
        UInt64(UInt(bitPattern: cls)) << 32 | UInt64(UInt(bitPattern: selector))
    }

    /// The types of the method `object` runs for `selector`, or nil if it
    /// doesn't respond to it.
    static func signature(_ object: UnsafeMutableRawPointer, _ selector: UnsafeMutableRawPointer) -> ObjCSignature? {
        guard let cls = objcrt_object_class(object) else { return nil }
        let cacheKey = key(cls, selector)
        if let signature = signatures[cacheKey] { return signature }
        var raw = ObjCRTSignature()
        guard objcrt_signature(object, selector, &raw) == 0 else { return nil }
        var types: [CChar] = []
        var sizes: [Int] = []
        for index in 0..<raw.argumentCount {
            types.append(byte(raw.argumentTypes, index))
            sizes.append(long(raw.argumentSizes, index))
        }
        let signature = ObjCSignature(returnType: raw.returnType, returnSize: raw.returnSize, types: types, sizes: sizes)
        signatures[cacheKey] = signature
        return signature
    }
}

/// A key for setAssociated(_:for:): its address identifies it.
public final class ObjCAssociationKey {
    let pointer: UnsafeMutableRawPointer

    public init() {
        pointer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    }
}

// MARK: - Defining classes

extension ObjCRuntime {
    /// Defines an Objective-C class whose methods are Swift closures, and
    /// returns it. If a class of that name exists, returns it unchanged.
    @discardableResult
    public func defineClass(_ name: String, superclass: String = "NSObject",
                            _ build: (ObjCClassBuilder) -> Void) -> ObjCValue {
        if let existing = ObjCCache.classNamed(name) { return ObjCValue(object: existing) }
        ObjCMethods.install()
        guard let parent = ObjCCache.classNamed(superclass),
              let cls = withCString(name, { objcrt_allocate_class($0, parent) }) else {
            fatalError("can't define \(name): no superclass \(superclass)")
        }
        build(ObjCClassBuilder(pointer: cls))
        objcrt_register_class(cls)
        ObjCCache.classes[name] = cls
        return ObjCValue(object: cls)
    }
}

/// Adds methods and protocols to a class being defined.
public final class ObjCClassBuilder {
    public let pointer: UnsafeMutableRawPointer
    var protocols: [String] = []

    init(pointer: UnsafeMutableRawPointer) {
        self.pointer = pointer
    }

    /// Adopts a protocol, whose methods' types `method` can then use.
    /// Returns false if the runtime doesn't know the protocol: only protocols
    /// some loaded code refers to are registered, so give such methods `types`.
    @discardableResult
    public func conform(to protocolName: String) -> Bool {
        guard withCString(protocolName, { objcrt_add_protocol(pointer, $0) }) == 0 else { return false }
        protocols.append(protocolName)
        return true
    }

    /// Implements a method that returns nothing.
    public func method(_ selector: String, types: String? = nil, fallbackTypes: String? = nil,
                       _ body: @escaping (ObjCMethodCall) -> Void) {
        function(selector, types: types, fallbackTypes: fallbackTypes) { call in
            body(call)
            return ObjCValue(storage: .void)
        }
    }

    /// Implements a method that returns a value. Its types come from `types`, else the superclass
    /// (an override), else an adopted protocol, else `fallbackTypes`, else
    /// they're objects returning void: "v@:" plus "@" for each colon.
    public func function(_ selector: String, types: String? = nil, fallbackTypes: String? = nil,
                         _ body: @escaping (ObjCMethodCall) -> ObjCValue) {
        let sel = ObjCCache.selector(selector)
        var encoding = types
        if encoding == nil, let inherited = objcrt_method_types(pointer, sel) {
            encoding = String(cString: inherited)
        }
        if encoding == nil {
            for name in protocols {
                if let found = withCString(name, { objcrt_protocol_method_types($0, sel) }) {
                    encoding = String(cString: found)
                    break
                }
            }
        }
        if encoding == nil { encoding = fallbackTypes }
        if encoding == nil {
            var defaults = "v@:"
            for byte in selector.utf8 where byte == UInt8(ascii: ":") { defaults += "@" }
            encoding = defaults
        }
        if withCString(encoding!, { objcrt_add_method(pointer, sel, $0) }) != 0 {
            fatalError("can't add \(selector) with types \(encoding!)")
        }
        ObjCMethods.handlers[ObjCCache.key(pointer, sel)] = ObjCMethodHandler(definingClass: pointer, selector: selector, body: body)
    }
}

/// One call of a method defined from Swift.
public struct ObjCMethodCall {
    /// The receiver (self).
    public let this: ObjCValue
    public let arguments: [ObjCValue]
    public let selector: String
    let definingClass: UnsafeMutableRawPointer

    /// An argument, or nil past the end.
    public subscript(index: Int) -> ObjCValue {
        index < arguments.count ? arguments[index] : nil
    }

    /// Sends this message to the superclass's implementation, with the same arguments.
    @discardableResult
    public func callSuper() -> ObjCValue {
        ObjCValue.send(selector, to: this, arguments, superclass: definingClass)
    }

    /// Sends this message to the superclass's implementation, with other arguments.
    @discardableResult
    public func callSuper(_ arguments: any ObjCConvertible...) -> ObjCValue {
        var values: [ObjCValue] = []
        for argument in arguments { values.append(argument.objcValue) }
        return ObjCValue.send(selector, to: this, values, superclass: definingClass)
    }
}

final class ObjCMethodHandler {
    let definingClass: UnsafeMutableRawPointer
    let selector: String
    let body: (ObjCMethodCall) -> ObjCValue

    init(definingClass: UnsafeMutableRawPointer, selector: String, body: @escaping (ObjCMethodCall) -> ObjCValue) {
        self.definingClass = definingClass
        self.selector = selector
        self.body = body
    }
}

enum ObjCMethods {
    /// By class and selector.
    static var handlers: [UInt64: ObjCMethodHandler] = [:]
    static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        objcrt_set_handler { object, selector, words, result, structResult in
            guard let object, let selector, let words else { return }
            ObjCMethods.run(object, selector, words, result, structResult)
        }
    }

    /// Runs the Swift implementation for a message to a defined class (or a subclass of one).
    static func run(_ object: UnsafeMutableRawPointer, _ selector: UnsafeMutableRawPointer, _ words: UnsafePointer<UInt>,
                    _ result: UnsafeMutablePointer<UInt>?, _ structResult: UnsafeMutableRawPointer?) {
        var cls = objcrt_object_class(object)
        var handler: ObjCMethodHandler?
        while let current = cls, handler == nil {
            handler = handlers[ObjCCache.key(current, selector)]
            cls = objcrt_superclass(current)
        }
        guard let handler, let signature = ObjCCache.signature(object, selector) else { return }

        var arguments: [ObjCValue] = []
        var index = 0
        for (type, size) in zip(signature.types, signature.sizes) {
            let count = ObjCValue.wordCount(type: type, size: size)
            var argumentWords: [UInt] = []
            for offset in 0..<count where index + offset < ObjCRTMaxWords { argumentWords.append(words[index + offset]) }
            index += count
            let high = argumentWords.count > 1 ? argumentWords[1] : 0
            arguments.append(ObjCValue(returnType: type, size: size, result: (argumentWords.first ?? 0, high),
                                       structWords: argumentWords, owned: false))
        }

        // self isn't retained during dealloc, where it can't be revived.
        let this = handler.selector == "dealloc" ? ObjCObject(borrowing: object) : ObjCObject(retaining: object)
        let value = handler.body(ObjCMethodCall(this: ObjCValue(this), arguments: arguments, selector: handler.selector,
                                                definingClass: handler.definingClass))

        let returnType = signature.returnType
        if returnType == ascii("v") { return }
        if returnType == ascii("@"), let returned = value.asObject {
            // Returned objects outlive `value`: owned (+1) for the alloc, new,
            // copy and init families, autoreleased otherwise.
            _ = objcrt_retain(returned.pointer)
            if MethodFamily(handler.selector) == .other { objcrt_autorelease(returned.pointer) }
        }
        var buffers: [UnsafeMutablePointer<CChar>] = []
        var resultWords: [UInt] = []
        value.appendWords(to: &resultWords, type: returnType, size: signature.returnSize, buffers: &buffers,
                          selector: handler.selector)
        if let structResult {
            let bytes = structResult.assumingMemoryBound(to: UInt.self)
            for (offset, word) in resultWords.enumerated() { bytes[offset] = word }
        } else if let result {
            result[0] = resultWords.first ?? 0
            result[1] = resultWords.count > 1 ? resultWords[1] : 0
        }
    }
}

extension ObjCValue {
    /// How many words an argument of this type takes.
    static func wordCount(type: CChar, size: Int) -> Int {
        switch type {
        case ascii("d"), ascii("q"), ascii("Q"): return 2
        case ascii("{"), ascii("("): return max(1, (size + 3) / 4)
        default: return 1
        }
    }
}

// MARK: - Macros

/// A typed wrapper around an Objective-C object:
///
///     @ObjC("UILabel")
///     struct UILabel {
///         @ObjCMethod init(frame: CGRect)
///         @ObjCProperty var text: String?
///         @ObjCMethod func sizeThatFits(_ size: CGSize) -> CGSize
///     }
///
/// Adds `object`, `init(_ object: ObjCValue)` and `objcClass`, and makes
/// the type an ObjCWrapper. The class name defaults to the type's name.
@attached(member, names: named(object), named(init), named(objcClass))
@attached(extension, conformances: ObjCWrapper)
public macro ObjC(_ className: String? = nil) = #externalMacro(module: "ObjCMacros", type: "ObjCClassMacro")

/// Without a body: sends the message, with the selector from the name and
/// labels (or the one given), and converts the result to the return type.
/// On a static method it messages the class; on an initializer it sends
/// alloc and init… to the class. With a body, in an @ObjCImplementation
/// class: the class exports the method to Objective-C.
@attached(body)
public macro ObjCMethod(_ selector: String? = nil) = #externalMacro(module: "ObjCMacros", type: "ObjCMethodMacro")

/// Getter and setter messages for a property: `text` and `setText:` by default.
@attached(accessor)
public macro ObjCProperty(getter: String? = nil, setter: String? = nil, readonly: Bool = false) =
    #externalMacro(module: "ObjCMacros", type: "ObjCPropertyMacro")

/// Defines an Objective-C class implemented by this Swift class: each
/// @ObjCMethod method becomes a method of `objcClass`, converting its
/// arguments and result. See ObjCImplementationMacro for how instances are tied.
@attached(member, names: named(objcInstances), named(objcPointer), named(object), named(objcClass), named(attach),
          named(objcInstance), named(callSuper))
@attached(extension, conformances: ObjCConvertible, names: named(objcValue))
public macro ObjCImplementation(_ className: String? = nil, superclass: String = "NSObject") =
    #externalMacro(module: "ObjCMacros", type: "ObjCImplementationMacro")

// MARK: - Typed results

/// A Swift type a message result or a method argument converts to.
public protocol ObjCResult {
    init(objcValue: ObjCValue)
}

/// Converts a message result to the type the context expects.
public func objcResult<T: ObjCResult>(_ value: ObjCValue) -> T {
    T(objcValue: value)
}

extension ObjCValue: ObjCResult {
    public init(objcValue: ObjCValue) { self = objcValue }
}

extension Int: ObjCResult {
    public init(objcValue: ObjCValue) { self = objcValue.asInt ?? 0 }
}

extension Int32: ObjCResult {
    public init(objcValue: ObjCValue) { self = Int32(truncatingIfNeeded: objcValue.asInt ?? 0) }
}

extension UInt: ObjCResult {
    public init(objcValue: ObjCValue) { self = UInt(bitPattern: objcValue.asInt ?? 0) }
}

extension Int64: ObjCResult {
    public init(objcValue: ObjCValue) { self = objcValue.asInt64 ?? 0 }
}

extension Double: ObjCResult {
    public init(objcValue: ObjCValue) { self = objcValue.asDouble ?? 0 }
}

extension Float: ObjCResult {
    public init(objcValue: ObjCValue) { self = Float(objcValue.asDouble ?? 0) }
}

extension Bool: ObjCResult {
    public init(objcValue: ObjCValue) { self = objcValue.asBool ?? false }
}

extension String: ObjCResult {
    /// An NSString's contents, or "" for nil.
    public init(objcValue: ObjCValue) { self = objcValue.asString ?? "" }
}

extension Optional: ObjCResult where Wrapped: ObjCResult {
    public init(objcValue: ObjCValue) {
        self = objcValue.isNil ? nil : Wrapped(objcValue: objcValue)
    }
}

/// A Swift type that wraps an Objective-C object; @ObjC makes one.
public protocol ObjCWrapper: ObjCConvertible, ObjCResult {
    var object: ObjCValue { get }
    init(_ object: ObjCValue)
    static var objcClass: ObjCValue { get }
}

extension ObjCWrapper {
    public var objcValue: ObjCValue { object }
    public init(objcValue: ObjCValue) { self.init(objcValue) }

    /// Whether the object is nil.
    public var isNil: Bool { object.isNil }

    /// The same object as another wrapper type, such as a UILabel as a UIView.
    public func `as`<T: ObjCWrapper>(_ type: T.Type) -> T { T(object) }
}

// MARK: - Geometry

/// Core Graphics and Foundation structs as they are on armv7 (CGFloat is a
/// 32-bit float), passed and returned by value.
public struct CGPoint: Equatable, ObjCConvertible, ObjCResult {
    public var x: Float
    public var y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
    public var objcValue: ObjCValue { .point(x: x, y: y) }
    public init(objcValue: ObjCValue) {
        let words = objcValue.asStruct
        self.init(x: words?.float(at: 0) ?? 0, y: words?.float(at: 1) ?? 0)
    }
}

public struct CGSize: Equatable, ObjCConvertible, ObjCResult {
    public var width: Float
    public var height: Float
    public init(width: Float, height: Float) { self.width = width; self.height = height }
    public var objcValue: ObjCValue { .size(width: width, height: height) }
    public init(objcValue: ObjCValue) {
        let words = objcValue.asStruct
        self.init(width: words?.float(at: 0) ?? 0, height: words?.float(at: 1) ?? 0)
    }
}

public struct CGRect: Equatable, ObjCConvertible, ObjCResult {
    public var origin: CGPoint
    public var size: CGSize
    public init(x: Float, y: Float, width: Float, height: Float) {
        origin = CGPoint(x: x, y: y)
        size = CGSize(width: width, height: height)
    }
    public var objcValue: ObjCValue { .rect(x: origin.x, y: origin.y, width: size.width, height: size.height) }
    public init(objcValue: ObjCValue) {
        let words = objcValue.asStruct
        self.init(x: words?.float(at: 0) ?? 0, y: words?.float(at: 1) ?? 0,
                  width: words?.float(at: 2) ?? 0, height: words?.float(at: 3) ?? 0)
    }
}

public struct NSRange: Equatable, ObjCConvertible, ObjCResult {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var objcValue: ObjCValue { .range(location: location, length: length) }
    public init(objcValue: ObjCValue) {
        let words = objcValue.asStruct
        self.init(location: words?.int(at: 0) ?? 0, length: words?.int(at: 1) ?? 0)
    }
}

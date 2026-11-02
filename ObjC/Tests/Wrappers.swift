// Typed wrappers and a Swift-implemented class, written with the macros.

import ObjCInterop

@ObjC("NSString")
struct NSString {
    @ObjCMethod static func stringWithString(_ string: String) -> NSString
    @ObjCMethod func uppercaseString() -> String
    @ObjCMethod func hasPrefix(_ prefix: String) -> Bool
    @ObjCMethod func rangeOfString(_ string: String) -> NSRange
    @ObjCMethod func stringByReplacingOccurrencesOfString(_ target: String, withString replacement: String) -> NSString
    @ObjCProperty(readonly: true) var length: Int
    @ObjCProperty(getter: "UTF8String", readonly: true) var utf8Pointer: ObjCValue
}

@ObjC("NSMutableArray")
struct NSMutableArray {
    @ObjCMethod init()
    @ObjCMethod func addObject(_ object: ObjCValue)
    @ObjCMethod func objectAtIndex(_ index: Int) -> ObjCValue
    @ObjCProperty(readonly: true) var count: Int
    @ObjCMethod func componentsJoinedByString(_ separator: String) -> String
}

@ObjC("NSNumber")
struct NSNumber {
    @ObjCMethod static func numberWithDouble(_ value: Double) -> NSNumber
    @ObjCMethod static func numberWithLongLong(_ value: Int64) -> NSNumber
    @ObjCProperty(readonly: true) var doubleValue: Double
    @ObjCProperty(readonly: true) var longLongValue: Int64
}

@ObjC("NSNotificationCenter")
struct NSNotificationCenter {
    @ObjCMethod static func defaultCenter() -> NSNotificationCenter
    @ObjCMethod func addObserver(_ observer: ObjCValue, selector: ObjCValue, name: String, object: ObjCValue)
    @ObjCMethod func postNotificationName(_ name: String, object: ObjCValue)
    @ObjCMethod func removeObserver(_ observer: ObjCValue)
}

/// A class implemented in Swift: Objective-C creates instances with
/// alloc/init (it has an init()), and calls its methods.
@ObjCImplementation("SITypedCounter")
final class Counter {
    var count = 0
    var lastName = ""
    static var deallocs = 0

    init() {}

    @ObjCMethod func increment() {
        count += 1
    }

    @ObjCMethod func add(_ amount: Int, times: Int) -> Int {
        count += amount * times
        return count
    }

    @ObjCMethod func scale(_ value: Double) -> Double {
        value * Double(count)
    }

    @ObjCMethod func received(_ notification: ObjCValue) {
        lastName = notification.name().asString ?? "?"
    }

    @ObjCMethod("description") func describe() -> String {
        "Counter at \(count)"
    }

    @ObjCMethod func dealloc() {
        Counter.deallocs += 1
    }
}

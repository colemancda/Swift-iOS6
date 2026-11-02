// Exercises ObjCInterop against Foundation and UIKit on the device.
// Run with `make test`; prints each check and a summary.

import ObjCInterop

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition { passed += 1 } else { failed += 1 }
    print("\(condition ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": " + detail)")
}

ObjC.load(framework: "UIKit")

ObjC.autoreleasepool {
    // Strings: a Swift string becomes an NSString argument.
    let greeting = ObjC.NSString.stringWithString("Hello, iOS 6")
    check("NSString round trip", greeting.asString == "Hello, iOS 6", greeting.asString ?? "nil")
    check("uppercaseString", greeting.uppercaseString().asString == "HELLO, IOS 6")
    check("length (NSUInteger)", greeting.length().asInt == 12)
    check("hasPrefix: (BOOL)", greeting.hasPrefix("Hello").asBool == true)
    check("hasPrefix: false", greeting.hasPrefix("Bye").asBool == false)
    check("char * argument", ObjC.NSString.stringWithUTF8String("café").asString == "café")
    let replaced = greeting.stringByReplacingOccurrencesOfString("iOS", withString: "Swift")
    check("two labeled arguments", replaced.asString == "Hello, Swift 6", replaced.asString ?? "nil")
    let sub = greeting.substringWithRange(.range(location: 7, length: 3))
    check("NSRange struct argument", sub.asString == "iOS", sub.asString ?? "nil")
    let found = greeting.rangeOfString("iOS").asStruct
    check("NSRange struct result", found?.int(at: 0) == 7 && found?.int(at: 1) == 3)

    // Numbers, including 64-bit and floating-point arguments and results.
    let number = ObjC.NSNumber.numberWithInt(42)
    check("NSNumber int", number.intValue().asInt == 42 && number.asInt == 42)
    let big = ObjC.NSNumber.numberWithLongLong(ObjCValue(Int64(5_000_000_000)))
    check("long long argument and result", big.longLongValue().asInt64 == 5_000_000_000, "\(big.longLongValue().asInt64 ?? 0)")
    let pi = ObjC.NSNumber.numberWithDouble(3.25)
    check("double argument and result", pi.doubleValue().asDouble == 3.25)
    let half = ObjC.NSNumber.numberWithFloat(0.5)
    check("float argument and result", half.floatValue().asDouble == 0.5)
    check("BOOL number", ObjC.NSNumber.numberWithBool(true).boolValue().asBool == true)

    // Collections.
    let array = ObjC.NSMutableArray.array()
    array.addObject("one")
    array.addObject("two")
    array.addObject(ObjC.NSNumber.numberWithInt(3))
    check("NSMutableArray count", array.count().asInt == 3)
    check("objectAtIndex:", array.objectAtIndex(1).asString == "two")
    let joined = array.componentsJoinedByString(", ")
    check("componentsJoinedByString:", joined.asString == "one, two, 3", joined.asString ?? "nil")
    let dictionary = ObjC.NSMutableDictionary.dictionary()
    dictionary.setObject("value", forKey: "key")
    check("NSMutableDictionary", dictionary.objectForKey("key").asString == "value")

    // Swift variables of any ObjCConvertible type, not just literals.
    let flag = true
    let ratio: Double = 0.75
    let count = 7
    let name: String? = "variable"
    let missing: String? = nil
    check("Bool variable", ObjC.NSNumber.numberWithBool(flag).asBool == true)
    check("Double variable", ObjC.NSNumber.numberWithDouble(ratio).asDouble == 0.75)
    check("Int variable", ObjC.NSNumber.numberWithInt(count).asInt == 7)
    check("Optional String variable", ObjC.NSString.stringWithString(name).asString == "variable")
    let holder = ObjC.NSMutableArray.array()
    holder.addObject(greeting)
    check("ObjCValue variable", holder.lastObject().asString == "Hello, iOS 6")
    let plain = ObjC.UIView.new()
    plain.setBackgroundColor(ObjC.UIColor.redColor())
    check("object argument", !plain.backgroundColor().isNil)
    plain.setBackgroundColor(ObjC.nil)
    check("ObjC.nil argument", plain.backgroundColor().isNil)
    plain.setBackgroundColor(ObjC.UIColor.blueColor())
    plain.setAccessibilityLabel(missing)
    check("nil Optional argument", plain.accessibilityLabel().isNil)

    // Classes, selectors, nil.
    check("isKind(of:)", greeting.isKind(of: "NSString") && !greeting.isKind(of: "NSArray"))
    check("respondsToSelector: with a SEL", greeting.respondsToSelector(ObjC.selector("length")).asBool == true)
    check("respondsToSelector: from a string", greeting.respondsToSelector("noSuchMethod").asBool == false)
    check("missing class is nil", ObjC.NoSuchClass.isNil)
    let nothing: ObjCValue = nil
    check("message to nil is nil", nothing.length().isNil)

    // UIKit: struct results returned through objc_msgSend_stret.
    let device = ObjC.UIDevice.currentDevice()
    let system = "\(device.systemName().asString ?? "?") \(device.systemVersion().asString ?? "?")"
    check("UIDevice", system.hasPrefix("iPhone OS ") && device.systemVersion().length().asInt ?? 0 >= 3, system)
    let view = ObjC.UIView.alloc().initWithFrame(.rect(x: 10, y: 20, width: 300, height: 400))
    let frame = view.frame().asStruct
    check("CGRect argument and stret result",
          frame?.float(at: 0) == 10 && frame?.float(at: 1) == 20 && frame?.float(at: 2) == 300 && frame?.float(at: 3) == 400)
    view.setAlpha(0.25)
    check("CGFloat argument and result", view.alpha().asDouble == 0.25)
    let color = ObjC.UIColor.colorWithRed(1, green: 0.5, blue: 0, alpha: 1)
    check("four CGFloat arguments", color.className?.hasPrefix("UI") == true, color.send("description").asString ?? "nil")
    let center = view.center().asStruct
    check("CGPoint stret result", center?.float(at: 0) == 160 && center?.float(at: 1) == 220)

    let screen = ObjC.UIScreen.mainScreen()
    let bounds = screen.bounds().asStruct
    check("UIScreen bounds", bounds?.float(at: 2) == 320 && bounds?.float(at: 3) == 480,
          "\(Int(bounds?.float(at: 2) ?? 0))×\(Int(bounds?.float(at: 3) ?? 0))")
    check("UIScreen scale", screen.scale().asDouble == 2)
}

// Ownership: alloc/init and convenience constructors in a loop; an extra
// release would crash, and a leak would grow memory.
for _ in 0..<10_000 {
    ObjC.autoreleasepool {
        let string = ObjC.NSString.alloc().initWithUTF8String("loop")
        let copy = string.copy()
        let label = ObjC.NSMutableString.stringWithString("x")
        label.appendString(copy)
    }
}
check("10,000 alloc/init/copy rounds", true)

print("\(passed) passed, \(failed) failed")

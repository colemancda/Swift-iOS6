// Exercises ObjCInterop against Foundation and UIKit on the device.
// Run with `make test`; prints each check and a summary.
//
// iOS 6 won't start UIKit outside an app (it traps in GraphicsServices), so
// there the UIKit checks are skipped; the SwiftUI apps exercise UIKit
// through the bridge instead. iOS 7 and later run them.

import ObjCInterop

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition { passed += 1 } else { failed += 1 }
    print("\(condition ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": " + detail)")
}

let osVersion = ObjC.NSProcessInfo.processInfo().operatingSystemVersionString().asString ?? ""
let hasUIKit = !osVersion.hasPrefix("Version 5.") && !osVersion.hasPrefix("Version 6.")
if hasUIKit {
    ObjC.load(framework: "UIKit")
} else {
    print("SKIP UIKit checks: UIKit can't start outside an app on \(osVersion)")
}

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
    // setValue:forKey: with nil removes the key.
    let values = ObjC.NSMutableDictionary.dictionary()
    values.setObject("a", forKey: "first")
    values.setObject("b", forKey: "second")
    values.setValue(ObjC.nil, forKey: "first")
    check("ObjC.nil argument", values.objectForKey("first").isNil && values.count().asInt == 1)
    values.setValue(missing, forKey: "second")
    check("nil Optional argument", values.count().asInt == 0)

    // Classes, selectors, nil.
    check("isKind(of:)", greeting.isKind(of: "NSString") && !greeting.isKind(of: "NSArray"))
    check("respondsToSelector: with a SEL", greeting.respondsToSelector(ObjC.selector("length")).asBool == true)
    check("respondsToSelector: from a string", greeting.respondsToSelector("noSuchMethod").asBool == false)
    check("missing class is nil", ObjC.NoSuchClass.isNil)
    let nothing: ObjCValue = nil
    check("message to nil is nil", nothing.length().isNil)

}

func uikitChecks() {
    // UIKit: struct results returned through objc_msgSend_stret.
    let plain = ObjC.UIView.new()
    plain.setBackgroundColor(ObjC.UIColor.redColor())
    check("object argument", !plain.backgroundColor().isNil)
    plain.setBackgroundColor(ObjC.nil)
    check("ObjC.nil argument to UIKit", plain.backgroundColor().isNil)

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

    // What the SwiftUI backend does for a Text.
    let label = ObjC.UILabel.new()
    label.setText(ObjC.NSString.stringWithUTF8String("Jupiter"))
    label.setNumberOfLines(0)
    label.setFont(ObjC.UIFont.systemFontOfSize(17))
    check("label text set", label.text().asString == "Jupiter", label.text().asString ?? "nil")
    let fitted = label.sizeThatFits(.size(width: 288, height: 100000)).asStruct
    check("label sizeThatFits", (fitted?.float(at: 0) ?? 0) > 20 && (fitted?.float(at: 1) ?? 0) > 10,
          "\(fitted?.float(at: 0) ?? -1) × \(fitted?.float(at: 1) ?? -1)")
    label.setFrame(.rect(x: 16, y: 11, width: 60, height: 21))
    let labelFrame = label.frame().asStruct
    check("label frame", labelFrame?.float(at: 2) == 60, "\(labelFrame?.float(at: 2) ?? -1)")

    let screen = ObjC.UIScreen.mainScreen()
    let bounds = screen.bounds().asStruct
    check("UIScreen bounds", bounds?.float(at: 2) == 320 && bounds?.float(at: 3) == 480,
          "\(Int(bounds?.float(at: 2) ?? 0))×\(Int(bounds?.float(at: 3) ?? 0))")
    check("UIScreen scale", screen.scale().asDouble == 2)
}

if hasUIKit { ObjC.autoreleasepool { uikitChecks() } }

// Classes defined from Swift.
var notified = 0
var notificationName = ""
var layouts = 0
var deallocs = 0

ObjC.autoreleasepool {
    // A target for target-action and notifications.
    let observerClass = ObjC.defineClass("SITestObserver") { cls in
        cls.method("received:") { call in
            notified += 1
            notificationName = call[0].name().asString ?? "?"
        }
        cls.method("dealloc") { call in
            deallocs += 1
            call.callSuper()
        }
    }
    let observer = observerClass.new()
    let center = ObjC.NSNotificationCenter.defaultCenter()
    center.addObserver(observer, selector: ObjC.selector("received:"), name: "SITest", object: ObjC.nil)
    center.postNotificationName("SITest", object: ObjC.nil)
    center.postNotificationName("SITest", object: ObjC.nil)
    check("method called from Objective-C", notified == 2, "\(notified)")
    check("object argument decoded", notificationName == "SITest", notificationName)
    center.removeObserver(observer)

    // New methods with explicit types: numbers and objects in and out.
    let mathClass = ObjC.defineClass("SITestMath") { cls in
        cls.function("answer", types: "i@:") { _ in 42 }
        cls.function("multiply:by:", types: "d@:dd") { call in
            ObjCValue((call[0].asDouble ?? 0) * (call[1].asDouble ?? 0))
        }
        cls.function("greet:", types: "@@:@") { call in
            ObjC.NSString.stringWithString("Hello, \(call[0].asString ?? "?")")
        }
        cls.function("halve:", types: "f@:f") { call in ObjCValue((call[0].asDouble ?? 0) / 2) }
        cls.function("description") { _ in ObjC.NSString.stringWithString("SITestMath!") }
    }
    let math = mathClass.new()
    check("int result", math.answer().asInt == 42)
    check("double arguments and result", math.multiply(1.5, by: 4).asDouble == 6)
    check("float argument and result", math.halve(5).asDouble == 2.5)
    check("object argument and result", math.greet("Swift").asString == "Hello, Swift")
    check("override of an NSObject method", math.send("description").asString == "SITestMath!")

    // Associated objects keep a value alive with its owner.
    let key = ObjCAssociationKey()
    let owner = ObjC.NSObject.new()
    owner.setAssociated(ObjC.NSString.stringWithString("kept"), for: key)
    check("associated object", owner.associated(key).asString == "kept")
}
check("dealloc override runs", deallocs == 1, "\(deallocs)")

func uikitClassChecks() {
    // Overrides of a UIKit class, calling super.
    let viewClass = ObjC.defineClass("SITestView", superclass: "UIView") { cls in
        cls.method("layoutSubviews") { call in
            layouts += 1
            call.callSuper()
        }
        cls.function("sizeThatFits:") { call in
            let proposal = call[0].asStruct
            return .size(width: (proposal?.float(at: 0) ?? 0) / 2, height: 33)
        }
    }
    let view = viewClass.alloc().initWithFrame(.rect(x: 0, y: 0, width: 100, height: 100))
    let fitted = view.sizeThatFits(.size(width: 200, height: 999)).asStruct
    check("struct override through stret", fitted?.float(at: 0) == 100 && fitted?.float(at: 1) == 33)
    view.setNeedsLayout()
    view.layoutIfNeeded()
    check("layoutSubviews override", layouts == 1, "\(layouts)")
    check("defined class is a UIView", view.isKind(of: "UIView") && view.className == "SITestView")

    // Protocol methods take their types from the protocol.
    let delegateClass = ObjC.defineClass("SITestScrollDelegate") { cls in
        cls.conform(to: "UIScrollViewDelegate")
        cls.method("scrollViewDidScroll:") { _ in layouts += 100 }
    }
    let delegate = delegateClass.new()
    check("protocol method added", delegate.responds(to: "scrollViewDidScroll:"))
    let scroll = ObjC.UIScrollView.alloc().initWithFrame(.rect(x: 0, y: 0, width: 100, height: 100))
    scroll.setContentSize(.size(width: 100, height: 1000))
    scroll.setDelegate(delegate)
    scroll.setContentOffset(.point(x: 0, y: 10))
    check("delegate called by UIKit", layouts >= 101, "\(layouts)")
    scroll.setDelegate(ObjC.nil)
}

if hasUIKit { ObjC.autoreleasepool { uikitClassChecks() } }

// The same through the macros: typed wrappers and a Swift-implemented class.
ObjC.autoreleasepool {
    let greeting = NSString.stringWithString("Hello, macros")
    check("@ObjC static method and String result", greeting.uppercaseString() == "HELLO, MACROS")
    check("@ObjCProperty readonly Int", greeting.length == 13, "\(greeting.length)")
    check("Bool result", greeting.hasPrefix("Hello") && !greeting.hasPrefix("Bye"))
    check("NSRange result", greeting.rangeOfString("macros") == NSRange(location: 7, length: 6))
    check("wrapper result", greeting.stringByReplacingOccurrencesOfString("macros", withString: "Swift").uppercaseString() == "HELLO, SWIFT")
    let array = NSMutableArray()
    array.addObject(greeting.object)
    array.addObject(ObjC.NSString.stringWithString("two"))
    check("@ObjCMethod init()", array.count == 2)
    check("wrapper as argument", array.componentsJoinedByString(" + ") == "Hello, macros + two")
    check("Double through wrapper", NSNumber.numberWithDouble(2.5).doubleValue == 2.5)
    check("Int64 through wrapper", NSNumber.numberWithLongLong(6_000_000_000).longLongValue == 6_000_000_000)

    // Objective-C creates the Swift instance (alloc/init) and calls it.
    let counter = Counter.objcClass.new()
    counter.increment()
    counter.increment()
    check("@ObjCImplementation method", counter.add(5, times: 2).asInt == 12, "\(counter.add(0, times: 0).asInt ?? -1)")
    check("Double argument and result", counter.scale(0.5).asDouble == 6)
    check("override with a String result", counter.send("description").asString == "Counter at 12")
    let swiftSide = Counter.objcInstance(for: counter)
    check("Swift instance tied to the object", swiftSide?.count == 12)
    let center = NSNotificationCenter.defaultCenter()
    center.addObserver(counter, selector: ObjC.selector("received:"), name: "SITyped", object: ObjC.nil)
    center.postNotificationName("SITyped", object: ObjC.nil)
    check("Objective-C calls a Swift method", swiftSide?.lastName == "SITyped")
    center.removeObserver(counter)

    // Swift creates the instance and ties it to a new object.
    let manual = Counter()
    let manualObject = Counter.objcClass.new()
    manual.attach(to: manualObject)
    manualObject.increment()
    check("attach(to:)", Counter.objcInstance(for: manualObject) === manual && manual.count == 1)
}
check("@ObjCImplementation dealloc runs", Counter.deallocs >= 1, "\(Counter.deallocs)")

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

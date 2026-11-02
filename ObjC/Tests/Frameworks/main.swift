// Exercises the wrappers generated from the SDK's headers (../../../Frameworks)
// on the device. Run with `make test-frameworks`.
//
// UIKit is compiled and linked, but its checks need an app: iOS 6 won't
// start UIKit in a command-line tool.

import Foundation
import ObjCInterop
import UIKit

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition { passed += 1 } else { failed += 1 }
    print("\(condition ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": " + detail)")
}

ObjC.autoreleasepool {
    // Class methods returning Self, and String results.
    let greeting = NSString.stringWithString("Hello, generated wrappers")
    check("static factory returning Self", greeting.length == 25, "\(greeting.length)")
    check("String result", greeting.uppercaseString == "HELLO, GENERATED WRAPPERS")
    check("Bool result", greeting.hasPrefix("Hello") && !greeting.hasSuffix("Hello"))
    check("NSRange result", greeting.rangeOfString("generated") == NSRange(location: 7, length: 9))
    check("labeled arguments", greeting.stringByReplacingOccurrencesOfString("wrappers", withString: "code") == "Hello, generated code")

    // Inherited members: NSMutableString has NSString's and NSObject's.
    let text = NSMutableString.stringWithString("abc")
    text.appendString("def")
    check("subclass method", text.length == 6)
    check("inherited NSString method", text.uppercaseString == "ABCDEF")
    check("inherited NSObject property", text.description == "abcdef", text.description ?? "nil")
    check("isKindOfClass from NSObject", text.isKindOfClass(NSString.objcClass))

    // Initializers: alloc + init…, for the struct they're called on.
    let array = NSMutableArray(capacity: 4)
    array.addObject(greeting.object)
    array.addObject(NSNumber.numberWithInt(42).object)
    check("init(capacity:)", array.count == 2, "\(array.count)")
    check("inherited NSArray method", NSNumber(array.objectAtIndex(1)).intValue == 42)
    check("NSArray argument", NSArray.arrayWithArray(array).count == 2)

    let dictionary = NSMutableDictionary.dictionary()
    dictionary.setObject(greeting.object, forKey: NSString.stringWithString("key").object)
    check("NSDictionary", dictionary.count == 1 && dictionary.objectForKey(ObjCValue("key")).asString == "Hello, generated wrappers")

    // Numbers.
    let number = NSNumber.numberWithDouble(2.5)
    check("Double property", number.doubleValue == 2.5)
    check("Int64 property", NSNumber.numberWithLongLong(6_000_000_000).longLongValue == 6_000_000_000)
    check("Bool through NSNumber", NSNumber.numberWithBool(true).boolValue)

    // Nullable results, custom getters, and structs.
    let manager = NSFileManager.defaultManager()
    check("nonexistent file", !manager.fileExistsAtPath("/no/such/file"))
    check("existing file", manager.fileExistsAtPath("/System/Library/CoreServices/SystemVersion.plist"))
    let names = manager.contentsOfDirectoryAtPath("/System/Library/CoreServices", error: ObjC.nil)
    check("nullable wrapper result", (names?.count ?? 0) > 0, "\(names?.count ?? -1) entries")
    check("nil result", manager.contentsOfDirectoryAtPath("/no/such/dir", error: ObjC.nil) == nil)
    let version = NSDictionary.dictionaryWithContentsOfFile("/System/Library/CoreServices/SystemVersion.plist")
    let product = version?.objectForKey(ObjCValue("ProductVersion")).asString ?? ""
    check("dictionary from a file", product.hasPrefix("6.") || product.hasPrefix("9."), product)

    let info = NSProcessInfo.processInfo()
    check("NSProcessInfo", info.processorCount >= 1 && info.physicalMemory > 0,
          "\(info.processorCount) CPU, \(info.physicalMemory / 1_048_576) MB, \(info.operatingSystemVersionString)")
    check("process name", info.processName == "framework-tests", info.processName)

    let url = NSURL.URLWithString("http://example.com/path/file.xml?x=1")
    check("NSURL properties", url?.host == "example.com" && url?.path == "/path/file.xml" && url?.query == "x=1")
    check("init(string:)", NSURL(string: "http://example.com").scheme == "http")

    let now = NSDate.date()
    let later = now.dateByAddingTimeInterval(60)
    check("Double argument and result", later.timeIntervalSinceDate(now) == 60)
    check("Int result from compare", now.compare(later) == -1)

    let data = NSString.stringWithString("bytes").dataUsingEncoding(4)
    check("NSData", data?.length == 5)
    check("init(data:encoding:)", NSString(data: data!, encoding: 4).length == 5)

    let uuid = NSUUID.UUID()
    check("NSUUID (iOS 6)", uuid.UUIDString.utf8.count == 36, uuid.UUIDString)

    // Methods that take blocks take Swift closures.
    let numbers = NSMutableArray(capacity: 4)
    for value in [5, 3, 9, 1] { numbers.addObject(NSNumber.numberWithInt(value).object) }
    var seen: [Int] = []
    numbers.enumerateObjectsUsingBlock { object, index, stop in
        seen.append(NSNumber(object).intValue)
        if index == 2 { stop.setPointee(true) }
    }
    check("closure: enumerate with stop", seen == [5, 3, 9])
    let sorted = numbers.sortedArrayUsingComparator { a, b in
        let x = NSNumber(a).intValue, y = NSNumber(b).intValue
        return x < y ? -1 : (x > y ? 1 : 0)
    }
    check("closure: comparator", sorted.componentsJoinedByString(",") == "1,3,5,9")
    check("closure: Bool result", numbers.indexesOfObjectsPassingTest { object, _, _ in NSNumber(object).intValue > 4 }.count == 2)
    var words: [String] = []
    NSString.stringWithString("Blocks from generated wrappers")
        .enumerateSubstringsInRange(NSRange(location: 0, length: 30), options: 3) { word, range, _, _ in
            words.append("\(word ?? "?")@\(range.location)")
        }
    check("closure: String? and NSRange arguments", words == ["Blocks@0", "from@7", "generated@12", "wrappers@22"],
          words.joined(separator: " "))
    var ran = false
    NSBlockOperation.blockOperationWithBlock { ran = true }.start()
    check("closure: kept and run later", ran)

    // UIKit types exist and inherit, without running UIKit.
    check("UIKit class names", UILabel.objcClass.isNil == ObjC.UILabel.isNil)
}

print("\(passed) passed, \(failed) failed")

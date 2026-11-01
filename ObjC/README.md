# ObjCInterop

Objective-C messaging for Embedded Swift, which has no Objective-C interop.
Swift code can use UIKit, Foundation and private frameworks directly, without
an Objective-C wrapper file:

```swift
import ObjCInterop

let label = ObjC.UILabel.alloc().initWithFrame(.rect(x: 20, y: 20, width: 280, height: 44))
label.setText("Hello from Swift")
label.setTextColor(ObjC.UIColor.colorWithRed(0.2, green: 0.4, blue: 0.8, alpha: 1))

let version = ObjC.UIDevice.currentDevice().systemVersion().asString   // "6.1.6"
let title = greeting.stringByReplacingOccurrencesOfString("iOS", withString: "Swift")
application.setIdleTimerDisabled(keepAwake)                             // a Swift Bool
```

It's built on `@dynamicMemberLookup` and `@dynamicCallable`:

- **Classes:** `ObjC.Name` looks up a class (nil if there's none).
  `ObjC.load(framework: "BluetoothManager")` loads a public or private
  framework first.
- **Messages:** on any value, `.name(arguments)` sends a message. The selector
  is the name followed by one `label:` per argument, and the first argument is
  unlabeled. So `setTitle("Go", forState: 0)` sends `setTitle:forState:`, and
  `length()` sends `length`.
- **Arguments:**
  - Literals, or Swift values of any `ObjCConvertible` type: `Int`, `Int64`,
    `Double`, `Float`, `Bool`, `String`, optionals of these, `ObjCValue`.
  - Structs: `.rect(x:y:width:height:)`, `.point`, `.size`, `.range`.
  - nil: `ObjC.nil`. A selector: `ObjC.selector("name")`.
- **Results** are `ObjCValue`s. Send them more messages, or read them with
  `asString` (NSString), `asInt`, `asInt64`, `asDouble`, `asBool` (also
  NSNumber), `asStruct`, `asObject`, `isNil`, `isKind(of:)` and
  `responds(to:)`.
- **Name clashes:** a selector that clashes with a Swift keyword or one of
  those names is sent with `send("init")` or `send("setValue:forKey:", v, k)`.

## How it works

```
Swift: label.setText("Hello")
  └─ ObjCValue / ObjCMessage   Sources/ObjCInterop.swift (Embedded Swift)
       └─ ObjCRuntime.h        objcrt_signature, objcrt_send… (pointers and longs)
            └─ ObjCRuntime.c   objc_msgSend / objc_msgSend_stret, built for iOS
```

1. **Building the selector:** `@dynamicMemberLookup` turns `label.setText` into
   an `ObjCMessage`. `@dynamicCallable` collects the arguments and builds the
   selector from the labels.
2. **Converting the arguments:** the runtime gives the method's type encoding
   (`method_getArgumentType`, `NSGetSizeAndAlignment`), and each argument is
   converted to what its parameter takes:
   - A Swift string becomes an autoreleased NSString for `@`, a C string for
     `*`, and a selector for `:`.
   - A number becomes a float for `f` (CGFloat on armv7), two words for `d` or
     `q`, and one word for an int or BOOL.
   - A struct is its words.
3. **One call for every signature:** on armv7 iOS, every argument travels as
   32-bit words. Floats go in integer registers, and 64-bit values and structs
   go in consecutive words. So `objcrt_send` calls `objc_msgSend` with 16 words
   for any signature, and the callee reads the ones it takes. Struct results
   larger than 4 bytes (CGRect, CGPoint) go through `objc_msgSend_stret`.
4. **Typing the result** from the return encoding: objects, integers of each
   size, BOOL, float and double, selectors, pointers and structs.
5. **Memory:** an `ObjCValue` holding an object retains it, and releases it
   when the last copy goes away. Objective-C's naming rules decide ownership:
   - `alloc`, `new`, `copy` and `mutableCopy` return objects that are already
     owned.
   - `init…` consumes its receiver.
6. **r9:** the calls go through named C functions with at most four arguments,
   so in SwiftUI apps the `r9` trampolines (`../SwiftUI/tools/r9wrap.py`) cover
   them. Calling through a raw function pointer would bypass that protection.

Embedded Swift in Swift 6.4 accepts everything this needs:
`@dynamicMemberLookup`, `@dynamicCallable` with `KeyValuePairs` keyword
arguments, and `any ObjCConvertible` existentials. Older Embedded Swift only
allowed class-bound existentials.

## Using it

- **SwiftUI apps:** every app built with `../SwiftUI/Makefile` can
  `import ObjCInterop`. `../SwiftUI/Examples/Interop` reads UIDevice, UIScreen,
  NSLocale and NSTimeZone, and drives UIApplication and UIScreen from switches
  and buttons, all from Swift.
- **Tests:** `make` here builds a command-line test. `make test` runs it on the
  device (`SSH_HOST=4s SSH_CONF=…` for the iPhone 4S).

```
$ make test
PASS NSString round trip: Hello, iOS 6
PASS NSRange struct argument: iOS
PASS long long argument and result: 5000000000
PASS CGRect argument and stret result
PASS four CGFloat arguments: UIDeviceRGBColorSpace 1 0.5 0 1
…
39 passed, 0 failed
```

The tests and the Interop example have been run on the iPhone 4S (iOS 9.3.6).
They haven't run on the iPod (iOS 6.1.6) yet.

## Limits

- **No blocks:** methods that take blocks (`addObserverForName:…usingBlock:`,
  `animateWithDuration:animations:`) can't be called.
- **No new classes:** Swift can't define Objective-C classes, so it can't act
  as a delegate or a target-action receiver.
- **No variadic methods:** the type encoding doesn't describe variadic
  arguments, so `stringWithFormat:` and `arrayWithObjects:` don't work. Use
  `stringWithString:` and `addObject:` instead.
- **Exceptions crash:** an Objective-C exception (such as inserting nil into an
  array) crashes the app, because Swift can't catch it. An unknown selector or
  the wrong number of arguments stops with a message naming the method.
- **Speed:** every message looks up its method's types, which is fine for UI
  code but slower than a direct call.
- **Argument size:** at most 16 words of arguments.

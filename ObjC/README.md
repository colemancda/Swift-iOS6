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

## Typed wrappers and classes with macros

Macros give the same calls typed Swift declarations, in the style of
swift-java's `@JavaClass`, `@JavaMethod` and `@JavaImplementation`:

```swift
@ObjC("UILabel")
struct UILabel {
    @ObjCMethod init(frame: CGRect)                      // alloc + initWithFrame:
    @ObjCProperty var text: String?                      // text / setText:
    @ObjCProperty(getter: "isHidden") var hidden: Bool
    @ObjCMethod func sizeThatFits(_ size: CGSize) -> CGSize
    @ObjCMethod("setTitle:forState:") func setTitle(_ title: String, for state: Int)
    @ObjCMethod static func new() -> UILabel             // a class method
}

@ObjCImplementation("Counter", superclass: "NSObject")
final class Counter {
    var count = 0
    init() {}                                            // lets Objective-C create it
    @ObjCMethod func increment() { count += 1 }
    @ObjCMethod func add(_ amount: Int, times: Int) -> Int { count += amount * times; return count }
    @ObjCMethod("description") func describe() -> String { "Counter at \(count)" }
}
```

- **`@ObjC`** on a struct adds `object` (the `ObjCValue`), `init(_:)` and
  `objcClass`, and makes the type an `ObjCWrapper`: a message argument and
  result, convertible with `.as(UIView.self)`.
- **`@ObjCMethod` without a body** generates one. The selector is the name,
  then for the first parameter its label capitalized (nothing for `_`) and a
  colon, then `label:` for the rest, unless you pass one:
  - `setTitle(_:forState:)` becomes `setTitle:forState:`.
  - `scrollRect(toVisible:animated:)` becomes `scrollRectToVisible:animated:`.
  - `init(frame:)` becomes alloc and `initWithFrame:`.

  The result converts to the declared type: `Int`, `Int64`, `Double`, `Float`,
  `Bool`, `String`, an optional, a wrapper, a struct (`CGPoint`, `CGSize`,
  `CGRect`, `NSRange`), or `ObjCValue`.
- **`@ObjCProperty`** generates the getter and setter (`text` and `setText:`).
  It takes `getter:`, `setter:` and `readonly: true`.
- **`@ObjCImplementation`** on a class defines `objcClass`.
  - Each `@ObjCMethod` method becomes an Objective-C method that converts its
    arguments to the Swift parameter types and returns its result. The type
    encoding comes from the Swift signature, but the superclass's types win for
    an override.
  - Each Objective-C instance is tied to a Swift instance, which the object
    keeps alive until `dealloc`. If the class has an `init()`, Objective-C can
    create instances itself (alloc/init). Otherwise, create one in Swift and
    `attach(to:)` an object of `objcClass`.
  - `callSuper("selector", …)` reaches the superclass. A `@ObjCMethod func
    dealloc()` runs before the tie ends.

The macros are a compiler plugin built for the Mac against the swift-syntax
libraries the toolchain ships for its own macros (`usr/lib/swift/host`), so
there's no SwiftPM step or download. `make macros` builds
`build/plugins/libObjCMacros.dylib`, and every Swift compile loads it with
`-load-plugin-library`, including SwiftUI apps. Macros expand before Embedded
compilation, so the generated code is ordinary Embedded Swift.
`../SwiftUI/Examples/Interop/UIKit.swift` declares the UIKit and Foundation
API that example uses this way.

## Defining classes

Swift can define Objective-C classes, for delegates, target-action and
overrides of UIKit methods:

```swift
let hostClass = ObjC.defineClass("HostView", superclass: "UIView") { cls in
    cls.method("layoutSubviews") { call in
        call.callSuper()
        layout(call.this.bounds())
    }
    cls.function("sizeThatFits:") { call in      // returns a CGSize
        .size(width: 100, height: 44)
    }
}
let delegateClass = ObjC.defineClass("ScrollDelegate") { cls in
    cls.conform(to: "UIScrollViewDelegate")
    cls.method("scrollViewDidEndDecelerating:", types: "v@:@") { _ in reload() }
}
```

- **Methods:** a closure implements each method. Use `method` for methods
  that return nothing and `function` for ones that return a value.
- **Inside a method:** `call.this` is the receiver, `call[0]`… are the
  arguments, decoded like message results, and `call.callSuper()` sends the
  message to the superclass's implementation.
- **Types:**
  - Overrides take their types from the superclass.
  - Otherwise they come from an adopted protocol, else from `types:`, else
    they're objects returning void.
  - At run time, the runtime only knows protocols that some loaded code refers
    to, so `conform(to:)` returns false for the others. Delegate methods should
    pass `types:`.
- **Under the hood:** every method gets one C implementation (another for
  struct results larger than 4 bytes), which collects the 16 argument words and
  calls Swift. Swift finds the closure by class and selector, including for
  instances of subclasses.
- **Memory:**
  - In `dealloc`, `self` isn't retained.
  - Returned objects are autoreleased, except in the alloc, new, copy and
    init families.
- **Also available:**
  - Associated objects: `value.setAssociated(other, for: key)`.
  - Main-queue dispatch and `UIApplicationMain`, in `ObjCRuntime.h`.
- **Caching:** selectors, classes and method signatures are cached, so
  repeated messages don't look up types again.

The SwiftUI library's UIKit backend (`../SwiftUI/Sources/SwiftUI/Backend.swift`)
is written this way, with no Objective-C.

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
PASS method called from Objective-C: 2
PASS struct override through stret
…
```

On the iPod (iOS 6.1.6), all 56 checks that run outside an app pass,
including the macro checks in `Tests/Wrappers.swift`. iOS 6
won't start UIKit in a command-line tool (it traps in GraphicsServices), so
the UIKit checks are skipped there, and the SwiftUI apps cover UIKit instead.
An earlier version of the suite, including the UIKit checks, passed 55/55 on
the iPhone 4S (iOS 9.3.6). The current suite hasn't run there yet.

## Limits

- **No blocks:** methods that take blocks (`addObserverForName:…usingBlock:`,
  `animateWithDuration:animations:`) can't be called.
- **No instance variables:** classes defined from Swift keep their state in
  Swift (for example, in a dictionary by object address, cleared in
  `dealloc`) or in associated objects.
- **No variadic methods:** the type encoding doesn't describe variadic
  arguments, so `stringWithFormat:` and `arrayWithObjects:` don't work. Use
  `stringWithString:` and `addObject:` instead.
- **Exceptions crash:** an Objective-C exception (such as inserting nil into an
  array) crashes the app, because Swift can't catch it. An unknown selector or
  the wrong number of arguments stops with a message naming the method.
- **Speed:** a message converts its arguments and result through the cached
  method types, which is slower than a direct call but fine for UI code.
- **Argument size:** at most 16 words of arguments.

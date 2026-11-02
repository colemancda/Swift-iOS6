# Frameworks

Foundation and UIKit for Embedded Swift on iOS 6. These are typed Swift
wrappers generated from the iOS SDK's headers by
[../ObjC/tools/objcgen.py](../ObjC/README.md#generating-wrappers-from-headers),
with the API limited to what iOS 6.0 has. Each is a Swift module of the same
name:

```swift
import Foundation
import UIKit

let label = UILabel(frame: CGRect(x: 20, y: 20, width: 280, height: 44))
label.text = "Hello"
label.textColor = UIColor.redColor()
label.backgroundColor = nil           // inherited from UIView
let name = UIDevice.currentDevice().name ?? "?"
if let url = NSURL.URLWithString("http://www.apple.com") {
    _ = UIApplication.sharedApplication().openURL(url)
}
```

| Module | Classes | Methods | Properties |
|---|---|---|---|
| Foundation | 127 | 1,428 | 600 |
| UIKit | 109 | 833 | 755 |

UIKit's counts include its additions to Foundation classes, such as
NSString's drawing methods.

1,546 APIs newer than iOS 6.0 and 97 newer classes are left out.

## What the declarations look like

- **Classes:** each Objective-C class is an `@ObjC` struct, such as
  `UILabel`. Its members are in an extension of a protocol, `UILabelMethods`,
  which refines `UIViewMethods`, and so on up to `NSObjectMethods`. A
  `UILabel` therefore has UIView's, UIResponder's and NSObject's members too
  (including the `NSObject` protocol's `isKindOfClass:` and friends).
  `wrapper.as(UIView.self)` converts between wrapper types.
- **Methods:** each method is an `@ObjCMethod` with its selector spelled out.
  - The Swift name is the selector's first part. The first argument is
    unlabeled and the rest are labeled with the selector's parts:
    `setTitle(_:forState:)`.
  - `init…` methods are initializers. `initWithFrame:` is `init(frame:)`,
    which allocates an instance of whichever struct it's called on, so
    `UILabel(frame:)` makes a UILabel.
  - Class methods are `static`. One returning `instancetype` returns `Self`,
    or `Self?` when it's nullable.
- **Properties:** `@ObjCProperty`, with `getter:` for `isHidden`-style
  getters and `readonly`.
- **Types:**
  - `NSString *` is `String`. Other wrapped classes are their wrappers, and
    nullable or unannotated objects are optionals.
  - A wrapper parameter accepts any subclass's wrapper, as
    `some NSArrayMethods`.
  - `NSInteger`, `NSUInteger`, enums and other integers are `Int`.
    `long long` is `Int64`.
  - `CGFloat` and `float` are `Float`, and `double` is `Double`.
  - `CGRect`, `CGPoint`, `CGSize` and `NSRange` are ObjCInterop's structs.
  - Everything else is `ObjCValue`: `id`, `SEL`, `Class`, other structs,
    pointers, and objects of classes from other frameworks.
- **Left out:** methods that take blocks, function pointers, C arrays or
  variable arguments.

The members are generic (protocol extensions), so Embedded Swift only
compiles the ones an app uses. The framework test binary links both modules
and is 238 KB.

## Using them

- **Apps:** a SwiftUI app lists `Foundation UIKit` in a `LIBS` file next to
  its `Info.plist` (see `../SwiftUI/Examples/Interop`), or passes
  `LIBS="Foundation UIKit"` to `../SwiftUI/Makefile`. UIKit needs
  Foundation.
- **Regenerating:** `make frameworks` in `../ObjC` regenerates both from the
  SDK. Don't edit them by hand.
- **Tests:** `make test-frameworks` in `../ObjC` runs 31 checks of the
  generated Foundation on the device. They cover factories, initializers,
  inheritance, subclass arguments, nullable results, numbers, files, URLs,
  dates, data and NSUUID.

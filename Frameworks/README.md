# Frameworks

Foundation, UIKit, CoreLocation, CoreBluetooth and CoreData for Embedded
Swift on iOS 6. These are typed Swift
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
| Foundation | 127 | 1,430 | 601 |
| UIKit | 109 | 833 | 755 |
| CoreLocation | 6 | 26 | 48 |
| CoreBluetooth | 12 | 30 | 29 |
| CoreData | 28 | 141 | 158 |

UIKit's counts include its additions to Foundation classes, such as
NSString's drawing methods.

1,670 APIs newer than iOS 6.0 and 113 newer classes are left out. Each
framework only uses the wrapper types of frameworks listed before it, and
imports just the ones it refers to (CoreData uses Foundation's, not
UIKit's). A type from a later framework is `ObjCValue` instead: for example,
UIKit's `UIManagedDocument.managedObjectContext`.

Example apps:
- [../Location](../Location/README.md) uses CoreLocation.
- [../BLEScanner](../BLEScanner/README.md) uses CoreBluetooth.
- [../Notes](../Notes/README.md) uses CoreData.
- `../SwiftUI/Examples/Interop` uses UIKit.

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
  - A non-null wrapper parameter accepts any subclass's wrapper, as
    `some NSArrayMethods`. A nullable one is the plain optional
    (`NSDictionary?`), so that it can take `nil`. Pass a subclass's wrapper
    to it with `.as(NSDictionary.self)`.
  - `NSInteger`, `NSUInteger`, enums and other integers are `Int`.
    `long long` is `Int64`.
  - `CGFloat` and `float` are `Float`, and `double` is `Double`.
  - `CGRect`, `CGPoint`, `CGSize` and `NSRange` are ObjCInterop's structs.
  - A C struct whose fields are all numbers of one size becomes a Swift
    struct: `CLLocationCoordinate2D`, `UIEdgeInsets` and `UIOffset`. It
    converts to and from the runtime's words.
  - Everything else is `ObjCValue`: `id`, `SEL`, `Class`, other structs,
    pointers, and objects of classes from other frameworks.
- **Left out:**
  - Methods that take blocks, function pointers, C arrays or variable
    arguments.
  - Protocols and constants. Write delegates with `@ObjCImplementation`, as
    the example apps do, and pass a constant's value, such as `"SQLite"` for
    `NSSQLiteStoreType`.

The members are generic (protocol extensions), so Embedded Swift only
compiles the ones an app uses. The framework test binary links both modules
and is 238 KB.

## Using them

- **Apps:** a SwiftUI app lists the modules it uses in a `LIBS` file next to
  its `Info.plist` (for example `Foundation CoreLocation`), or passes `LIBS`
  to `../SwiftUI/Makefile`. Every module needs Foundation. The app is linked
  against each listed framework.
- **Regenerating:** `make frameworks` in `../ObjC` regenerates them all
  (the list is `FRAMEWORKS` in `../ObjC/Makefile`). Don't edit them by hand.
- **Tests:** `make test-frameworks` in `../ObjC` runs 31 checks of the
  generated Foundation on the device. They cover factories, initializers,
  inheritance, subclass arguments, nullable results, numbers, files, URLs,
  dates, data and NSUUID.

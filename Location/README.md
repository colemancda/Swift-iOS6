# Location

Where the device is, from Core Location, on iOS 6. It's written in SwiftUI
with the CoreLocation module generated in [../Frameworks](../Frameworks/README.md).

- **Position:** latitude, longitude and accuracy, altitude, speed, course,
  and the number of updates, as they arrive.
- **Compass:** the magnetic heading, where there's a magnetometer. The iPod
  touch 4 has none.
- **Permission:** iOS 6 asks the first time updating starts, with the
  manager's `purpose` text. The app shows the permission state and errors.

The iPod touch 4 has no GPS, so its fixes come from Wi-Fi (about ±65 m
indoors).

```bash
make           # build build/Location.app
make install   # copy it to the iPod
make run       # launch it (the iPod must be unlocked)
```

## How it works

- **Delegate:** `LocationDelegate` is the `CLLocationManagerDelegate`,
  written with `@ObjCImplementation`. It handles
  `locationManager:didUpdateLocations:`, heading updates, errors and
  permission changes. Each method's Objective-C types come from its Swift
  signature.
- **Coordinates:** `CLLocation.coordinate` is a generated
  `CLLocationCoordinate2D` struct with `Double` fields.
- **Number formatting:** Embedded Swift can't print floating-point numbers,
  so `fixed(_:_:)` formats them with integer arithmetic.

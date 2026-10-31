# Wi-Fi Scanner

A Wi-Fi scanner for iOS 6, written in SwiftUI with the library in
[../SwiftUI](../SwiftUI/README.md), running on a jailbroken iPod touch (4th gen).

It lists nearby networks from iOS's private MobileWiFi framework. Each row
shows a network's name, security, channel and signal strength. The joined
network is checked and listed first, and the rest are ordered strongest first.
The list rescans every 5 seconds. Tapping a network shows its BSSID, signal
quality and band. A switch at the top turns Wi-Fi on and off, like the one in
Settings.

```bash
make           # build build/WiFiScanner.app
make install   # copy it to the iPod
make run       # launch it (the iPod must be unlocked)
```

## How it works

```
WiFiScannerApp.swift (Embedded Swift, SwiftUI)
  └─ WiFi.h (C API: pointers and longs only)
       └─ WiFi.c (iOS side: CoreFoundation + MobileWiFi, looked up with dlsym)
            └─ wifid
```

- **MobileWiFi:** a plain C framework on iOS 6, used by Settings.
  - `WiFiManagerClientCreate` connects to `wifid`.
  - `WiFiDeviceClientScanAsync` scans and calls back on the main run loop
    with the networks it found.
  - `WiFiNetworkGetSSID`, `WiFiNetworkGetProperty` (BSSID, RSSI, CHANNEL) and
    `WiFiNetworkIsWPA`/`IsWEP`/`IsEAP` describe each network.
  - `WiFiManagerClientGetPower`/`SetPower` read and set the Wi-Fi switch.

  The SDK has no stubs for private frameworks, so `WiFi.c` loads these with
  `dlsym`.
- **Entitlement:** `wifid` only answers processes signed with
  `com.apple.wifi.manager-access`. `Entitlements.plist` holds it, and `ldid`
  signs the app with it. The app runs from `/Applications`, outside the
  sandbox.
- **Swift boundary:** CoreFoundation types stay in C. Scan results reach Swift
  as `WiFiNetworkInfo` structs of C strings and `long`s, so nothing depends on
  the bare-metal and iOS calling conventions agreeing on floats or structs
  passed by value.
- **Build:** `make` here calls `../SwiftUI/Makefile` with `APP_DIR` set to this
  folder. That builds `WiFi.c` for iOS, imports `include/` as the `CWiFi` Clang
  module, links the SwiftUI library, and signs with the entitlement.

## SwiftUI additions made for this app

- **`Toggle`**, backed by `UISwitch`.
- **Faster rendering:** the backend now lays out with frames instead of Auto
  Layout. A rescan used to block the main thread for 1.5–2.5 seconds (iOS's
  watchdog once killed the app for it). It now takes about 0.2 seconds.
- **Navigation fix:** a render no longer pushes or pops while a navigation
  transition is animating, which corrupted the navigation bar.

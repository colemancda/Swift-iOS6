# Bluetooth Scanner

A Bluetooth Classic scanner for iOS 6, written in SwiftUI with the library in
[../SwiftUI](../SwiftUI/README.md), running on a jailbroken iPod touch (4th gen).

It lists paired devices and every discoverable device nearby, including the
phones and computers that Settings → Bluetooth hides. Each row shows the
device's name, kind (from its Class of Device) and address. Tapping a device
shows its class codes and its paired, connected and nearby state. A switch at
the top turns Bluetooth on and off, like the one in Settings.

```bash
make           # build build/BluetoothScanner.app
make install   # copy it to the iPod
make run       # launch it (the iPod must be unlocked)
```

Devices only answer while discoverable: an iPhone while its Bluetooth screen is
open, a Mac while its Bluetooth settings are open, headphones in pairing mode.
Discovery is slow; a device can take 20–30 seconds to appear.

## How it works

```
BluetoothScannerApp.swift (Embedded Swift, SwiftUI)
  └─ Bluetooth.h (C API: pointers and longs only)
       └─ Bluetooth.m (Objective-C: BluetoothManager, looked up at run time)
            └─ BTServer
```

- **BluetoothManager** is the private framework Settings uses.
  `+sharedInstance` attaches to `BTServer`. The other calls only work after
  `BluetoothAvailabilityChangedNotification` arrives. Found devices arrive
  as `BluetoothDeviceDiscoveredNotification`, and devices that stop answering
  as `BluetoothDeviceRemovedNotification`.
- **Unfiltered discovery:** on iOS 6, `setDeviceScanningEnabled:` only reports
  devices with services iOS can use. A probe on the iPod found nothing with it,
  even with an iPhone and a Mac discoverable. `scanForServices:0xFFFFFFFF`
  asks for every service, and reports both.
- **Lost devices stay listed:** a Mac answers discovery only now and then, so
  a lost device stays in the list, marked "Not nearby", until it answers again.
- **No signal strength:** iOS 6's `BluetoothDevice` has no RSSI.
- **No entitlement needed:** BluetoothManager talks to `BTServer` without
  one when the app runs from `/Applications`.
- **Fewer re-renders:** `BTServer` posts a notification on every discovery
  cycle. The Swift store publishes only when the device list or status
  actually changes, so the screen re-renders only then.

## Limits

- Discovery and pairing information only. Talking to arbitrary devices (SPP
  serial, L2CAP, game controllers) needs a full Bluetooth stack such as
  BTstack in place of `BTServer`, because iOS 6 has no API for it.
- Bluetooth Classic only: the iPod touch 4 has no Bluetooth Low Energy.

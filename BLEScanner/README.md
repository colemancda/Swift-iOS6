# BLE Scanner

Scans for Bluetooth Low Energy devices with Core Bluetooth (iOS 5 and
later). It's written in SwiftUI with the CoreBluetooth module generated in
[../Frameworks](../Frameworks/README.md).

- **Devices:** each one's name, signal strength (dBm, updated as
  advertisements arrive), and every advertised value (local name,
  manufacturer data, services, transmit power…). The list is sorted by signal
  strength.
- **Bluetooth state:** shown at the top. Scanning starts only once it's On.

Core Bluetooth needs Bluetooth 4.0 hardware.

- **iPod touch 4** (Bluetooth 2.1): reports Unsupported. For Bluetooth
  Classic devices there, see [../BluetoothScanner](../BluetoothScanner/README.md).
- **iPhone 4S** (iOS 9.3.6): powers on and scans. Install there with:

```bash
make install SSH_HOST=4s SSH_CONF=/path/to/4s-ssh.conf
make run SSH_HOST=4s SSH_CONF=/path/to/4s-ssh.conf
```

`CentralDelegate` is the `CBCentralManagerDelegate`, written with
`@ObjCImplementation`. The manager calls it on the main queue (`queue: nil`).
Scanning uses `kCBScanOptionAllowDuplicates`, so signal strengths stay
current.

## Status

On the iPhone 4S, the manager reaches Powered On and the scan starts. No
devices showed up in testing, but no BLE device was known to be advertising
nearby: iOS hides other iPhones' Continuity advertisements from Core
Bluetooth. Discovery hasn't been confirmed against a known peripheral yet.

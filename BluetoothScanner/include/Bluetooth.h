// C interface to iOS 6's private BluetoothManager framework, for Embedded Swift.
//
// Only pointers and `long` cross this boundary; the Objective-C side is
// Bluetooth.m. Every call must be made on the main thread, and callbacks
// arrive on it.

#ifndef BLUETOOTH_H
#define BLUETOOTH_H

/// Major device classes from a device's Class of Device.
enum {
    BTMajorClassMisc = 0x000,
    BTMajorClassComputer = 0x100,
    BTMajorClassPhone = 0x200,
    BTMajorClassNetwork = 0x300,
    BTMajorClassAudioVideo = 0x400,
    BTMajorClassPeripheral = 0x500,
    BTMajorClassImaging = 0x600,
    BTMajorClassWearable = 0x700,
    BTMajorClassToy = 0x800,
    BTMajorClassHealth = 0x900,
};

/// A paired or discovered device. The strings are only valid during the callback.
typedef struct {
    const char *name;
    /// "AA:BB:CC:DD:EE:FF"
    const char *address;
    /// One of BTMajorClass*.
    long majorClass;
    /// Meaning depends on the major class (for a phone, 0xC is a smartphone).
    long minorClass;
    long paired;
    long connected;
    /// 0 once a discovered device stops answering (it stays in the list).
    long nearby;
} BTDeviceInfo;

/// Called whenever availability, power, scanning or the device list changes,
/// with every known device: paired ones first, then the rest in the order
/// they were found.
typedef void (*BTChangedCallback)(void *context, const BTDeviceInfo *devices, long count);

/// Attaches to BTServer. `changed` is called once Bluetooth is available, and
/// after every change. Returns 0 on success.
long bt_open(BTChangedCallback changed, void *context);

/// 1 once BTServer has answered and the other calls work.
long bt_is_available(void);

/// Whether Bluetooth is turned on (1) or off (0).
long bt_get_power(void);

/// Turns Bluetooth on or off, like the switch in Settings.
void bt_set_power(long on);

/// Starts or stops looking for discoverable devices of every kind (not only
/// the ones iOS can pair with). A request made before Bluetooth is available
/// or powered takes effect once it is.
void bt_set_scanning(long on);

/// 1 while the radio is actively searching.
long bt_is_scanning(void);

#endif

// C interface to iOS 6's private MobileWiFi framework, for Embedded Swift.
//
// Like SwiftUIBackend.h, only pointers and `long` cross this boundary, and
// CoreFoundation stays on the iOS side (WiFi.c). Every call must be made on
// the main thread; scan results are delivered on the main run loop.

#ifndef WIFI_H
#define WIFI_H

enum {
    WiFiSecurityOpen = 0,
    WiFiSecurityWEP = 1,
    WiFiSecurityWPA = 2,
    /// WPA Enterprise (802.1X).
    WiFiSecurityEnterprise = 3,
};

/// One network from a scan. The strings are only valid during the callback.
typedef struct {
    /// UTF-8; empty for a hidden network.
    const char *ssid;
    /// "aa:bb:cc:dd:ee:ff"
    const char *bssid;
    /// Signal strength in dBm, such as -55.
    long rssi;
    long channel;
    long security;
    /// 1 if this is the network the device is joined to.
    long current;
} WiFiNetworkInfo;

/// `error` is 0 on success, in which case `networks` holds `count` entries.
typedef void (*WiFiScanCallback)(void *context, const WiFiNetworkInfo *networks, long count, long error);

/// Connects to wifid. Returns 0 on success, or nonzero if MobileWiFi isn't
/// available or the app lacks the com.apple.wifi.manager-access entitlement.
long wifi_open(void);

/// Whether Wi-Fi is turned on (1) or off (0).
long wifi_get_power(void);

/// Turns Wi-Fi on or off, like the switch in Settings.
void wifi_set_power(long on);

/// Starts a scan and calls `callback` on the main run loop when it finishes.
/// Returns 0 if the scan started, or nonzero (for example, while Wi-Fi is off
/// or another scan is running).
long wifi_scan(WiFiScanCallback callback, void *context);

#endif

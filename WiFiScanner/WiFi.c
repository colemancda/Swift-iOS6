// MobileWiFi implementation of WiFi.h.
//
// MobileWiFi is private and the SDK has no stubs for it, so its functions
// are looked up with dlsym. The signatures are the ones iOS 5-7 used.

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include "WiFi.h"

typedef struct __WiFiManager *WiFiManagerRef;
typedef struct __WiFiDevice *WiFiDeviceRef;
typedef struct __WiFiNetwork *WiFiNetworkRef;
typedef void (*WiFiDeviceScanCallback)(WiFiDeviceRef device, CFArrayRef networks, int error, void *token);

static WiFiManagerRef (*WiFiManagerClientCreate)(CFAllocatorRef allocator, int flags);
static void (*WiFiManagerClientScheduleWithRunLoop)(WiFiManagerRef manager, CFRunLoopRef runLoop, CFStringRef mode);
static CFArrayRef (*WiFiManagerClientCopyDevices)(WiFiManagerRef manager);
static Boolean (*WiFiManagerClientGetPower)(WiFiManagerRef manager);
static void (*WiFiManagerClientSetPower)(WiFiManagerRef manager, Boolean on);
static int (*WiFiDeviceClientScanAsync)(WiFiDeviceRef device, CFDictionaryRef options, WiFiDeviceScanCallback callback, void *token);
static WiFiNetworkRef (*WiFiDeviceClientCopyCurrentNetwork)(WiFiDeviceRef device);
static CFStringRef (*WiFiNetworkGetSSID)(WiFiNetworkRef network);
static CFTypeRef (*WiFiNetworkGetProperty)(WiFiNetworkRef network, CFStringRef property);
static Boolean (*WiFiNetworkIsWEP)(WiFiNetworkRef network);
static Boolean (*WiFiNetworkIsWPA)(WiFiNetworkRef network);
static Boolean (*WiFiNetworkIsEAP)(WiFiNetworkRef network);

static WiFiManagerRef WiFiManager;
static WiFiDeviceRef WiFiDevice;
static int WiFiScanning;

typedef struct {
    WiFiScanCallback callback;
    void *context;
} WiFiScanRequest;

#define WIFI_LOAD(handle, name) \
    if (!(*(void **)&name = dlsym(handle, #name))) return 2

static long WiFiLoad(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
    if (!handle) return 1;
    WIFI_LOAD(handle, WiFiManagerClientCreate);
    WIFI_LOAD(handle, WiFiManagerClientScheduleWithRunLoop);
    WIFI_LOAD(handle, WiFiManagerClientCopyDevices);
    WIFI_LOAD(handle, WiFiManagerClientGetPower);
    WIFI_LOAD(handle, WiFiManagerClientSetPower);
    WIFI_LOAD(handle, WiFiDeviceClientScanAsync);
    WIFI_LOAD(handle, WiFiDeviceClientCopyCurrentNetwork);
    WIFI_LOAD(handle, WiFiNetworkGetSSID);
    WIFI_LOAD(handle, WiFiNetworkGetProperty);
    WIFI_LOAD(handle, WiFiNetworkIsWEP);
    WIFI_LOAD(handle, WiFiNetworkIsWPA);
    WIFI_LOAD(handle, WiFiNetworkIsEAP);
    return 0;
}

long wifi_open(void) {
    if (WiFiManager) return 0;
    long error = WiFiLoad();
    if (error) return error;
    WiFiManager = WiFiManagerClientCreate(kCFAllocatorDefault, 0);
    if (!WiFiManager) return 3;
    WiFiManagerClientScheduleWithRunLoop(WiFiManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    CFArrayRef devices = WiFiManagerClientCopyDevices(WiFiManager);
    if (devices && CFArrayGetCount(devices) > 0) {
        WiFiDevice = (WiFiDeviceRef)CFRetain(CFArrayGetValueAtIndex(devices, 0));
    }
    if (devices) CFRelease(devices);
    return WiFiDevice ? 0 : 4;
}

long wifi_get_power(void) {
    return WiFiManager && WiFiManagerClientGetPower(WiFiManager) ? 1 : 0;
}

void wifi_set_power(long on) {
    if (WiFiManager) WiFiManagerClientSetPower(WiFiManager, on != 0);
}

/// A copy of `string` as UTF-8, or "" for NULL. Free with free().
static char *WiFiCopyUTF8(CFStringRef string) {
    if (!string || CFGetTypeID(string) != CFStringGetTypeID()) return strdup("");
    CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
    char *buffer = malloc(size);
    if (!CFStringGetCString(string, buffer, size, kCFStringEncodingUTF8)) buffer[0] = 0;
    return buffer;
}

static long WiFiNumberProperty(WiFiNetworkRef network, CFStringRef property) {
    CFTypeRef value = WiFiNetworkGetProperty(network, property);
    long result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberLongType, &result);
    }
    return result;
}

static CFStringRef WiFiBSSID(WiFiNetworkRef network) {
    return network ? WiFiNetworkGetProperty(network, CFSTR("BSSID")) : NULL;
}

static void WiFiScanDone(WiFiDeviceRef device, CFArrayRef networks, int error, void *token) {
    WiFiScanRequest *request = token;
    WiFiScanning = 0;
    if (error || !networks) {
        request->callback(request->context, NULL, 0, error ? error : -1);
        free(request);
        return;
    }

    WiFiNetworkRef current = WiFiDeviceClientCopyCurrentNetwork(device);
    CFStringRef currentBSSID = WiFiBSSID(current);
    CFIndex count = CFArrayGetCount(networks);
    WiFiNetworkInfo *infos = calloc(count ? count : 1, sizeof *infos);
    for (CFIndex i = 0; i < count; i++) {
        WiFiNetworkRef network = (WiFiNetworkRef)CFArrayGetValueAtIndex(networks, i);
        CFStringRef bssid = WiFiBSSID(network);
        infos[i].ssid = WiFiCopyUTF8(WiFiNetworkGetSSID(network));
        infos[i].bssid = WiFiCopyUTF8(bssid);
        infos[i].rssi = WiFiNumberProperty(network, CFSTR("RSSI"));
        infos[i].channel = WiFiNumberProperty(network, CFSTR("CHANNEL"));
        infos[i].security = WiFiNetworkIsEAP(network) ? WiFiSecurityEnterprise
            : WiFiNetworkIsWPA(network) ? WiFiSecurityWPA
            : WiFiNetworkIsWEP(network) ? WiFiSecurityWEP
            : WiFiSecurityOpen;
        infos[i].current = currentBSSID && bssid && CFEqual(currentBSSID, bssid);
    }
    if (current) CFRelease(current);

    request->callback(request->context, infos, count, 0);
    for (CFIndex i = 0; i < count; i++) {
        free((char *)infos[i].ssid);
        free((char *)infos[i].bssid);
    }
    free(infos);
    free(request);
}

long wifi_scan(WiFiScanCallback callback, void *context) {
    if (!WiFiDevice) return 1;
    if (WiFiScanning) return 2;
    if (!wifi_get_power()) return 3;
    WiFiScanRequest *request = malloc(sizeof *request);
    request->callback = callback;
    request->context = context;
    CFDictionaryRef options = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                                                 &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int error = WiFiDeviceClientScanAsync(WiFiDevice, options, WiFiScanDone, request);
    CFRelease(options);
    if (error) {
        free(request);
        return error;
    }
    WiFiScanning = 1;
    return 0;
}

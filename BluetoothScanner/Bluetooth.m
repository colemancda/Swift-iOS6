// BluetoothManager implementation of Bluetooth.h.
//
// BluetoothManager is private, so its classes are looked up at run time and
// declared here as protocols. On iOS 6 `setDeviceScanningEnabled:` only
// reports devices with services iOS supports (headsets, keyboards...);
// `scanForServices:` with every bit set reports phones, computers and
// everything else that is discoverable.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include "Bluetooth.h"

@protocol BTManager
+ (id)sharedInstance;
- (BOOL)available;
- (BOOL)enabled;
- (BOOL)setEnabled:(BOOL)enabled;
- (BOOL)powered;
- (void)scanForServices:(unsigned)mask;
- (void)setDeviceScanningEnabled:(BOOL)enabled;
- (BOOL)deviceScanningInProgress;
- (NSArray *)pairedDevices;
@end

@protocol BTDevice
- (NSString *)name;
- (NSString *)address;
- (unsigned)majorClass;
- (unsigned)minorClass;
- (BOOL)paired;
- (BOOL)connected;
@end

static id<BTManager> BTManager;
static BTChangedCallback BTChanged;
static void *BTContext;
/// Devices found by scanning, in the order they were found. A device iOS
/// reports lost stays here, with its address in BTLost.
static NSMutableArray *BTDiscovered;
static NSMutableSet *BTLost;
static BOOL BTWantsScanning;
static BOOL BTScanning;

/// Starts or stops the radio to match what was asked for, once it can.
static void BTUpdateScanning(void) {
    BOOL scan = BTWantsScanning && [BTManager available] && [BTManager powered];
    if (scan == BTScanning) return;
    BTScanning = scan;
    if (scan) {
        [BTManager scanForServices:0xFFFFFFFF];
    } else {
        [BTManager setDeviceScanningEnabled:NO];
    }
}

static void BTReport(void) {
    if (!BTChanged) return;
    NSMutableArray *devices = [NSMutableArray array];
    NSMutableSet *addresses = [NSMutableSet set];
    NSArray *paired = [BTManager available] ? [BTManager pairedDevices] : @[];
    for (id<BTDevice> device in [paired arrayByAddingObjectsFromArray:BTDiscovered]) {
        NSString *address = [device address];
        if (!address || [addresses containsObject:address]) continue;
        [addresses addObject:address];
        [devices addObject:device];
    }

    NSUInteger count = devices.count;
    BTDeviceInfo infos[count ? count : 1];
    // Holds the strings whose UTF-8 buffers `infos` points into.
    NSMutableArray *strings = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        id<BTDevice> device = devices[i];
        NSString *name = [device name] ?: @"";
        NSString *address = [device address];
        [strings addObject:name];
        [strings addObject:address];
        infos[i].name = name.UTF8String;
        infos[i].address = address.UTF8String;
        infos[i].majorClass = [device majorClass];
        infos[i].minorClass = [device minorClass];
        infos[i].paired = [device paired];
        infos[i].connected = [device connected];
        infos[i].nearby = [device connected] || ([BTDiscovered containsObject:device] && ![BTLost containsObject:address]);
    }
    BTChanged(BTContext, infos, (long)count);
    (void)strings.count;
}

static void BTHandle(NSNotification *notification) {
    NSString *name = notification.name;
    if ([name isEqualToString:@"BluetoothDeviceDiscoveredNotification"]) {
        id<BTDevice> device = notification.object;
        BOOL known = NO;
        for (id<BTDevice> other in BTDiscovered) {
            if ([[other address] isEqualToString:[device address]]) known = YES;
        }
        if (!known) [BTDiscovered addObject:device];
        [BTLost removeObject:[device address]];
    } else if ([name isEqualToString:@"BluetoothDeviceRemovedNotification"]) {
        NSString *address = [notification.object address];
        if (address) [BTLost addObject:address];
    } else if ([name isEqualToString:@"BluetoothPowerChangedNotification"] && ![BTManager powered]) {
        // Turning Bluetooth off forgets what was found.
        [BTDiscovered removeAllObjects];
        [BTLost removeAllObjects];
        BTScanning = NO;
    }
    BTUpdateScanning();
    BTReport();
}

long bt_open(BTChangedCallback changed, void *context) {
    if (BTManager) return 0;
    if (!dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_NOW)) return 1;
    Class managerClass = NSClassFromString(@"BluetoothManager");
    if (!managerClass) return 2;
    BTChanged = changed;
    BTContext = context;
    BTDiscovered = [NSMutableArray array];
    BTLost = [NSMutableSet set];
    [[NSNotificationCenter defaultCenter] addObserverForName:nil object:nil queue:nil usingBlock:^(NSNotification *notification) {
        if ([notification.name hasPrefix:@"Bluetooth"]) BTHandle(notification);
    }];
    // The first use attaches to BTServer; BluetoothAvailabilityChangedNotification
    // follows once it has answered.
    BTManager = [(id)managerClass sharedInstance];
    return BTManager ? 0 : 3;
}

long bt_is_available(void) {
    return [BTManager available] ? 1 : 0;
}

long bt_get_power(void) {
    return [BTManager available] && [BTManager enabled] ? 1 : 0;
}

void bt_set_power(long on) {
    if ([BTManager available]) [BTManager setEnabled:on != 0];
}

void bt_set_scanning(long on) {
    BTWantsScanning = on != 0;
    BTUpdateScanning();
}

long bt_is_scanning(void) {
    return BTScanning && [BTManager deviceScanningInProgress] ? 1 : 0;
}

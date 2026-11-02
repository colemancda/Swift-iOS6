// Typed Swift declarations of the UIKit and Foundation API this example uses,
// written with ObjCInterop's macros: each @ObjCMethod and @ObjCProperty sends
// its Objective-C message and converts the result.

import ObjCInterop

@ObjC
struct UIDevice {
    @ObjCMethod static func currentDevice() -> UIDevice
    @ObjCProperty(readonly: true) var name: String
    @ObjCProperty(readonly: true) var model: String
    @ObjCProperty(readonly: true) var systemName: String
    @ObjCProperty(readonly: true) var systemVersion: String
    /// iOS 6 and later.
    @ObjCProperty(readonly: true) var identifierForVendor: NSUUID?
    @ObjCProperty(getter: "isBatteryMonitoringEnabled") var batteryMonitoringEnabled: Bool
    /// 0 to 1, or -1 while battery monitoring is off.
    @ObjCProperty(readonly: true) var batteryLevel: Float
    /// Unknown, unplugged, charging, full.
    @ObjCProperty(readonly: true) var batteryState: Int
}

@ObjC
struct NSUUID {
    @ObjCProperty(getter: "UUIDString", readonly: true) var uuidString: String
}

@ObjC
struct UIScreen {
    @ObjCMethod static func mainScreen() -> UIScreen
    @ObjCProperty(readonly: true) var bounds: CGRect
    @ObjCProperty(readonly: true) var scale: Float
    @ObjCProperty var brightness: Float
}

@ObjC
struct UIApplication {
    @ObjCMethod static func sharedApplication() -> UIApplication
    @ObjCProperty(getter: "isIdleTimerDisabled") var idleTimerDisabled: Bool
    @ObjCMethod("openURL:") func open(_ url: NSURL) -> Bool
}

@ObjC
struct NSURL {
    @ObjCMethod static func URLWithString(_ string: String) -> NSURL
}

@ObjC
struct NSLocale {
    @ObjCMethod static func currentLocale() -> NSLocale
    @ObjCProperty(readonly: true) var localeIdentifier: String
}

@ObjC
struct NSTimeZone {
    @ObjCMethod static func localTimeZone() -> NSTimeZone
    @ObjCProperty(readonly: true) var name: String
}

@ObjC
struct NSBundle {
    @ObjCMethod static func mainBundle() -> NSBundle
    @ObjCMethod func objectForInfoDictionaryKey(_ key: String) -> String?
}

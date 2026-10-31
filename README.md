# Swift-iOS6

Embedded Swift running on iOS 6, built with Xcode 27 and Swift 6.4.

[SwiftUI/](SwiftUI/README.md) is a SwiftUI-compatible UI library for iOS 6,
with example apps that use `NavigationStack`, `List` and `async`/`await`.
[WiFiScanner/](WiFiScanner/README.md) is a SwiftUI app that scans for Wi-Fi
networks with iOS 6's private MobileWiFi framework, and
[BluetoothScanner/](BluetoothScanner/README.md) one that finds Bluetooth
Classic devices with the private BluetoothManager framework.

A minimal UIKit app and a command-line tool for a jailbroken iPod touch (4th gen,
iPod4,1, armv7, iOS 6.1.6). Adapted from
[iPhone4S-HelloWorld](https://github.com/colemancda/iPhone4S-HelloWorld), which
does the same for iOS 9.

```
$ make run-cli
Hello from Swift 6.4, iPod touch!
1² + 2² + 3² + 4² + 5² = 55
```

## How it works

- **Compiler and linker:** Xcode 27's `clang` and `ld` still support armv7. With
  `-miphoneos-version-min=6.0` the linker writes `LC_VERSION_MIN_IPHONEOS 6.0` and
  `LC_MAIN`, which iOS 6's dyld understands.
- **SDK:** there's no iOS 6 SDK in [theos/sdks](https://github.com/theos/sdks), so
  the build uses `iPhoneOS9.3.sdk` (release `master-146e41f`). The headers' availability annotations, plus
  `-Werror=unguarded-availability`, make any API newer than iOS 6.0 a compile error.
  Binaries bind symbols through `libSystem.B.dylib` and the frameworks' umbrella
  install names, so they resolve against iOS 6's libraries at run time. Set it up with
  `make sdk SDK_ARCHIVE=/path/to/iPhoneOS9.3.sdk.tar.xz`. That strips `i386, x86_64` from
  the `.tbd` stubs and adds the `mem*` functions Swift calls directly.
- **Swift:** [Embedded Swift](https://www.swift.org/getting-started/embedded-swift/) from
  the swift.org 6.4.2 toolchain, built for `armv7-apple-none-macho` with
  `-Xcc -marm -Xcc -ffixed-r9`. The reasons are the same as in iPhone4S-HelloWorld.
  `swift/HelloIOS6.swift` exports `@c` functions that `src/main.m` calls through
  `swift/HelloIOS6.h`.
- **UI:** iOS 6 has no `UIStackView` or layout anchors, so the labels use frames
  and autoresizing masks.
- **Signing:** `ldid -S`.
- **Install:** over SSH into `/Applications`, then `uicache`.
- **Launch:** `tools/launch.c` calls SpringBoardServices'
  `SBSLaunchApplicationWithIdentifier`. It's signed with the
  `com.apple.springboard.launchapplications` entitlement.

## Commands

```bash
make          # build build/HelloWorld.app
make install  # copy to the iPod and refresh the home screen
make run      # launch the installed app (the iPod must be unlocked)
make screenshot  # save the iPod's screen to build/screenshot.png
make ipa      # package build/HelloWorld.ipa
make cli      # build the Swift command-line tool, build/hello-swift
make run-cli  # copy it to the iPod and run it there
make sdk      # re-create sdk/ from the archive
make clean
```

Device access is SSH as root over USB. Start the tunnel with libimobiledevice
(add `-u <UDID>` if more than one device is plugged in):

```bash
iproxy 2223:22
```

`ipod-ssh.conf` is the SSH config. The phone's old OpenSSH needs the legacy
algorithms enabled there. Override with `make install SSH_CONF=...`.

## Limits

- Code is ARM, not Thumb (`-marm`).
- Embedded Swift only: no Foundation, `@objc`, reflection or `Codable`.
- Xcode 27 has no iOS 6 developer disk image, so `idevicescreenshot` and the
  debugger don't work. `make screenshot` uses UIKit's private
  `UIGetScreenImage()` over SSH instead.

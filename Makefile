# Builds an armv7 / iOS 6 app for the iPod touch (4th gen) with the current Xcode's clang,
# Embedded Swift from a swift.org toolchain, and the iOS 9.3 SDK in ./sdk
# (from github.com/theos/sdks). There's no iOS 6 SDK there, so the 9.3 headers are used
# with -Werror=unguarded-availability to reject anything newer than MIN_IOS.

APP      := HelloWorld
BUNDLE_ID := org.millertechnology.hello-ios6
BUNDLE   := build/$(APP).app
CLI      := build/hello-swift
SDK      := sdk/iPhoneOS9.3.sdk
MIN_IOS  := 6.0
ARCH     := armv7

CC       := xcrun clang
# -marm: Xcode 27's linker writes an even LC_MAIN entry offset for Thumb code,
# so dyld enters a Thumb main() in ARM state and the app crashes at launch.
CFLAGS   := -arch $(ARCH) -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) \
            -marm -fobjc-arc -O2 -Wall -Werror=unguarded-availability -Iswift
LDBASE   := -arch $(ARCH) -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS)
LDFLAGS  := $(LDBASE) -framework UIKit -framework Foundation

# Embedded Swift. Xcode's toolchain has no Embedded stdlib; swift.org's does,
# for armv7-apple-none-macho (bare-metal armv7 Mach-O), which we link for iOS.
# -marm: as for CFLAGS. -ffixed-r9: iOS lets callees clobber r9, but the
# bare-metal target keeps values in it across calls into libSystem.
SWIFT_TOOLCHAIN ?= $(HOME)/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain
SWIFTC     := $(SWIFT_TOOLCHAIN)/usr/bin/swiftc
SWIFTFLAGS := -target armv7-apple-none-macho -enable-experimental-feature Embedded \
              -wmo -Osize -Xcc -marm -Xcc -ffixed-r9
SWIFT_SRCS := $(wildcard swift/*.swift)

# Install target on the jailbroken iPod (SSH over USB via iproxy, see README)
SSH_CONF ?= ipod-ssh.conf
SSH_HOST ?= ipod

SRCS := $(wildcard src/*.m)
OBJS := $(patsubst src/%.m,build/obj/%.o,$(SRCS)) build/obj/swift.o

# Preserved, unmodified copy of the SDK (sha256 in the .sha256 file next to it)
SDK_ARCHIVE ?= /Volumes/4TB/Downloads/iPhoneOS9.3.sdk.tar.xz

.PHONY: all clean ipa install run screenshot sdk cli run-cli
.DEFAULT_GOAL := all

# Unpacks the SDK and drops i386/x86_64 from its .tbd stubs: Xcode 27's linker
# reads the mixed device/simulator stubs as simulator-only and refuses to link.
sdk:
	rm -rf $(SDK) && mkdir -p sdk
	tar -xJf $(SDK_ARCHIVE) -C sdk
	find $(SDK) -name '*.tbd' -type f -print0 | xargs -0 sed -i '' -E \
	  's/(archs: *\[ armv7, armv7s, arm64), i386, x86_64 \]/\1 ]/'
	# The stubs omit the mem* functions (Swift's stdlib calls them directly).
	# libSystem re-exports libsystem_platform, so dyld finds them at run time.
	perl -0pi -e 's/(symbols: *\[ )/$$1_bzero, _memcmp, _memcpy, _memmove, _memset, /' \
	  $(SDK)/usr/lib/system/libsystem_platform.tbd

all: $(BUNDLE)/$(APP)

build/obj/%.o: src/%.m swift/HelloIOS6.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

# The linker warns "no platform load command found" for Swift objects, since
# they're built for a bare-metal target. It assumes iOS, which is what we want.
build/obj/swift.o: $(SWIFT_SRCS)
	@mkdir -p $(dir $@)
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -c $(SWIFT_SRCS) -o $@

build/obj/cli.o: $(SWIFT_SRCS) cli/main.swift
	@mkdir -p $(dir $@)
	$(SWIFTC) $(SWIFTFLAGS) -c $(SWIFT_SRCS) cli/main.swift -o $@

cli: $(CLI)

$(CLI): build/obj/cli.o
	$(CC) $(LDBASE) $< -o $@.tmp
	ldid -S $@.tmp
	mv $@.tmp $@

# Copies the command-line tool to /var/root on the phone and runs it.
run-cli: $(CLI)
	ssh -F $(SSH_CONF) $(SSH_HOST) 'cat > /var/root/hello-swift && chmod 755 /var/root/hello-swift && /var/root/hello-swift' < $(CLI)

$(BUNDLE)/$(APP): $(OBJS) src/Info.plist
	@mkdir -p $(BUNDLE)
	$(CC) $(LDFLAGS) $(OBJS) -o $@.tmp
	ldid -S $@.tmp
	mv $@.tmp $@
	plutil -convert binary1 -o $(BUNDLE)/Info.plist src/Info.plist
	printf 'APPL????' > $(BUNDLE)/PkgInfo

ipa: $(BUNDLE)/$(APP)
	rm -rf build/ipa && mkdir -p build/ipa/Payload
	cp -R $(BUNDLE) build/ipa/Payload/
	cd build/ipa && COPYFILE_DISABLE=1 zip -qr ../$(APP).ipa Payload

# Copies the app into /Applications and refreshes the home screen.
# Apps in /Applications run on a jailbroken device without AppSync.
install: $(BUNDLE)/$(APP)
	COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C build -cf - $(APP).app | \
	  ssh -F $(SSH_CONF) $(SSH_HOST) 'cd / && rm -rf /Applications/$(APP).app && tar -C /Applications -xf - && chown -R root:wheel /Applications/$(APP).app && su mobile -c uicache'

# Launches the installed app through SpringBoardServices (the iPod must be unlocked).
build/launch: tools/launch.c tools/launch.plist
	@mkdir -p build
	$(CC) $(LDBASE) -marm -O2 -Wall -framework CoreFoundation $< -o $@.tmp
	ldid -Stools/launch.plist $@.tmp
	mv $@.tmp $@

run: build/launch
	ssh -F $(SSH_CONF) $(SSH_HOST) 'cat > /var/root/launch && chmod 755 /var/root/launch && /var/root/launch $(BUNDLE_ID)' < build/launch

# Saves the iPod's screen to build/screenshot.png.
build/screenshot: tools/screenshot.m
	@mkdir -p build
	$(CC) $(LDBASE) -marm -O2 -Wall -framework UIKit -framework Foundation -framework CoreGraphics $< -o $@.tmp
	ldid -S $@.tmp
	mv $@.tmp $@

screenshot: build/screenshot
	ssh -F $(SSH_CONF) $(SSH_HOST) 'cat > /var/root/screenshot && chmod 755 /var/root/screenshot' < build/screenshot
	ssh -F $(SSH_CONF) $(SSH_HOST) /var/root/screenshot > build/screenshot.png

clean:
	rm -rf build

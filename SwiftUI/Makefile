# Builds SwiftUI apps for iOS 6 / armv7 (iPod touch 4th gen) with Embedded Swift.
#
#   make                       build the example in EXAMPLE (default Counter)
#   make install               copy it to a jailbroken device over SSH
#   make EXAMPLE=Other install
#
# An app in another folder sets APP, APP_DIR and BUILD (see ../WiFiScanner).
# APP_DIR holds its Swift sources and Info.plist, and optionally C or
# Objective-C sources built for iOS, a Clang module in include/, and
# Entitlements.plist for signing.
#
# Needs Xcode (clang, ld), a swift.org toolchain (Embedded stdlib) and the
# iOS 9.3 SDK in ../sdk (`make sdk` in the parent directory).

EXAMPLE  ?= Counter
APP      ?= $(EXAMPLE)
APP_DIR  ?= Examples/$(EXAMPLE)
BUILD    ?= build
BUNDLE   := $(BUILD)/$(APP).app
BUNDLE_ID = $(shell plutil -extract CFBundleIdentifier raw $(APP_DIR)/Info.plist)
SDK      := ../sdk/iPhoneOS9.3.sdk
# Objective-C messaging from Swift (`import ObjCInterop`), built into every app.
OBJC     := ../ObjC
MIN_IOS  := 6.0
ARCH     := armv7

SWIFT_TOOLCHAIN ?= $(HOME)/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain
SWIFTC := $(SWIFT_TOOLCHAIN)/usr/bin/swiftc
SWIFT_EMBEDDED_LIB := $(SWIFT_TOOLCHAIN)/usr/lib/swift/embedded/armv7-apple-none-macho
CC     := xcrun clang

# Xcode's linker writes an even LC_MAIN entry offset for Thumb code, so a
# Thumb main() is entered in ARM state and crashes: build everything as ARM.
# The 9.3 headers stand in for iOS 6's; -Werror=unguarded-availability rejects
# anything newer than MIN_IOS.
CFLAGS  := -arch $(ARCH) -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) \
           -marm -fobjc-arc -O2 -Wall -Werror=unguarded-availability \
           -ISources/CSwiftUIBackend/include -I$(APP_DIR)/include
# The executor hooks and libc shims are called by the Swift runtime with its
# (bare-metal) calling convention, so they are compiled for the same target.
EXECUTOR_CFLAGS := -target armv7-apple-none-macho -ffreestanding -marm -ffixed-r9 \
                   -O2 -Wall -ISources/CSwiftUIBackend/include -I$(OBJC)/include
# String comparison and normalization need the stdlib's Unicode tables;
# only the parts an app uses are linked. The concurrency runtime is C++, and
# -dead_strip drops its unused parts, which reference symbols nothing defines.
LDFLAGS := -arch $(ARCH) -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) \
           -framework UIKit -framework Foundation -lc++ -Wl,-dead_strip
RUNTIME_LIBS := $(SWIFT_EMBEDDED_LIB)/libswiftUnicodeDataTables.a \
                $(SWIFT_EMBEDDED_LIB)/libswift_Concurrency.a
LLVM_OBJCOPY := $(SWIFT_TOOLCHAIN)/usr/bin/llvm-objcopy

# Everything built for the bare-metal target. Its calls into iOS code go
# through r9-preserving trampolines (see tools/r9wrap.py), written to $(BUILD)/r9.
BAREMETAL := $(BUILD)/obj/$(APP).o $(BUILD)/obj/SwiftUI.o $(BUILD)/obj/ObjCInterop.o $(BUILD)/obj/Executor.o \
             $(BUILD)/obj/Compat.o $(RUNTIME_LIBS)
WRAPPED   := $(addprefix $(BUILD)/r9/$(APP)/,$(notdir $(BAREMETAL))) $(BUILD)/r9/$(APP)/trampolines.o

# There's no Embedded stdlib for armv7-apple-ios, so Swift targets bare-metal
# armv7 Mach-O and is linked into the iOS binary. -ffixed-r9: iOS lets callees
# clobber r9, but the bare-metal convention expects it preserved.
SWIFTFLAGS := -target armv7-apple-none-macho -enable-experimental-feature Embedded \
              -wmo -Osize -Xcc -marm -Xcc -ffixed-r9 \
              -ISources/CSwiftUIBackend/include -I$(OBJC)/include -I$(BUILD)/modules -I$(APP_DIR)/include

SWIFTUI_SRCS := $(wildcard Sources/SwiftUI/*.swift)
APP_SRCS     := $(wildcard $(APP_DIR)/*.swift)
# The app's own C and Objective-C code, built for iOS like the backend.
APP_C_SRCS   := $(wildcard $(APP_DIR)/*.c $(APP_DIR)/*.m)
APP_HEADERS  := $(wildcard $(APP_DIR)/include/*.h)
APP_OBJS     := $(patsubst %,$(BUILD)/obj/$(APP)-%.o,$(basename $(notdir $(APP_C_SRCS))))
ENTITLEMENTS ?= $(wildcard $(APP_DIR)/Entitlements.plist)
# Headers of the iOS-side functions Swift calls, for the trampolines' stack arguments.
IOS_HEADERS  := Sources/CSwiftUIBackend/include/SwiftUIBackend.h $(OBJC)/include/ObjCRuntime.h $(APP_HEADERS)
comma := ,
empty :=
space := $(empty) $(empty)

SSH_CONF ?= ../ipod-ssh.conf
SSH_HOST ?= ipod

.PHONY: all install run clean
.DEFAULT_GOAL := all

all: $(BUNDLE)/$(APP)

# Also writes $(BUILD)/modules/SwiftUI.swiftmodule.
$(BUILD)/obj/SwiftUI.o: $(SWIFTUI_SRCS) Sources/CSwiftUIBackend/include/SwiftUIBackend.h $(BUILD)/obj/ObjCInterop.o
	@mkdir -p $(BUILD)/modules $(BUILD)/obj
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-name SwiftUI \
	  -emit-module -emit-module-path $(BUILD)/modules/SwiftUI.swiftmodule \
	  -c $(SWIFTUI_SRCS) -o $@

# Also writes $(BUILD)/modules/ObjCInterop.swiftmodule.
$(BUILD)/obj/ObjCInterop.o: $(OBJC)/Sources/ObjCInterop.swift $(OBJC)/include/ObjCRuntime.h
	@mkdir -p $(BUILD)/modules $(BUILD)/obj
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-name ObjCInterop \
	  -emit-module -emit-module-path $(BUILD)/modules/ObjCInterop.swiftmodule \
	  -c $(OBJC)/Sources/ObjCInterop.swift -o $@

$(BUILD)/obj/ObjCRuntime.o: $(OBJC)/ObjCRuntime.c $(OBJC)/include/ObjCRuntime.h
	@mkdir -p $(BUILD)/obj
	$(CC) $(CFLAGS) -I$(OBJC)/include -c $< -o $@

$(BUILD)/obj/$(APP).o: $(APP_SRCS) $(APP_HEADERS) $(BUILD)/obj/SwiftUI.o $(BUILD)/obj/ObjCInterop.o
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-name $(APP) -c $(APP_SRCS) -o $@

$(BUILD)/obj/$(APP)-%.o: $(APP_DIR)/%.c $(APP_HEADERS)
	@mkdir -p $(BUILD)/obj
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/obj/$(APP)-%.o: $(APP_DIR)/%.m $(APP_HEADERS)
	@mkdir -p $(BUILD)/obj
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/obj/Executor.o: Sources/CSwiftUIBackend/Executor.c $(OBJC)/include/ObjCRuntime.h
	@mkdir -p $(BUILD)/obj
	$(CC) $(EXECUTOR_CFLAGS) -c $< -o $@

$(BUILD)/obj/Compat.o: Sources/CSwiftUIBackend/Compat.c
	@mkdir -p $(BUILD)/obj
	$(CC) $(EXECUTOR_CFLAGS) -c $< -o $@

# The linker warns "no platform load command found" for the Swift objects
# (bare-metal target) and assumes iOS, which is what we want.
$(BUILD)/r9/$(APP)/trampolines.s: $(BAREMETAL) tools/r9wrap.py $(IOS_HEADERS)
	LLVM_OBJCOPY=$(LLVM_OBJCOPY) python3 tools/r9wrap.py $(BUILD)/r9/$(APP) \
	  $(subst $(space),$(comma),$(strip $(IOS_HEADERS))) $(BAREMETAL)

$(BUILD)/r9/$(APP)/trampolines.o: $(BUILD)/r9/$(APP)/trampolines.s
	$(CC) -arch $(ARCH) -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) -c $< -o $@

$(BUNDLE)/$(APP): $(BUILD)/r9/$(APP)/trampolines.o $(BUILD)/obj/ObjCRuntime.o $(APP_OBJS) $(APP_DIR)/Info.plist $(ENTITLEMENTS)
	@mkdir -p $(BUNDLE)
	$(CC) $(LDFLAGS) $(WRAPPED) $(BUILD)/obj/ObjCRuntime.o $(APP_OBJS) -o $@.tmp
	ldid -S$(ENTITLEMENTS) $@.tmp
	mv $@.tmp $@
	plutil -convert binary1 -o $(BUNDLE)/Info.plist $(APP_DIR)/Info.plist
	printf 'APPL????' > $(BUNDLE)/PkgInfo

# Copies the app into /Applications (runs without AppSync on a jailbroken
# device) and refreshes the home screen.
install: $(BUNDLE)/$(APP)
	COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C $(BUILD) -cf - $(APP).app | \
	  ssh -F $(SSH_CONF) $(SSH_HOST) 'cd / && rm -rf /Applications/$(APP).app && tar -C /Applications -xf - && chown -R root:wheel /Applications/$(APP).app && su mobile -c uicache'

# Launches the installed app (the iPod must be unlocked). Uses ../tools/launch.c.
run:
	$(MAKE) -C .. build/launch
	ssh -F $(SSH_CONF) $(SSH_HOST) 'cat > /var/root/launch && chmod 755 /var/root/launch && /var/root/launch $(BUNDLE_ID)' < ../build/launch

clean:
	rm -rf $(BUILD)

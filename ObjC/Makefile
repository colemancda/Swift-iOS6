# Builds the ObjCInterop module and its on-device tests.
#
#   make        build build/objc-tests
#   make test   copy it to the iPod and run it
#
# SwiftUI apps get the module through ../SwiftUI/Makefile.

SDK     := ../sdk/iPhoneOS9.3.sdk
MIN_IOS := 6.0
CC      := xcrun clang
SWIFT_TOOLCHAIN ?= $(HOME)/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain
SWIFTC  := $(SWIFT_TOOLCHAIN)/usr/bin/swiftc
SWIFT_EMBEDDED_LIB := $(SWIFT_TOOLCHAIN)/usr/lib/swift/embedded/armv7-apple-none-macho

# As in ../Makefile: ARM code (not Thumb), r9 left alone by Swift.
SWIFTFLAGS := -target armv7-apple-none-macho -enable-experimental-feature Embedded \
              -wmo -Osize -Xcc -marm -Xcc -ffixed-r9 -Iinclude -Ibuild/modules
CFLAGS     := -arch armv7 -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) -marm -O2 -Wall -Iinclude
LDFLAGS    := -arch armv7 -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) \
              -framework Foundation -framework UIKit -Wl,-dead_strip \
              $(SWIFT_EMBEDDED_LIB)/libswiftUnicodeDataTables.a

SSH_CONF ?= ../ipod-ssh.conf
SSH_HOST ?= ipod

.PHONY: all test clean
all: build/objc-tests

build/obj/ObjCInterop.o: Sources/ObjCInterop.swift include/ObjCRuntime.h
	@mkdir -p build/obj build/modules
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-name ObjCInterop \
	  -emit-module -emit-module-path build/modules/ObjCInterop.swiftmodule -c Sources/ObjCInterop.swift -o $@

build/obj/Tests.o: Tests/main.swift build/obj/ObjCInterop.o
	$(SWIFTC) $(SWIFTFLAGS) -module-name ObjCTests -c Tests/main.swift -o $@

build/obj/ObjCRuntime.o: ObjCRuntime.c include/ObjCRuntime.h
	@mkdir -p build/obj
	$(CC) $(CFLAGS) -c $< -o $@

build/objc-tests: build/obj/Tests.o build/obj/ObjCInterop.o build/obj/ObjCRuntime.o
	$(CC) $(LDFLAGS) $^ -o $@.tmp
	ldid -S $@.tmp
	mv $@.tmp $@

test: build/objc-tests
	ssh -F $(SSH_CONF) $(SSH_HOST) 'cd / && cat > /tmp/objc-tests && chmod 755 /tmp/objc-tests && su mobile -c /tmp/objc-tests' < $<

clean:
	rm -rf build

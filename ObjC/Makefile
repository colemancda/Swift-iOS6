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

# The macros (@ObjC, @ObjCMethod, @ObjCProperty, @ObjCImplementation) are a
# compiler plugin built for the Mac, against the swift-syntax libraries the
# toolchain ships for its own macros, and loaded into every Swift compile.
HOST_LIB   := $(SWIFT_TOOLCHAIN)/usr/lib/swift/host
MACOS_SDK  := $(shell xcrun --sdk macosx --show-sdk-path)
MACROS     := build/plugins/libObjCMacros.dylib

# As in ../Makefile: ARM code (not Thumb), r9 left alone by Swift.
SWIFTFLAGS := -target armv7-apple-none-macho -enable-experimental-feature Embedded \
              -wmo -Osize -Xcc -marm -Xcc -ffixed-r9 -Iinclude -Ibuild/modules \
              -load-plugin-library $(abspath $(MACROS))
CFLAGS     := -arch armv7 -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) -marm -O2 -Wall -Iinclude
LDFLAGS    := -arch armv7 -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) \
              -framework Foundation -Wl,-dead_strip \
              $(SWIFT_EMBEDDED_LIB)/libswiftUnicodeDataTables.a

SSH_CONF ?= ../ipod-ssh.conf
SSH_HOST ?= ipod

.PHONY: all test clean macros
all: build/objc-tests
macros: $(MACROS)

$(MACROS): Macros/ObjCMacros.swift
	@mkdir -p build/plugins
	$(SWIFT_TOOLCHAIN)/usr/bin/swiftc -sdk $(MACOS_SDK) -emit-library -module-name ObjCMacros -O \
	  -I $(HOST_LIB) -L $(HOST_LIB) -lSwiftSyntax -lSwiftSyntaxMacros -lSwiftSyntaxBuilder \
	  -lSwiftDiagnostics -lSwiftBasicFormat -Xlinker -rpath -Xlinker $(HOST_LIB) $< -o $@

build/obj/ObjCInterop.o: Sources/ObjCInterop.swift include/ObjCRuntime.h $(MACROS)
	@mkdir -p build/obj build/modules
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-name ObjCInterop \
	  -emit-module -emit-module-path build/modules/ObjCInterop.swiftmodule -c Sources/ObjCInterop.swift -o $@

build/obj/Tests.o: $(wildcard Tests/*.swift) build/obj/ObjCInterop.o
	$(SWIFTC) $(SWIFTFLAGS) -module-name ObjCTests -c $(wildcard Tests/*.swift) -o $@

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

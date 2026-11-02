# Builds the XML module and its on-device tests.
#
#   make        build build/xml-tests
#   make test   copy it to the iPod and run it
#
# SwiftUI apps get the module with LIBS=XML (see ../XMLBrowser).

OBJC    := ../ObjC
SDK     := ../sdk/iPhoneOS9.3.sdk
MIN_IOS := 6.0
CC      := xcrun clang
SWIFT_TOOLCHAIN ?= $(HOME)/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain
SWIFTC  := $(SWIFT_TOOLCHAIN)/usr/bin/swiftc
SWIFT_EMBEDDED_LIB := $(SWIFT_TOOLCHAIN)/usr/lib/swift/embedded/armv7-apple-none-macho
MACROS  := $(abspath $(OBJC))/build/plugins/libObjCMacros.dylib

# As in ../ObjC/Makefile.
SWIFTFLAGS := -target armv7-apple-none-macho -enable-experimental-feature Embedded \
              -wmo -Osize -Xcc -marm -Xcc -ffixed-r9 -I$(OBJC)/include -I$(OBJC)/build/modules -Ibuild/modules \
              -load-plugin-library $(MACROS)
LDFLAGS    := -arch armv7 -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) \
              -framework Foundation -Wl,-dead_strip \
              $(SWIFT_EMBEDDED_LIB)/libswiftUnicodeDataTables.a

SSH_CONF ?= ../ipod-ssh.conf
SSH_HOST ?= ipod

OBJC_OBJS := $(OBJC)/build/obj/ObjCInterop.o $(OBJC)/build/obj/ObjCRuntime.o

.PHONY: all test clean FORCE
all: build/xml-tests

# ObjCInterop, its module and the macros, from ../ObjC (which knows when
# they're out of date).
$(OBJC)/build/obj/%.o: FORCE
	$(MAKE) -C $(OBJC) build/obj/$*.o

build/obj/XML.o: $(wildcard Sources/*.swift) $(OBJC_OBJS)
	@mkdir -p build/obj build/modules
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-name XML \
	  -emit-module -emit-module-path build/modules/XML.swiftmodule -c $(wildcard Sources/*.swift) -o $@

build/obj/Tests.o: $(wildcard Tests/*.swift) build/obj/XML.o
	$(SWIFTC) $(SWIFTFLAGS) -module-name XMLTests -c $(wildcard Tests/*.swift) -o $@

build/xml-tests: build/obj/Tests.o build/obj/XML.o $(OBJC_OBJS)
	$(CC) $(LDFLAGS) $^ -o $@.tmp
	ldid -S $@.tmp
	mv $@.tmp $@

test: build/xml-tests
	ssh -F $(SSH_CONF) $(SSH_HOST) 'cd / && cat > /tmp/xml-tests && chmod 755 /tmp/xml-tests && su mobile -c /tmp/xml-tests' < $<

clean:
	rm -rf build

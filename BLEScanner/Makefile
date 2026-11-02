# Builds the Bluetooth LE scanner with the SwiftUI library in ../SwiftUI and the
# frameworks generated in ../Frameworks (listed in LIBS).
#
#   make           build build/BLEScanner.app
#   make install   copy it to the iPod
#   make run       launch it (the iPod must be unlocked)

APP     := BLEScanner
SWIFTUI := ../SwiftUI
SSH_CONF ?= $(abspath ../ipod-ssh.conf)
SSH_HOST ?= ipod
SWIFTUI_MAKE = $(MAKE) -C $(SWIFTUI) APP=$(APP) APP_DIR=$(CURDIR) BUILD=$(CURDIR)/build \
               SSH_CONF=$(SSH_CONF) SSH_HOST=$(SSH_HOST)

.PHONY: all install run clean
.DEFAULT_GOAL := all

all install run:
	$(SWIFTUI_MAKE) $@

clean:
	rm -rf build

# Builds the system information app with the SwiftUI library in ../SwiftUI.
#
#   make           build build/SystemInfo.app
#   make install   copy it to the iPod
#   make run       launch it (the iPod must be unlocked)
#
# ../SwiftUI/Makefile does the work: it builds the Swift and C sources here,
# links them with the SwiftUI library and signs the app with Entitlements.plist.

APP     := SystemInfo
SWIFTUI := ../SwiftUI
SWIFTUI_MAKE = $(MAKE) -C $(SWIFTUI) APP=$(APP) APP_DIR=$(CURDIR) BUILD=$(CURDIR)/build \
               SSH_CONF=$(abspath ../ipod-ssh.conf)

.PHONY: all install run clean
.DEFAULT_GOAL := all

all install run:
	$(SWIFTUI_MAKE) $@

clean:
	rm -rf build

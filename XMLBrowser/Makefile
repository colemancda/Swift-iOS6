# Builds the XML browser with the SwiftUI library in ../SwiftUI and the XML
# module in ../XML.
#
#   make           build build/XMLBrowser.app
#   make install   copy it to the iPod
#   make run       launch it (the iPod must be unlocked)
#
# ../SwiftUI/Makefile does the work: it builds ../XML (LIBS=XML) and the Swift
# sources here, links them with the SwiftUI library, and bundles Resources/.

APP     := XMLBrowser
SWIFTUI := ../SwiftUI
SWIFTUI_MAKE = $(MAKE) -C $(SWIFTUI) APP=$(APP) APP_DIR=$(CURDIR) BUILD=$(CURDIR)/build LIBS=XML \
               SSH_CONF=$(abspath ../ipod-ssh.conf)

.PHONY: all install run clean
.DEFAULT_GOAL := all

all install run:
	$(SWIFTUI_MAKE) $@

clean:
	rm -rf build

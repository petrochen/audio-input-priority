LABEL   = com.apetrochenko.audio-input-priority
APP     = $(HOME)/Applications/AudioPriority.app
EXE     = $(APP)/Contents/MacOS/audio-input-priority
BIN     = $(HOME)/bin/audio-input-priority
CONFIG  = $(HOME)/.config/audio-input-priority/devices
DOMAIN  = gui/$(shell id -u)
PLIST   = $(HOME)/Library/LaunchAgents/$(LABEL).plist

.PHONY: build app icon release install uninstall start stop restart status log list

build:
	swiftc -O -o audio-input-priority audio-input-priority.swift

app: build
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	rm -rf "$(APP)/Contents/Library"
	cp audio-input-priority "$(EXE)"
	cp Info.plist "$(APP)/Contents/Info.plist"
	cp AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	codesign -f -s - "$(APP)" 2>/dev/null

icon:   # regenerate AppIcon.icns from scripts/make-icon.swift
	swiftc -O -o /tmp/make-icon scripts/make-icon.swift && rm -rf /tmp/AppIcon.iconset && /tmp/make-icon /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o AppIcon.icns

VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
release:   # zip of the app bundle for GitHub Releases (ad-hoc signed, see README about Gatekeeper)
	$(MAKE) app APP=dist/AudioPriority.app
	cd dist && rm -f AudioPriority-$(VERSION).zip && ditto -c -k --keepParent AudioPriority.app AudioPriority-$(VERSION).zip && shasum -a 256 AudioPriority-$(VERSION).zip

# Builds the app, enables "Start at login" (the app writes its own LaunchAgent) and starts it.
install: app
	mkdir -p $(HOME)/bin $(dir $(CONFIG))
	ln -sf "$(EXE)" $(BIN)
	test -f $(CONFIG) || cp devices.example $(CONFIG)
	test -f $(dir $(CONFIG))outputs || cp outputs.example $(dir $(CONFIG))outputs
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null; pkill -f "$(EXE)" 2>/dev/null; sleep 1
	"$(EXE)" --register

uninstall:
	-"$(EXE)" --unregister 2>/dev/null; pkill -f "$(EXE)" 2>/dev/null; true
	rm -rf "$(APP)" $(BIN) $(PLIST)

start:
	"$(EXE)" --register

stop:
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null; pkill -f "$(EXE)" 2>/dev/null; true

restart: stop
	sleep 1; $(MAKE) start

status:
	@launchctl print $(DOMAIN)/$(LABEL) 2>/dev/null | grep -E '^\s*(state|pid) =' || echo "not loaded by launchd"
	@$(BIN) --list

log:
	tail -n 30 $(HOME)/Library/Logs/audio-input-priority.log

list:
	$(BIN) --list

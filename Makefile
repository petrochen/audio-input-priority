LABEL   = com.apetrochenko.audio-input-priority
APP     = $(HOME)/Applications/AudioPriority.app
EXE     = $(APP)/Contents/MacOS/audio-input-priority
BIN     = $(HOME)/bin/audio-input-priority
CONFIG  = $(HOME)/.config/audio-input-priority/devices
DOMAIN  = gui/$(shell id -u)
PLIST   = $(HOME)/Library/LaunchAgents/$(LABEL).plist

.PHONY: build app install uninstall start stop restart status log list

build:
	swiftc -O -o audio-input-priority audio-input-priority.swift

app: build
	mkdir -p "$(APP)/Contents/MacOS"
	rm -rf "$(APP)/Contents/Library"
	cp audio-input-priority "$(EXE)"
	cp Info.plist "$(APP)/Contents/Info.plist"
	codesign -f -s - "$(APP)" 2>/dev/null

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

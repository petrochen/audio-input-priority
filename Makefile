LABEL   = com.apetrochenko.audio-input-priority
APP     = $(HOME)/Applications/AudioPriority.app
EXE     = $(APP)/Contents/MacOS/audio-input-priority
BIN     = $(HOME)/bin/audio-input-priority
PLIST   = $(HOME)/Library/LaunchAgents/$(LABEL).plist
CONFIG  = $(HOME)/.config/audio-input-priority/devices
DOMAIN  = gui/$(shell id -u)

.PHONY: build app install uninstall start stop restart status log list

build:
	swiftc -O -o audio-input-priority audio-input-priority.swift

app: build
	mkdir -p "$(APP)/Contents/MacOS"
	cp audio-input-priority "$(EXE)"
	cp Info.plist "$(APP)/Contents/Info.plist"
	codesign -f -s - "$(APP)" 2>/dev/null

install: app
	mkdir -p $(HOME)/bin $(HOME)/Library/LaunchAgents $(dir $(CONFIG))
	ln -sf "$(EXE)" $(BIN)
	test -f $(CONFIG) || cp devices.example $(CONFIG)
	test -f $(dir $(CONFIG))outputs || cp outputs.example $(dir $(CONFIG))outputs
	sed 's|__HOME__|$(HOME)|g' $(LABEL).plist > $(PLIST)
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null; sleep 1
	launchctl bootstrap $(DOMAIN) $(PLIST)

uninstall: stop
	rm -rf "$(APP)" $(BIN) $(PLIST)

start:
	launchctl bootstrap $(DOMAIN) $(PLIST)

stop:
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null; sleep 1

restart: stop start

status:
	@launchctl print $(DOMAIN)/$(LABEL) 2>/dev/null | grep -E '^\s*(state|pid) =' || echo "not loaded"
	@$(BIN) --list

log:
	tail -n 30 $(HOME)/Library/Logs/audio-input-priority.log

list:
	$(BIN) --list

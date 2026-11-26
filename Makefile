CERT_NAME := dltidy Local Signing
APP       := $(HOME)/Applications/DLTidy.app
AGENT     := $(HOME)/Library/LaunchAgents/local.dltidy.plist
LOGS      := $(HOME)/Library/Logs/dltidy
STATE     := $(HOME)/Library/Application Support/dltidy
BUILD_APP := .build/DLTidy.app
BIN_DIR   := $(HOME)/.local/bin
LINK      := $(BIN_DIR)/dltidy
UID_      := $(shell id -u)

.PHONY: build bundle sign install uninstall test

build:
	swift build -c release

test:
	swift test

bundle: build
	rm -rf "$(BUILD_APP)"
	mkdir -p "$(BUILD_APP)/Contents/MacOS"
	cp Support/Info.plist "$(BUILD_APP)/Contents/Info.plist"
	cp .build/release/dltidy "$(BUILD_APP)/Contents/MacOS/dltidy"
	mkdir -p "$(BUILD_APP)/Contents/Resources/magick"
	cp Support/magick/policy.xml "$(BUILD_APP)/Contents/Resources/magick/policy.xml"

sign: bundle
	KC=$$(Support/make-cert.sh) || exit 1; \
	  HASH=$$(security find-identity -p codesigning "$$KC" | awk -v n='"$(CERT_NAME)"' '$$0 ~ n {print $$2; exit}'); \
	  test -n "$$HASH" || { security lock-keychain "$$KC"; echo "signing identity not found"; exit 1; }; \
	  codesign --force --options runtime --keychain "$$KC" --sign "$$HASH" --identifier local.dltidy --timestamp=none "$(BUILD_APP)"; \
	  RC=$$?; security lock-keychain "$$KC"; exit $$RC
	codesign -d -r- "$(BUILD_APP)" 2>&1 | grep designated

install: sign
	-launchctl bootout gui/$(UID_)/local.dltidy 2>/dev/null
	mkdir -p "$(HOME)/Applications" "$(LOGS)" "$(HOME)/Library/LaunchAgents"
	rm -rf "$(APP)"
	ditto "$(BUILD_APP)" "$(APP)"
	sed -e 's|@APP@|$(APP)|g' -e 's|@LOGS@|$(LOGS)|g' Support/local.dltidy.plist.template > "$(AGENT)"
	plutil -lint "$(AGENT)"
	launchctl bootstrap gui/$(UID_) "$(AGENT)"
	launchctl kickstart gui/$(UID_)/local.dltidy
	mkdir -p "$(BIN_DIR)"
	ln -sfn "$(APP)/Contents/MacOS/dltidy" "$(LINK)"
	@case ":$$PATH:" in *":$(BIN_DIR):"*) ;; *) echo "note: $(BIN_DIR) is not on PATH; add it in ~/.zshrc (export PATH=\"\$$HOME/.local/bin:\$$PATH\")";; esac
	@echo "installed; log: $(LOGS)/dltidy.log"
	@sleep 3
	-"$(LINK)" doctor

uninstall:
	-launchctl bootout gui/$(UID_)/local.dltidy 2>/dev/null
	rm -f "$(AGENT)"
	rm -rf "$(APP)"
	rm -f "$(LINK)"
ifeq ($(PURGE),1)
	rm -rf "$(STATE)" "$(LOGS)"
	-security delete-generic-password -s local.dltidy >/dev/null 2>&1
endif

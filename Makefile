APP_NAME = BetterBar
BUNDLE_ID = com.yohan.betterbar
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
APP_EXECUTABLE = $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
APP_ICON = $(BUILD_DIR)/AppIcon.icns
TEST_EXECUTABLE = $(BUILD_DIR)/CoreTests
INSTALL_DIR = /Applications
CORE_SOURCES = $(wildcard Sources/Core/*.swift)
APP_SOURCES = $(CORE_SOURCES) $(wildcard Sources/App/*.swift)
TEST_SOURCES = $(filter-out Sources/App/main.swift,$(APP_SOURCES)) Tests/main.swift

# Self-signed identity (create with `make cert`); falls back to ad-hoc.
CODESIGN_ID ?= BetterBar Signing
SIGN_ID = $(shell security find-certificate -c "$(CODESIGN_ID)" >/dev/null 2>&1 && echo "$(CODESIGN_ID)" || echo "-")

SWIFTC = swiftc
SWIFT_COMMON_FLAGS = -swift-version 6 -target arm64-apple-macosx27.0
SWIFT_FLAGS = -O -whole-module-optimization $(SWIFT_COMMON_FLAGS)
FRAMEWORKS = -framework Cocoa -framework SwiftUI -framework ApplicationServices -framework ServiceManagement

.PHONY: all build cert test check test-spacing-relaunch install run uninstall clean

all: build

cert:
	@./scripts/make-cert.sh "$(CODESIGN_ID)"

build: $(APP_EXECUTABLE)

$(APP_ICON): Resources/AppIcon.png scripts/make-icon.sh Makefile
	@./scripts/make-icon.sh "$<" "$@"

$(APP_EXECUTABLE): $(APP_SOURCES) Info.plist $(APP_ICON) Makefile
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	$(SWIFTC) $(SWIFT_FLAGS) $(FRAMEWORKS) $(APP_SOURCES) -o "$@"
	@cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@cp "$(APP_ICON)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	codesign --force --sign "$(SIGN_ID)" --options runtime "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE) (signed with: $(SIGN_ID))"

$(TEST_EXECUTABLE): $(TEST_SOURCES) Makefile
	@mkdir -p "$(BUILD_DIR)"
	$(SWIFTC) $(SWIFT_COMMON_FLAGS) $(FRAMEWORKS) $(TEST_SOURCES) -o "$@"

test: $(TEST_EXECUTABLE)
	@"$(TEST_EXECUTABLE)"

check: build test
	@for script in scripts/*.sh; do bash -n "$$script" || exit; done
	@plutil -lint Info.plist Tests/SpacingFixture/Info.plist
	@codesign --verify --strict "$(APP_BUNDLE)"

test-spacing-relaunch:
	@./scripts/test-spacing-relaunch.sh

# Quitting first releases the restriction (every icon comes back).
install: build
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

run: install
	@open "$(INSTALL_DIR)/$(APP_NAME).app"

uninstall:
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@defaults delete $(BUNDLE_ID) >/dev/null 2>&1 || true
	@echo "Uninstalled."

clean:
	@rm -rf "$(BUILD_DIR)"

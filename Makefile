APP_NAME    := pitchshift
APP_BUNDLE  := $(APP_NAME).app
APP_DIR     := $(APP_BUNDLE)/Contents
BINARY      := .build/apple/Products/Release/$(APP_NAME)

.PHONY: build run install clean

build:
	swift build -c release --arch arm64 --arch x86_64
	@mkdir -p "$(APP_DIR)/MacOS" "$(APP_DIR)/Resources"
	cp $(BINARY) "$(APP_DIR)/MacOS/$(APP_NAME)"
	cp Info.plist "$(APP_DIR)/Info.plist"
	cp assets/AppIcon.icns "$(APP_DIR)/Resources/AppIcon.icns"
	cp assets/menubar_active.pdf "$(APP_DIR)/Resources/menubar_active.pdf"
	cp assets/menubar_inactive.pdf "$(APP_DIR)/Resources/menubar_inactive.pdf"
	codesign --force --sign - --entitlements pitchshift.entitlements "$(APP_BUNDLE)"
	@echo "\n✓ Built $(APP_BUNDLE)"

run: build
	open $(APP_BUNDLE)

install: build
	cp -R $(APP_BUNDLE) /Applications/$(APP_BUNDLE)
	@echo "✓ Installed to /Applications/$(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf "$(APP_DIR)/MacOS/$(APP_NAME)"
	@echo "✓ Cleaned"

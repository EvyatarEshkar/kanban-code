.PHONY: build test run app run-app run-release clean

BUNDLE_NAME = KanbanCode.app
BUNDLE_DIR = build/$(BUNDLE_NAME)
BUNDLE_ID = com.kanban-code.app
VERSION ?= 0.1.1
CONFIG ?= debug
ARCH := $(shell uname -m)
BUILD_DIR = .build/$(ARCH)-apple-macosx/$(CONFIG)

build:
	swift build

test:
	swift test

run:
	swift run KanbanCode

app: build
	@mkdir -p $(BUNDLE_DIR)/Contents/MacOS
	@mkdir -p $(BUNDLE_DIR)/Contents/Resources
	@cp $(BUILD_DIR)/KanbanCode $(BUNDLE_DIR)/Contents/MacOS/KanbanCode
	@# Active session marker app (detected by Amphetamine etc.)
	@mkdir -p $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app/Contents/MacOS
	@cp $(BUILD_DIR)/kanban-code-active-session $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app/Contents/MacOS/kanban-code-active-session
	@/bin/echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>kanban-code-active-session</string><key>CFBundleIdentifier</key><string>com.kanban-code.active-session</string><key>CFBundleName</key><string>kanban-code-active-session</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>$(VERSION)</string><key>LSUIElement</key><true/></dict></plist>' > $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app/Contents/Info.plist
	@codesign --force --sign - $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app
	@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app 2>/dev/null || true
	@cp Sources/KanbanCode/Resources/AppIcon.icns $(BUNDLE_DIR)/Contents/Resources/AppIcon.icns
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<plist version="1.0"><dict>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleExecutable</key><string>KanbanCode</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleName</key><string>Kanban Code</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleVersion</key><string>$(VERSION)</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleShortVersionString</key><string>$(VERSION)</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundlePackageType</key><string>APPL</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>LSMinimumSystemVersion</key><string>14.0</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>NSHighResolutionCapable</key><true/>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>LSUIElement</key><false/>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleIconFile</key><string>AppIcon</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleIconName</key><string>AppIcon</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.kanban-code</string><key>CFBundleURLSchemes</key><array><string>kanbancode</string></array></dict></array>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '</dict></plist>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@# Copy SPM bundle resources
	@if [ -d $(BUILD_DIR)/KanbanCode_KanbanCode.bundle ]; then \
		cp -R $(BUILD_DIR)/KanbanCode_KanbanCode.bundle $(BUNDLE_DIR)/Contents/Resources/; \
	fi
	@# Code sign so macOS grants notification permissions
	@codesign --force --sign - $(BUNDLE_DIR)
	@# Register with Launch Services so macOS picks up the icon
	@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f $(BUNDLE_DIR) 2>/dev/null || true
	@echo "Built $(BUNDLE_DIR)"

run-app: app
	open $(BUNDLE_DIR)

run-release:
	swift build -c release
	@$(MAKE) app CONFIG=release
	KANBAN_WATCHDOG=1 build/$(BUNDLE_NAME)/Contents/MacOS/KanbanCode

clean:
	swift package clean
	rm -rf build

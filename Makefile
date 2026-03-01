.PHONY: build test run app run-app clean

BUNDLE_NAME = Kanban.app
BUNDLE_DIR = build/$(BUNDLE_NAME)
BUNDLE_ID = com.kanban.app
VERSION = 0.1.0

build:
	swift build

test:
	swift test

run:
	swift run Kanban

app: build
	@mkdir -p $(BUNDLE_DIR)/Contents/MacOS
	@mkdir -p $(BUNDLE_DIR)/Contents/Resources
	@cp .build/arm64-apple-macosx/debug/Kanban $(BUNDLE_DIR)/Contents/MacOS/Kanban
	@cp Sources/Kanban/Resources/AppIcon.icns $(BUNDLE_DIR)/Contents/Resources/AppIcon.icns
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<plist version="1.0"><dict>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleExecutable</key><string>Kanban</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleName</key><string>Kanban</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleVersion</key><string>$(VERSION)</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleShortVersionString</key><string>$(VERSION)</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundlePackageType</key><string>APPL</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>LSMinimumSystemVersion</key><string>14.0</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>NSHighResolutionCapable</key><true/>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>LSUIElement</key><false/>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleIconFile</key><string>AppIcon</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleIconName</key><string>AppIcon</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '</dict></plist>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@# Copy SPM bundle resources (clawd icon, etc.)
	@if [ -d .build/arm64-apple-macosx/debug/Kanban_Kanban.bundle ]; then \
		cp -R .build/arm64-apple-macosx/debug/Kanban_Kanban.bundle $(BUNDLE_DIR)/Contents/Resources/; \
	fi
	@# Code sign so macOS grants notification permissions
	@codesign --force --sign - $(BUNDLE_DIR)
	@# Register with Launch Services so macOS picks up the icon
	@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f $(BUNDLE_DIR) 2>/dev/null || true
	@echo "Built $(BUNDLE_DIR)"

run-app: app
	open $(BUNDLE_DIR)

clean:
	swift package clean
	rm -rf build

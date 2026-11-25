APP := Lodestone
BUNDLE := build/$(APP).app
# Ad-hoc by default. Pass SIGN_ID="Your Identity" to sign with a real certificate, which keeps the
# Accessibility grant across rebuilds (an ad-hoc signature changes with every build).
SIGN_ID ?= -
# Pass ARCHS="arm64 x86_64" for a universal build (the release workflow does).
ARCHS ?=
SWIFT_RELEASE := swift build -c release $(foreach a,$(ARCHS),--arch $(a))

.PHONY: all app zip guide icons install test clean

all: app

app:
	$(SWIFT_RELEASE) --product $(APP)
	$(SWIFT_RELEASE) --product lodestone-cli
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources $(BUNDLE)/Contents/Helpers
	cp "$$($(SWIFT_RELEASE) --show-bin-path)/$(APP)" $(BUNDLE)/Contents/MacOS/$(APP)
	cp "$$($(SWIFT_RELEASE) --show-bin-path)/lodestone-cli" $(BUNDLE)/Contents/Helpers/lodestone
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png $(BUNDLE)/Contents/Resources/
	codesign --force --sign "$(SIGN_ID)" --identifier app.lodestone.cli $(BUNDLE)/Contents/Helpers/lodestone
	codesign --force --sign "$(SIGN_ID)" $(BUNDLE)

# build/Lodestone.zip for a GitHub release (ditto keeps the bundle's symlinks and signature intact).
zip: app
	ditto -c -k --sequesterRsrc --keepParent $(BUNDLE) build/$(APP).zip

# Regenerates docs/Lodestone-Guide.pdf from the running app's default shortcuts (needs Google Chrome).
CHROME ?= /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
guide:
	mkdir -p build
	lodestone shortcuts list --json > build/shortcuts.json
	python3 scripts/build-guide.py build/shortcuts.json build/guide.html
	"$(CHROME)" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf=docs/Lodestone-Guide.pdf "file://$(CURDIR)/build/guide.html"

# Regenerates the icon SVGs and renders them. The outputs are committed, so plain builds don't need this.
icons:
	python3 scripts/generate-icon-svgs.py Assets
	swift scripts/render-icons.swift Assets Resources

install: app
	-pkill -x $(APP)
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/$(APP).app
	mkdir -p $(HOME)/.local/bin
	ln -sf /Applications/$(APP).app/Contents/Helpers/lodestone $(HOME)/.local/bin/lodestone
	/System/Library/CoreServices/pbs -update
	open /Applications/$(APP).app

test:
	swift test

clean:
	rm -rf .build build

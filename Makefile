APP := Lodestone
BUNDLE := build/$(APP).app
# Ad-hoc by default. Pass SIGN_ID="Your Identity" to sign with a real certificate, which keeps the
# Accessibility grant across rebuilds (an ad-hoc signature changes with every build).
SIGN_ID ?= -

.PHONY: all app icons install test clean

all: app

app:
	swift build -c release --product $(APP)
	swift build -c release --product lodestone-cli
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources $(BUNDLE)/Contents/Helpers
	cp "$$(swift build -c release --show-bin-path)/$(APP)" $(BUNDLE)/Contents/MacOS/$(APP)
	cp "$$(swift build -c release --show-bin-path)/lodestone-cli" $(BUNDLE)/Contents/Helpers/lodestone
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png $(BUNDLE)/Contents/Resources/
	codesign --force --sign "$(SIGN_ID)" --identifier app.lodestone.cli $(BUNDLE)/Contents/Helpers/lodestone
	codesign --force --sign "$(SIGN_ID)" $(BUNDLE)

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

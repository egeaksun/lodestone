APP := Lodestone
BUNDLE := build/$(APP).app
# Ad-hoc by default. Pass SIGN_ID="Your Identity" to sign with a real certificate, which keeps the
# Accessibility grant across rebuilds (an ad-hoc signature changes with every build).
SIGN_ID ?= -

.PHONY: all app install test clean

all: app

app:
	swift build -c release --product $(APP)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp "$$(swift build -c release --show-bin-path)/$(APP)" $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign "$(SIGN_ID)" $(BUNDLE)

install: app
	-pkill -x $(APP)
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/$(APP).app
	open /Applications/$(APP).app

test:
	swift test

clean:
	rm -rf .build build

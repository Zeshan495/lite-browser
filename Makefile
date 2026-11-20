APP      := LiteBrowser.app
BUILD    := build
ARCH     := $(shell uname -m)
TARGET   := $(ARCH)-apple-macos12.0
PREFIX   ?= /Applications
VERSION  ?=

.PHONY: all build run install clean android

all: build

build: $(BUILD)/$(APP)

$(BUILD)/$(APP): Sources/*.swift Info.plist Resources/AppIcon.icns Resources/AppIcon.png Resources/settings.html Resources/home.html
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Resources
	swiftc -O -target $(TARGET) Sources/*.swift \
		-framework Cocoa -framework WebKit -framework Network \
		-o $@/Contents/MacOS/LiteBrowser
	cp Info.plist $@/Contents/Info.plist
	cp Resources/AppIcon.icns Resources/AppIcon.png Resources/settings.html Resources/home.html $@/Contents/Resources/
	if [ -n "$(VERSION)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $@/Contents/Info.plist; fi
	codesign --force --deep --sign - $@

run: build
	open $(BUILD)/$(APP)

install: build
	rm -rf "$(PREFIX)/$(APP)"
	cp -R $(BUILD)/$(APP) "$(PREFIX)/"

clean:
	rm -rf $(BUILD) dist

android:
	gradle -p android assembleRelease

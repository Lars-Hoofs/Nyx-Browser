DERIVED := .build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Nyx.app

.PHONY: gen build run test-core test-ui clean

gen:
	xcodegen generate

build: gen
	xcodebuild -project Nyx.xcodeproj -scheme Nyx -configuration Debug \
		-derivedDataPath $(DERIVED) build

run: build
	open $(APP)

test-core:
	swift test --package-path NyxCore

test-ui: gen
	xcodebuild -project Nyx.xcodeproj -scheme Nyx -configuration Debug \
		-derivedDataPath $(DERIVED) test

clean:
	rm -rf .build Nyx.xcodeproj

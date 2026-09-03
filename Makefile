.PHONY: build test app install

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

install:
	./scripts/install.sh

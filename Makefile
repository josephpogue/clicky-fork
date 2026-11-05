test:
	swift test --package-path Packages/ClickyCore

build:
	bash scripts/build-app.sh

.PHONY: test build

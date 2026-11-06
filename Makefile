# The speech tests assert wall-clock deadlines (a 0.3 s timer must fire inside 2 s). ClickyCoreTests has hundreds of
# tests that block pool threads on child processes and pipes, so in one process the timer's continuation waits behind
# them for 2 to 4 s. Two runs, speech second and alone, keep the deadlines honest without loosening them. Both always
# run; the target fails when either does.
test:
	@status=0; \
	swift test --package-path Packages/ClickyCore --skip ClickySpeechTests || status=1; \
	swift test --package-path Packages/ClickyCore --filter ClickySpeechTests || status=1; \
	exit $$status

build:
	bash scripts/build-app.sh

.PHONY: test build

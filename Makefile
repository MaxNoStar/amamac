SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

DERIVED := $(HOME)/Library/Developer/Xcode/DerivedData/Amamac-cli
CONFIG ?= Debug
XCB := xcodebuild -project Amamac.xcodeproj -scheme Amamac -configuration $(CONFIG) \
	-derivedDataPath $(DERIVED) -skipPackagePluginValidation -skipMacroValidation -packageAuthorizationProvider netrc
APP := $(DERIVED)/Build/Products/$(CONFIG)/Amamac.app
RESOLVED_SRC := Package.resolved
RESOLVED_DST := Amamac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
SNAPSHOT_DIR ?= $(TMPDIR)amamac-snapshot

.PHONY: project resolve build test test-engine run app snapshot clean

project:
	@xcodegen generate --quiet
	@if [ -f $(RESOLVED_SRC) ]; then mkdir -p $$(dirname $(RESOLVED_DST)) && cp $(RESOLVED_SRC) $(RESOLVED_DST); fi

resolve: project
	@$(XCB) -resolvePackageDependencies > build-resolve.log 2>&1 || (tail -30 build-resolve.log; exit 1)
	@rm -f build-resolve.log
	@cp $(RESOLVED_DST) $(RESOLVED_SRC)

build: project
	@mkdir -p build
	@$(XCB) build > build/last-build.log 2>&1 \
		|| (grep -E "error:|Undefined symbol|ld:" build/last-build.log | grep -v iOSSimulator | sort -u | head -60; exit 1)
	@grep -E "\.swift:[0-9]+:[0-9]+: warning:" build/last-build.log | grep -v "/SourcePackages/" | sort -u | head -20 || true
	@echo "Built $(APP)"

test: project
	@mkdir -p build
	@$(XCB) test -skip-testing:AmamacCoreTests/EngineTests > build/last-test.log 2>&1 \
		|| (grep -E "error:|failed|Fail|issue|✘" build/last-test.log | sort -u | head -80; exit 1)
	@grep -E "Test run with|passed after|Executed" build/last-test.log | tail -3

test-engine: project
	@mkdir -p build
	@$(XCB) test -only-testing:AmamacCoreTests/EngineTests > build/last-test-engine.log 2>&1 \
		|| (grep -E "error:|failed|Fail|issue|✘" build/last-test-engine.log | sort -u | head -60; exit 1)
	@grep -E "Test run with|passed after|Executed" build/last-test-engine.log | tail -3

run: build
	@open -n "$(APP)"

app: build
	@rm -rf build/Amamac.app && cp -R "$(APP)" build/Amamac.app && echo "build/Amamac.app"

snapshot: build
	@rm -rf "$(SNAPSHOT_DIR)" && mkdir -p "$(SNAPSHOT_DIR)"
	@"$(APP)/Contents/MacOS/Amamac" --snapshot "$(SNAPSHOT_DIR)" --data-dir "$(SNAPSHOT_DIR)/data" --dump-layout "$(SNAPSHOT_DIR)/layout.json"
	@ls "$(SNAPSHOT_DIR)"

clean:
	@rm -rf build "$(DERIVED)"

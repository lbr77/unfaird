SHELL := /bin/bash

THEOS ?= $(HOME)/theos
THEOS_PACKAGE_SCHEME ?= rootless
THEOS_PACKAGE_DIR_NAME ?= debs
TARGET := iphone:clang:latest:17.0
ARCHS := arm64

PACKAGE_NAME := wiki.qaq.unfaird
EXECUTABLE_NAME := UnfairDaemon
BUILD_INFO := Sources/UnfairDaemon/BuildInfo.swift
IOS_TARGET := arm64-apple-ios17.0
IOS_BUILD_DIR := .build/ios-release
IOS_SCRATCH_DIR := .build-ios
IPHONEOS_SDK_PATH := $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
LDID ?= $(shell command -v ldid 2>/dev/null)
ifeq ($(LDID),)
LDID := $(THEOS)/bin/ldid
endif
SWIFT_STDLIB_TOOL ?= $(shell xcrun --find swift-stdlib-tool 2>/dev/null)

IOS_SWIFT_FLAGS := \
	--build-system native \
	--triple $(IOS_TARGET) \
	-Xswiftc -sdk -Xswiftc "$(IPHONEOS_SDK_PATH)" \
	-Xcc -arch -Xcc arm64 \
	-Xcc --target=$(IOS_TARGET) \
	-Xcc -isysroot -Xcc "$(IPHONEOS_SDK_PATH)" \
	-Xcc -mios-version-min=17.0 \
	-Xcc -miphoneos-version-min=17.0

.PHONY: all build release ios-release mac-install mac-uninstall generate-build-info clean-package

all:: ios-release

build:
	@set -euo pipefail; \
	original="$$(mktemp)"; \
	cp "$(BUILD_INFO)" "$$original"; \
	restore() { cp "$$original" "$(BUILD_INFO)"; rm -f "$$original"; }; \
	trap restore EXIT; \
	$(MAKE) generate-build-info; \
	swift build

release:
	@set -euo pipefail; \
	original="$$(mktemp)"; \
	cp "$(BUILD_INFO)" "$$original"; \
	restore() { cp "$$original" "$(BUILD_INFO)"; rm -f "$$original"; }; \
	trap restore EXIT; \
	$(MAKE) generate-build-info; \
	swift build -c release

mac-install: release
	bash deploy/install-launchdaemon.sh

mac-uninstall:
	bash deploy/uninstall-launchdaemon.sh

ios-release:
	@set -euo pipefail; \
	if [[ -z "$(IPHONEOS_SDK_PATH)" ]]; then echo "iphoneos SDK missing" >&2; exit 1; fi; \
	if [[ ! -x "$(LDID)" ]]; then echo "ldid missing: $(LDID)" >&2; exit 1; fi; \
	if [[ ! -x "$(SWIFT_STDLIB_TOOL)" ]]; then echo "swift-stdlib-tool missing: $(SWIFT_STDLIB_TOOL)" >&2; exit 1; fi; \
	original="$$(mktemp)"; \
	cp "$(BUILD_INFO)" "$$original"; \
	restore() { cp "$$original" "$(BUILD_INFO)"; rm -f "$$original"; }; \
	trap restore EXIT; \
	$(MAKE) generate-build-info; \
	bin_dir="$$(swift build --scratch-path "$(IOS_SCRATCH_DIR)" -c release --product "$(EXECUTABLE_NAME)" --show-bin-path $(IOS_SWIFT_FLAGS))"; \
	swift build --scratch-path "$(IOS_SCRATCH_DIR)" -c release --product "$(EXECUTABLE_NAME)" $(IOS_SWIFT_FLAGS); \
	rm -rf "$(IOS_BUILD_DIR)"; \
	install -d "$(IOS_BUILD_DIR)"; \
	install -m 0755 "$$bin_dir/$(EXECUTABLE_NAME)" "$(IOS_BUILD_DIR)/$(EXECUTABLE_NAME)"; \
	"$(SWIFT_STDLIB_TOOL)" --copy --scan-executable "$(IOS_BUILD_DIR)/$(EXECUTABLE_NAME)" --destination "$(IOS_BUILD_DIR)" --platform iphoneos; \
	"$(LDID)" -Spackaging/unfaird.entitlements "$(IOS_BUILD_DIR)/$(EXECUTABLE_NAME)"; \
	shopt -s nullglob; \
	for dylib in "$(IOS_BUILD_DIR)"/libswift*.dylib; do "$(LDID)" -S "$$dylib"; done

generate-build-info:
	@commit="$$(git rev-parse --short=12 HEAD 2>/dev/null || awk -F'\"' '/static let commit/ { print $$2; exit }' "$(BUILD_INFO)" 2>/dev/null || echo unknown)"; \
	if [[ -z "$$commit" ]]; then commit="unknown"; fi; \
	timestamp="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	printf 'enum BuildInfo {\n    static let commit = "%s"\n    static let timestamp = "%s"\n}\n' "$$commit" "$$timestamp" > "$(BUILD_INFO)"

clean-package:
	rm -rf "$(IOS_BUILD_DIR)" "$(THEOS_PACKAGE_DIR_NAME)" ".theos"

THEOS_GOALS := package stage install show uninstall before-stage internal-stage after-stage before-package internal-package after-package
ifneq ($(filter $(THEOS_GOALS),$(MAKECMDGOALS)),)
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/rules.mk

after-stage:: ios-release
	@set -euo pipefail; \
	prefix="$(THEOS_PACKAGE_INSTALL_PREFIX)"; \
	if [[ -n "$$prefix" ]]; then \
		dyld_library_path="$$prefix/usr/lib:$$prefix/basebin:/usr/lib:/basebin"; \
		launchd_path="$$prefix/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"; \
	else \
		dyld_library_path="/usr/lib:/basebin"; \
		launchd_path="/usr/bin:/bin:/usr/sbin:/sbin"; \
	fi; \
	install -d "$(THEOS_STAGING_DIR)/usr/local/lib/unfaird"; \
	install -m 0755 "$(IOS_BUILD_DIR)/$(EXECUTABLE_NAME)" "$(THEOS_STAGING_DIR)/usr/local/lib/unfaird/$(EXECUTABLE_NAME)"; \
	shopt -s nullglob; \
	for dylib in "$(IOS_BUILD_DIR)"/libswift*.dylib; do install -m 0755 "$$dylib" "$(THEOS_STAGING_DIR)/usr/local/lib/unfaird/"; done; \
	install -d "$(THEOS_STAGING_DIR)/Library/LaunchDaemons"; \
	sed \
		-e "s|@INSTALL_PREFIX@|$$prefix|g" \
		-e "s|@DYLD_LIBRARY_PATH@|$$dyld_library_path|g" \
		-e "s|@LAUNCHD_PATH@|$$launchd_path|g" \
		packaging/wiki.qaq.unfaird.plist.in > "$(THEOS_STAGING_DIR)/Library/LaunchDaemons/$(PACKAGE_NAME).plist"; \
	chmod 0644 "$(THEOS_STAGING_DIR)/Library/LaunchDaemons/$(PACKAGE_NAME).plist"
endif

APP_NAME := KeyMic
APP_BUNDLE := $(APP_NAME).app
BUILD_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/release)

.PHONY: build build-arm64 build-x86_64 clean install run test release test-annotation-model test-pixelator test-renderer test-selection-handles test-toolbar-positioner test-overlay-state


build:
	swift build -c release
	$(eval BUILD_DIR := $(shell swift build -c release --show-bin-path))
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	install_name_tool -add_rpath "@executable_path/../Frameworks" $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) 2>/dev/null || true
	cp Info.plist $(APP_BUNDLE)/Contents/
	cp Resources/gitleaks.toml $(APP_BUNDLE)/Contents/Resources/
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	cp Resources/TrayIconTemplate.png $(APP_BUNDLE)/Contents/Resources/
	cp Resources/TrayIconTemplate@2x.png $(APP_BUNDLE)/Contents/Resources/
	mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	rm -rf $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	cp -R $(BUILD_DIR)/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	codesign --force --deep --sign "-" $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	codesign --force --sign "-" --identifier io.keymic.app $(APP_BUNDLE)
	@echo "\n✅ Built $(APP_BUNDLE)"

build-arm64:
	swift build -c release --arch arm64
	$(eval ARM64_BUILD := $(shell swift build -c release --arch arm64 --show-bin-path))
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources $(APP_BUNDLE)/Contents/Frameworks
	cp $(ARM64_BUILD)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	install_name_tool -add_rpath "@executable_path/../Frameworks" $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) 2>/dev/null || true
	cp Info.plist $(APP_BUNDLE)/Contents/
	cp Resources/gitleaks.toml $(APP_BUNDLE)/Contents/Resources/
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	cp Resources/TrayIconTemplate.png $(APP_BUNDLE)/Contents/Resources/
	cp Resources/TrayIconTemplate@2x.png $(APP_BUNDLE)/Contents/Resources/
	cp -R $(ARM64_BUILD)/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	codesign --force --deep --sign "-" $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	codesign --force --sign "-" --identifier io.keymic.app $(APP_BUNDLE)
	@echo "\n✅ Built $(APP_BUNDLE) (arm64)"

build-x86_64:
	swift build -c release --arch x86_64
	$(eval X86_BUILD := $(shell swift build -c release --arch x86_64 --show-bin-path))
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources $(APP_BUNDLE)/Contents/Frameworks
	cp $(X86_BUILD)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	install_name_tool -add_rpath "@executable_path/../Frameworks" $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) 2>/dev/null || true
	cp Info.plist $(APP_BUNDLE)/Contents/
	cp Resources/gitleaks.toml $(APP_BUNDLE)/Contents/Resources/
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	cp Resources/TrayIconTemplate.png $(APP_BUNDLE)/Contents/Resources/
	cp Resources/TrayIconTemplate@2x.png $(APP_BUNDLE)/Contents/Resources/
	cp -R $(X86_BUILD)/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	codesign --force --deep --sign "-" $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	codesign --force --sign "-" --identifier io.keymic.app $(APP_BUNDLE)
	@echo "\n✅ Built $(APP_BUNDLE) (x86_64)"

run: build
	open $(APP_BUNDLE)

test:
	mkdir -p .build
	swiftc Sources/KeyMic/Hotkey/HotkeyConfig.swift \
	       Sources/KeyMic/KeyMappingManager.swift \
	       Sources/KeyMic/HIDRemapper.swift \
	       Tests/KeyMappingManagerTests.swift \
	       -o .build/keymapping-tests
	.build/keymapping-tests

test-clipboard-store:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/CleanupMode.swift \
	       Sources/KeyMic/Clipboard/ClipboardPreferences.swift \
	       Sources/KeyMic/Clipboard/ClipboardKind.swift \
	       Sources/KeyMic/Clipboard/ClipboardItem.swift \
	       Sources/KeyMic/Clipboard/MinimalTOMLParser.swift \
	       Sources/KeyMic/Clipboard/GitleaksLoader.swift \
	       Sources/KeyMic/Clipboard/KindClassifier.swift \
	       Sources/KeyMic/Vault/VaultItem.swift \
	       Sources/KeyMic/Clipboard/ClipboardStore.swift \
	       Tests/ClipboardStoreTests.swift \
	       -o .build/clipboard-store-tests
	.build/clipboard-store-tests

test-clipboard-monitor:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/CleanupMode.swift \
	       Sources/KeyMic/Clipboard/ClipboardPreferences.swift \
	       Sources/KeyMic/Clipboard/ClipboardKind.swift \
	       Sources/KeyMic/Clipboard/ClipboardItem.swift \
	       Sources/KeyMic/Clipboard/MinimalTOMLParser.swift \
	       Sources/KeyMic/Clipboard/GitleaksLoader.swift \
	       Sources/KeyMic/Clipboard/KindClassifier.swift \
	       Sources/KeyMic/Vault/VaultItem.swift \
	       Sources/KeyMic/Clipboard/ClipboardStore.swift \
	       Sources/KeyMic/Clipboard/PasteboardReading.swift \
	       Sources/KeyMic/Clipboard/ClipboardMonitor.swift \
	       Tests/ClipboardMonitorTests.swift \
	       -o .build/clipboard-monitor-tests
	.build/clipboard-monitor-tests

test-toml-parser:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/MinimalTOMLParser.swift \
	       Tests/MinimalTOMLParserTests.swift \
	       -o .build/toml-parser-tests
	.build/toml-parser-tests

test-hotkey-config:
	mkdir -p .build
	swiftc Sources/KeyMic/Hotkey/HotkeyConfig.swift \
	       Tests/HotkeyConfigTests.swift \
	       -o .build/hotkey-config-tests
	.build/hotkey-config-tests

test-hotkey-action:
	mkdir -p .build
	swiftc Sources/KeyMic/Hotkey/HotkeyAction.swift \
	       Tests/HotkeyActionTests.swift \
	       -o .build/hotkey-action-tests
	.build/hotkey-action-tests

test-hotkey-bindings-store:
	mkdir -p .build
	swiftc Sources/KeyMic/Hotkey/HotkeyAction.swift \
	       Sources/KeyMic/Hotkey/HotkeyBindingsStore.swift \
	       Tests/HotkeyBindingsStoreTests.swift \
	       -o .build/hotkey-bindings-store-tests
	.build/hotkey-bindings-store-tests

test-kind-classifier:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/MinimalTOMLParser.swift \
	       Sources/KeyMic/Clipboard/GitleaksLoader.swift \
	       Sources/KeyMic/Clipboard/ClipboardKind.swift \
	       Sources/KeyMic/Clipboard/KindClassifier.swift \
	       Tests/KindClassifierTests.swift \
	       -o .build/kind-classifier-tests
	.build/kind-classifier-tests

test-cleanup-policy:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/CleanupMode.swift \
	       Sources/KeyMic/Clipboard/ClipboardPreferences.swift \
	       Sources/KeyMic/Clipboard/ClipboardKind.swift \
	       Sources/KeyMic/Clipboard/ClipboardItem.swift \
	       Sources/KeyMic/Clipboard/MinimalTOMLParser.swift \
	       Sources/KeyMic/Clipboard/GitleaksLoader.swift \
	       Sources/KeyMic/Clipboard/KindClassifier.swift \
	       Sources/KeyMic/Vault/VaultItem.swift \
	       Sources/KeyMic/Clipboard/ClipboardStore.swift \
	       Tests/CleanupPolicyTests.swift \
	       -o .build/cleanup-policy-tests
	.build/cleanup-policy-tests

test-hotkey-action-runner:
	mkdir -p .build
	swiftc Sources/KeyMic/Hotkey/HotkeyAction.swift \
	       Sources/KeyMic/Hotkey/HotkeyActionRunner.swift \
	       Tests/HotkeyActionRunnerTests.swift \
	       -o .build/hotkey-action-runner-tests
	.build/hotkey-action-runner-tests

test-keychain-vault:
	mkdir -p .build
	swiftc Sources/KeyMic/Vault/VaultConfig.swift \
	       Sources/KeyMic/Vault/KeychainBackend.swift \
	       Tests/Support/InMemoryKeychainBackend.swift \
	       Tests/KeychainVaultTests.swift \
	       -o .build/keychain-vault-tests
	.build/keychain-vault-tests

test-secret-scanner:
	mkdir -p .build
	swiftc Sources/KeyMic/Vault/VaultConfig.swift \
	       Sources/KeyMic/Clipboard/MinimalTOMLParser.swift \
	       Sources/KeyMic/Clipboard/GitleaksLoader.swift \
	       Sources/KeyMic/Vault/SecretScanner.swift \
	       Tests/SecretScannerTests.swift \
	       -o .build/secret-scanner-tests
	.build/secret-scanner-tests

test-vault-store:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/CleanupMode.swift \
	       Sources/KeyMic/Clipboard/ClipboardPreferences.swift \
	       Sources/KeyMic/Clipboard/ClipboardKind.swift \
	       Sources/KeyMic/Clipboard/ClipboardItem.swift \
	       Sources/KeyMic/Clipboard/MinimalTOMLParser.swift \
	       Sources/KeyMic/Clipboard/GitleaksLoader.swift \
	       Sources/KeyMic/Clipboard/KindClassifier.swift \
	       Sources/KeyMic/Vault/VaultConfig.swift \
	       Sources/KeyMic/Vault/VaultItem.swift \
	       Sources/KeyMic/Vault/VaultMask.swift \
	       Sources/KeyMic/Vault/KeychainBackend.swift \
	       Sources/KeyMic/Vault/SecretScanner.swift \
	       Sources/KeyMic/Vault/VaultStore.swift \
	       Tests/Support/InMemoryKeychainBackend.swift \
	       Tests/VaultStoreTests.swift \
	       -o .build/vault-store-tests
	.build/vault-store-tests

test-keymonitor-clipboard-panel:
	mkdir -p .build
	swiftc Sources/KeyMic/KeyMappingManager.swift \
	       Sources/KeyMic/HIDRemapper.swift \
	       Sources/KeyMic/Hotkey/HotkeyAction.swift \
	       Sources/KeyMic/Hotkey/HotkeyConfig.swift \
	       Sources/KeyMic/Hotkey/HotkeyPreferences.swift \
	       Sources/KeyMic/Hotkey/HotkeyBindingsStore.swift \
	       Sources/KeyMic/KeyMonitor.swift \
	       Tests/KeyMonitorClipboardPanelTests.swift \
	       -o .build/keymonitor-clipboard-panel-tests
	.build/keymonitor-clipboard-panel-tests

test-single-instance:
	mkdir -p .build
	swiftc Sources/KeyMic/SingleInstance.swift \
	       Tests/SingleInstanceTests.swift \
	       -o .build/single-instance-tests
	.build/single-instance-tests

test-annotation-model:
	mkdir -p .build
	swiftc Sources/KeyMic/Screenshot/AnnotationModel.swift \
	       Tests/AnnotationModelTests.swift \
	       -o .build/annotation-model-tests
	.build/annotation-model-tests

test-pixelator:
	mkdir -p .build
	swiftc Sources/KeyMic/Screenshot/AnnotationModel.swift \
	       Sources/KeyMic/Screenshot/Pixelator.swift \
	       Tests/PixelatorTests.swift \
	       -o .build/pixelator-tests
	.build/pixelator-tests

test-renderer:
	mkdir -p .build
	swiftc Sources/KeyMic/Screenshot/AnnotationModel.swift \
	       Sources/KeyMic/Screenshot/Pixelator.swift \
	       Sources/KeyMic/Screenshot/AnnotationRenderer.swift \
	       Tests/RendererTests.swift \
	       -o .build/renderer-tests
	.build/renderer-tests

test-selection-handles:
	mkdir -p .build
	swiftc Sources/KeyMic/Screenshot/SelectionHandle.swift \
	       Tests/SelectionHandleTests.swift \
	       -o .build/selection-handles-tests
	.build/selection-handles-tests

test-toolbar-positioner:
	mkdir -p .build
	swiftc Sources/KeyMic/Screenshot/ToolbarPositioner.swift \
	       Tests/ToolbarPositionerTests.swift \
	       -o .build/toolbar-positioner-tests
	.build/toolbar-positioner-tests

test-overlay-state:
	mkdir -p .build
	swiftc Sources/KeyMic/Screenshot/AnnotationModel.swift \
	       Sources/KeyMic/Screenshot/SelectionHandle.swift \
	       Sources/KeyMic/Screenshot/OverlayState.swift \
	       Tests/OverlayStateTests.swift \
	       -o .build/overlay-state-tests
	.build/overlay-state-tests

test-all: test test-clipboard-store test-clipboard-monitor test-cleanup-policy test-hotkey-config test-hotkey-action test-hotkey-bindings-store test-toml-parser test-kind-classifier test-hotkey-action-runner test-keymonitor-clipboard-panel test-single-instance test-keychain-vault test-secret-scanner test-vault-store test-annotation-model test-pixelator test-renderer test-selection-handles test-toolbar-positioner test-overlay-state
	@echo "\n✅ All tests passed"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

install: build
	rm -rf /Applications/$(APP_BUNDLE)
	cp -r $(APP_BUNDLE) /Applications/
	@echo "✅ Installed to /Applications/$(APP_BUNDLE)"

release:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make release VERSION=1.1.0"; exit 1; fi
	./scripts/release.sh $(VERSION)

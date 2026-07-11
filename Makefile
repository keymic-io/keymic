APP_NAME := KeyMic
APP_BUNDLE := $(APP_NAME).app
ENTITLEMENTS := $(APP_NAME).entitlements
# SpeechAnalyzer (LOR-28) needs the macOS 26 SDK. Detect SDK major version and,
# when >= 26, pass -DKEYMIC_HAS_SPEECH_ANALYZER so the guarded Speech code compiles.
# Older SDKs build fine without it (the #if excludes the new-API files).
SDK_MAJOR := $(shell xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1)
SPEECH_ANALYZER_FLAGS :=
ifeq ($(shell [ "$(SDK_MAJOR)" -ge 26 ] 2>/dev/null && echo yes),yes)
SPEECH_ANALYZER_FLAGS := -Xswiftc -DKEYMIC_HAS_SPEECH_ANALYZER
endif
BUILD_DIR := $(shell swift build -c release $(SPEECH_ANALYZER_FLAGS) --show-bin-path 2>/dev/null || echo .build/release)
CODESIGN_IDENTITY ?= -

.PHONY: build build-arm64 build-x86_64 clean install install-hooks uninstall-hooks run test release format lint test-annotation-model test-pixelator test-renderer test-selection-handles test-toolbar-positioner test-overlay-state test-persona test-persona-store test-persona-mru test-hotkey-registry test-hotkey-settings-store test-pasteboard-snapshot test-selection-copy-wait test-voice-model-catalog test-asset-store test-keychain-store test-me-api test-exchange-api test-auth-client test-account test-sync-section test-sync-engine test-voice-picker test-keymonitor-persona-cycle test-persona-engine smoke-onnx


build:
	swift build -c release $(SPEECH_ANALYZER_FLAGS)
	$(eval BUILD_DIR := $(shell swift build -c release $(SPEECH_ANALYZER_FLAGS) --show-bin-path))
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	install_name_tool -add_rpath "@executable_path/../Frameworks" $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) 2>/dev/null || true
	cp Info.plist $(APP_BUNDLE)/Contents/
	cp Resources/gitleaks.toml $(APP_BUNDLE)/Contents/Resources/
	cp Resources/sensevoice/am.mvn $(APP_BUNDLE)/Contents/Resources/
	cp Resources/sensevoice/chn_jpn_yue_eng_ko_spectok.bpe.model $(APP_BUNDLE)/Contents/Resources/
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	cp Resources/TrayIconTemplate.png $(APP_BUNDLE)/Contents/Resources/
	cp Resources/TrayIconTemplate@2x.png $(APP_BUNDLE)/Contents/Resources/
	xcrun --sdk macosx xcstringstool compile Sources/KeyMic/Resources/Localizable.xcstrings -o $(APP_BUNDLE)/Contents/Resources/
	xcrun --sdk macosx xcstringstool compile Sources/KeyMic/Resources/InfoPlist.xcstrings -o $(APP_BUNDLE)/Contents/Resources/
	mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	rm -rf $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	cp -R $(BUILD_DIR)/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	codesign --force --sign "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) --identifier io.keymic.app $(APP_BUNDLE)
	@echo "\n✅ Built $(APP_BUNDLE)"

build-arm64:
	swift build -c release $(SPEECH_ANALYZER_FLAGS) --arch arm64
	$(eval ARM64_BUILD := $(shell swift build -c release $(SPEECH_ANALYZER_FLAGS) --arch arm64 --show-bin-path))
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources $(APP_BUNDLE)/Contents/Frameworks
	cp $(ARM64_BUILD)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	install_name_tool -add_rpath "@executable_path/../Frameworks" $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) 2>/dev/null || true
	cp Info.plist $(APP_BUNDLE)/Contents/
	cp Resources/gitleaks.toml $(APP_BUNDLE)/Contents/Resources/
	cp Resources/sensevoice/am.mvn $(APP_BUNDLE)/Contents/Resources/
	cp Resources/sensevoice/chn_jpn_yue_eng_ko_spectok.bpe.model $(APP_BUNDLE)/Contents/Resources/
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	cp Resources/TrayIconTemplate.png $(APP_BUNDLE)/Contents/Resources/
	cp Resources/TrayIconTemplate@2x.png $(APP_BUNDLE)/Contents/Resources/
	xcrun --sdk macosx xcstringstool compile Sources/KeyMic/Resources/Localizable.xcstrings -o $(APP_BUNDLE)/Contents/Resources/
	xcrun --sdk macosx xcstringstool compile Sources/KeyMic/Resources/InfoPlist.xcstrings -o $(APP_BUNDLE)/Contents/Resources/
	cp -R $(ARM64_BUILD)/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	codesign --force --sign "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) --identifier io.keymic.app $(APP_BUNDLE)
	@echo "\n✅ Built $(APP_BUNDLE) (arm64)"

build-x86_64:
	swift build -c release $(SPEECH_ANALYZER_FLAGS) --arch x86_64
	$(eval X86_BUILD := $(shell swift build -c release $(SPEECH_ANALYZER_FLAGS) --arch x86_64 --show-bin-path))
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources $(APP_BUNDLE)/Contents/Frameworks
	cp $(X86_BUILD)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	install_name_tool -add_rpath "@executable_path/../Frameworks" $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) 2>/dev/null || true
	cp Info.plist $(APP_BUNDLE)/Contents/
	cp Resources/gitleaks.toml $(APP_BUNDLE)/Contents/Resources/
	cp Resources/sensevoice/am.mvn $(APP_BUNDLE)/Contents/Resources/
	cp Resources/sensevoice/chn_jpn_yue_eng_ko_spectok.bpe.model $(APP_BUNDLE)/Contents/Resources/
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	cp Resources/TrayIconTemplate.png $(APP_BUNDLE)/Contents/Resources/
	cp Resources/TrayIconTemplate@2x.png $(APP_BUNDLE)/Contents/Resources/
	xcrun --sdk macosx xcstringstool compile Sources/KeyMic/Resources/Localizable.xcstrings -o $(APP_BUNDLE)/Contents/Resources/
	xcrun --sdk macosx xcstringstool compile Sources/KeyMic/Resources/InfoPlist.xcstrings -o $(APP_BUNDLE)/Contents/Resources/
	cp -R $(X86_BUILD)/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	codesign --force --sign "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) --identifier io.keymic.app $(APP_BUNDLE)
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
	       Sources/KeyMic/Clipboard/ImageFormat.swift \
	       Sources/KeyMic/Clipboard/RichTextFormat.swift \
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
	       Sources/KeyMic/Clipboard/ImageFormat.swift \
	       Sources/KeyMic/Clipboard/RichTextFormat.swift \
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

test-clipboard-store-binary:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/ClipboardItem.swift \
	       Sources/KeyMic/Clipboard/ClipboardKind.swift \
	       Sources/KeyMic/Clipboard/ImageFormat.swift \
	       Sources/KeyMic/Clipboard/RichTextFormat.swift \
	       Sources/KeyMic/Clipboard/ClipboardStore.swift \
	       Sources/KeyMic/Clipboard/CleanupMode.swift \
	       Sources/KeyMic/Clipboard/ClipboardPreferences.swift \
	       Sources/KeyMic/Clipboard/KindClassifier.swift \
	       Sources/KeyMic/Clipboard/MinimalTOMLParser.swift \
	       Sources/KeyMic/Clipboard/GitleaksLoader.swift \
	       Sources/KeyMic/Vault/VaultItem.swift \
	       Tests/ClipboardStoreBinaryTests.swift \
	       -o .build/clipboard-store-binary-tests
	.build/clipboard-store-binary-tests

test-clipboard-monitor-types:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/ClipboardItem.swift \
	       Sources/KeyMic/Clipboard/ClipboardKind.swift \
	       Sources/KeyMic/Clipboard/ImageFormat.swift \
	       Sources/KeyMic/Clipboard/RichTextFormat.swift \
	       Sources/KeyMic/Clipboard/ClipboardStore.swift \
	       Sources/KeyMic/Clipboard/ClipboardMonitor.swift \
	       Sources/KeyMic/Clipboard/CleanupMode.swift \
	       Sources/KeyMic/Clipboard/ClipboardPreferences.swift \
	       Sources/KeyMic/Clipboard/KindClassifier.swift \
	       Sources/KeyMic/Clipboard/PasteboardReading.swift \
	       Sources/KeyMic/Clipboard/MinimalTOMLParser.swift \
	       Sources/KeyMic/Clipboard/GitleaksLoader.swift \
	       Sources/KeyMic/Vault/VaultItem.swift \
	       Tests/ClipboardMonitorTypesTests.swift \
	       -o .build/clipboard-monitor-types-tests
	.build/clipboard-monitor-types-tests

test-thumbnail-cache:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/ThumbnailLoader.swift \
	       Tests/ThumbnailCacheTests.swift \
	       -o .build/thumbnail-cache-tests
	.build/thumbnail-cache-tests

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

test-hotkey-settings-store:
	mkdir -p .build
	swiftc Sources/KeyMic/Hotkey/HotkeyConfig.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaStore.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellOutputRunner.swift \
	       Sources/KeyMic/Output/iTerm/ITermAvailability.swift \
	       Sources/KeyMic/Output/iTerm/ITermBridge.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Sources/KeyMic/Hotkey/HotkeySettingsStore.swift \
	       Tests/HotkeySettingsStoreTests.swift \
	       -o .build/hotkey-settings-store-tests
	.build/hotkey-settings-store-tests

test-sync-section:
	mkdir -p .build
	swiftc Sources/KeyMic/Sync/JSONValue.swift \
	       Sources/KeyMic/Sync/SyncSection.swift \
	       Tests/SyncSectionTests.swift \
	       -o .build/sync-section-tests
	.build/sync-section-tests

test-sync-engine:
	mkdir -p .build
	swiftc Sources/KeyMic/Sync/JSONValue.swift \
	       Sources/KeyMic/Sync/SyncSection.swift \
	       Sources/KeyMic/Sync/SyncState.swift \
	       Sources/KeyMic/Account/BackendConfig.swift \
	       Sources/KeyMic/Sync/ConfigSyncAPI.swift \
	       Sources/KeyMic/Sync/SyncEngine.swift \
	       Sources/KeyMic/Sync/ConfigSyncBootstrap.swift \
	       Tests/SyncEngineTests.swift \
	       -o .build/sync-engine-tests
	.build/sync-engine-tests

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
	       Sources/KeyMic/Clipboard/ImageFormat.swift \
	       Sources/KeyMic/Clipboard/RichTextFormat.swift \
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
	       Sources/KeyMic/Tools/Shell/ShellLogger.swift \
	       Sources/KeyMic/Tools/Shell/ShellSnapshot.swift \
	       Sources/KeyMic/Tools/Shell/ShellRunner.swift \
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
	       Sources/KeyMic/Clipboard/ImageFormat.swift \
	       Sources/KeyMic/Clipboard/RichTextFormat.swift \
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
	       Sources/KeyMic/Hotkey/HotkeyRecorder.swift \
	       Sources/KeyMic/Hotkey/HotkeyBindingsStore.swift \
	       Sources/KeyMic/Hotkey/HotkeySettingsStore.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaStore.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellOutputRunner.swift \
	       Sources/KeyMic/Output/iTerm/ITermAvailability.swift \
	       Sources/KeyMic/Output/iTerm/ITermBridge.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Sources/KeyMic/Input/InputState.swift \
	       Sources/KeyMic/Input/InputResetReason.swift \
	       Sources/KeyMic/Clipboard/ClipboardSwitcherState.swift \
	       Sources/KeyMic/KeyMonitor.swift \
	       Tests/KeyMonitorClipboardPanelTests.swift \
	       -o .build/keymonitor-clipboard-panel-tests
	.build/keymonitor-clipboard-panel-tests

test-keymonitor-persona-cycle:
	mkdir -p .build
	swiftc Sources/KeyMic/KeyMappingManager.swift \
	       Sources/KeyMic/HIDRemapper.swift \
	       Sources/KeyMic/Hotkey/HotkeyAction.swift \
	       Sources/KeyMic/Hotkey/HotkeyConfig.swift \
	       Sources/KeyMic/Hotkey/HotkeyPreferences.swift \
	       Sources/KeyMic/Hotkey/HotkeyRecorder.swift \
	       Sources/KeyMic/Hotkey/HotkeyBindingsStore.swift \
	       Sources/KeyMic/Hotkey/HotkeySettingsStore.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaStore.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellOutputRunner.swift \
	       Sources/KeyMic/Output/iTerm/ITermAvailability.swift \
	       Sources/KeyMic/Output/iTerm/ITermBridge.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Sources/KeyMic/Input/InputState.swift \
	       Sources/KeyMic/Input/InputResetReason.swift \
	       Sources/KeyMic/Clipboard/ClipboardSwitcherState.swift \
	       Sources/KeyMic/KeyMonitor.swift \
	       Tests/KeyMonitorPersonaCycleTests.swift \
	       -o .build/keymonitor-persona-cycle-tests
	.build/keymonitor-persona-cycle-tests

test-clipboard-history-keyboard:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/ClipboardHistoryKeyHandling.swift \
	       Tests/ClipboardHistoryKeyHandlingTests.swift \
	       -o .build/clipboard-history-keyboard-tests
	.build/clipboard-history-keyboard-tests

test-app-tips:
	mkdir -p .build
	swiftc Sources/KeyMic/Tips/AppTips.swift \
	       Tests/AppTipsTests.swift \
	       -o .build/app-tips-tests
	.build/app-tips-tests

test-clipboard-switcher:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/ClipboardSwitcherState.swift \
	       Tests/ClipboardSwitcherStateTests.swift \
	       -o .build/clipboard-switcher-tests
	.build/clipboard-switcher-tests

test-clipboard-selection-bridge:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/ClipboardPanelSelectionBridge.swift \
	       Tests/ClipboardPanelSelectionBridgeTests.swift \
	       -o .build/clipboard-selection-bridge-tests
	.build/clipboard-selection-bridge-tests

test-single-instance:
	mkdir -p .build
	swiftc Sources/KeyMic/SingleInstance.swift \
	       Tests/SingleInstanceTests.swift \
	       -o .build/single-instance-tests
	.build/single-instance-tests

test-speech-engine:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/VoiceError.swift \
	       Sources/KeyMic/Speech/VoiceState.swift \
	       Sources/KeyMic/Speech/SenseVoice/SpeechEngineProtocol.swift \
	       Sources/KeyMic/SpeechEngine.swift \
	       Tests/SpeechEngineTests.swift \
	       -o .build/speech-engine-tests
	.build/speech-engine-tests

test-voice-session:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/VoiceState.swift \
	       Tests/VoiceSessionTests.swift \
	       -o .build/voice-session-tests
	.build/voice-session-tests

test-speech-protocol:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/VoiceState.swift \
	       Sources/KeyMic/Speech/SenseVoice/SpeechEngineProtocol.swift \
	       Sources/KeyMic/PersonaPlatform/Triggers/SpeechSessionHost.swift \
	       Tests/SpeechEngineProtocolTests.swift \
	       -o .build/speech-protocol-tests
	.build/speech-protocol-tests

test-speech-factory:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/SenseVoice/SpeechEngineFactory.swift \
	       Tests/SpeechEngineFactoryTests.swift \
	       -o .build/speech-factory-tests
	.build/speech-factory-tests

test-speech-status:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/SpeechAnalyzer/SpeechEngineStatus.swift \
	       Tests/SpeechEngineStatusTests.swift \
	       -o .build/speech-status-tests
	.build/speech-status-tests

test-audio-capture-16k:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/SenseVoice/SenseVoiceConfig.swift \
	       Sources/KeyMic/Speech/SenseVoice/AudioCapture16k.swift \
	       Tests/AudioCapture16kTests.swift \
	       -o .build/audio-capture-16k-tests
	.build/audio-capture-16k-tests

test-sensevoice-vocab:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/SenseVoice/ProtobufReader.swift \
	       Sources/KeyMic/Speech/SenseVoice/SenseVoiceVocab.swift \
	       Tests/SenseVoiceVocabTests.swift \
	       -o .build/sensevoice-vocab-tests
	.build/sensevoice-vocab-tests

test-fbank-extractor:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/SenseVoice/SenseVoiceConfig.swift \
	       Sources/KeyMic/Speech/SenseVoice/FbankExtractor.swift \
	       Tests/Support/sensevoice/GoldenLoader.swift \
	       Tests/FbankExtractorTests.swift \
	       -framework Accelerate -framework AVFoundation \
	       -o .build/fbank-extractor-tests
	.build/fbank-extractor-tests

test-sensevoice-model-store:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/SenseVoice/SenseVoiceConfig.swift \
	       Sources/KeyMic/Speech/SenseVoice/SenseVoiceModelStore.swift \
	       Tests/SenseVoiceModelStoreTests.swift \
	       -framework CoreML \
	       -o .build/sensevoice-model-store-tests
	.build/sensevoice-model-store-tests

test-ctc-decoder:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/SenseVoice/SenseVoiceConfig.swift \
	       Sources/KeyMic/Speech/SenseVoice/ProtobufReader.swift \
	       Sources/KeyMic/Speech/SenseVoice/SenseVoiceVocab.swift \
	       Sources/KeyMic/Speech/SenseVoice/CTCDecoder.swift \
	       Tests/CTCDecoderTests.swift \
	       -o .build/ctc-decoder-tests
	.build/ctc-decoder-tests

test-sensevoice-model-input:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/SenseVoice/SenseVoiceConfig.swift \
	       Sources/KeyMic/Speech/VoiceError.swift \
	       Sources/KeyMic/Speech/SenseVoice/SenseVoiceModel.swift \
	       Tests/SenseVoiceModelInputTests.swift \
	       -framework CoreML -framework AVFoundation \
	       -o .build/sensevoice-model-input-tests
	.build/sensevoice-model-input-tests

# Model-gated: proves the int8 export graph's zero-pad attention mask isolates pad frames at
# EVERY EnumeratedShapes bucket (collapsed-CTC is bit-stable across 128…1800 for one real
# input). SKIPS gracefully when the 226 MB model is not installed (CI / macOS <15).
test-sensevoice-padding-parity:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/SenseVoice/SenseVoiceConfig.swift \
	       Sources/KeyMic/Speech/SenseVoice/SenseVoiceModelStore.swift \
	       Sources/KeyMic/Speech/SenseVoice/ProtobufReader.swift \
	       Sources/KeyMic/Speech/SenseVoice/SenseVoiceVocab.swift \
	       Sources/KeyMic/Speech/SenseVoice/CTCDecoder.swift \
	       Tests/Support/sensevoice/GoldenLoader.swift \
	       Tests/SenseVoicePaddingParityTests.swift \
	       -framework CoreML -framework AVFoundation \
	       -o .build/sensevoice-padding-parity-tests
	.build/sensevoice-padding-parity-tests

test-voice-state-machine:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/VoiceError.swift \
	       Sources/KeyMic/Speech/VoiceState.swift \
	       Sources/KeyMic/Speech/VoiceStateMachine.swift \
	       Tests/VoiceStateMachineTests.swift \
	       -o .build/voice-state-machine-tests
	.build/voice-state-machine-tests

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

test-keychain-store:
	swiftc -parse-as-library \
	  Sources/KeyMic/Account/KeychainStore.swift \
	  Tests/test_keychain_store.swift \
	  -o /tmp/keymic-test-keychain-store
	/tmp/keymic-test-keychain-store

test-me-api:
	swiftc -parse-as-library \
	  Sources/KeyMic/Account/BackendConfig.swift \
	  Sources/KeyMic/Account/MeAPI.swift \
	  Tests/test_me_api.swift \
	  -o /tmp/keymic-test-me-api
	/tmp/keymic-test-me-api

test-exchange-api:
	swiftc -parse-as-library \
	  Sources/KeyMic/Account/BackendConfig.swift \
	  Sources/KeyMic/Account/MeAPI.swift \
	  Sources/KeyMic/Account/ExchangeAPI.swift \
	  Tests/test_exchange_api.swift \
	  -o /tmp/keymic-test-exchange-api
	/tmp/keymic-test-exchange-api

test-auth-client:
	swiftc -parse-as-library \
	  Sources/KeyMic/Account/BackendConfig.swift \
	  Sources/KeyMic/Account/KeychainStore.swift \
	  Sources/KeyMic/Account/MeAPI.swift \
	  Sources/KeyMic/Account/ExchangeAPI.swift \
	  Sources/KeyMic/Account/AccountStore.swift \
	  Sources/KeyMic/Account/AuthClient.swift \
	  Tests/test_auth_client.swift \
	  -o /tmp/keymic-test-auth-client
	/tmp/keymic-test-auth-client

test-account: test-keychain-store test-me-api test-exchange-api test-auth-client
	@echo "✅ All account tests passed"

test-persona:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellOutputRunner.swift \
	       Sources/KeyMic/Output/iTerm/ITermAvailability.swift \
	       Sources/KeyMic/Output/iTerm/ITermBridge.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Tests/PersonaTests.swift \
	       -o .build/persona-tests
	.build/persona-tests

test-persona-store:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaStore.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellOutputRunner.swift \
	       Sources/KeyMic/Output/iTerm/ITermAvailability.swift \
	       Sources/KeyMic/Output/iTerm/ITermBridge.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Tests/PersonaStoreTests.swift \
	       -o .build/persona-store-tests
	.build/persona-store-tests

test-persona-context:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellOutputRunner.swift \
	       Sources/KeyMic/Output/iTerm/ITermAvailability.swift \
	       Sources/KeyMic/Output/iTerm/ITermBridge.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Tests/PersonaContextTests.swift \
	       -o .build/persona-context-tests
	.build/persona-context-tests

test-persona-mru:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaMRU.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellOutputRunner.swift \
	       Sources/KeyMic/Output/iTerm/ITermAvailability.swift \
	       Sources/KeyMic/Output/iTerm/ITermBridge.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Tests/PersonaMRUTests.swift \
	       -o .build/persona-mru-tests
	.build/persona-mru-tests

test-voice-picker:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaMRU.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Sources/KeyMic/PersonaPlatform/Triggers/VoicePickerModel.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellOutputRunner.swift \
	       Sources/KeyMic/Output/iTerm/ITermAvailability.swift \
	       Sources/KeyMic/Output/iTerm/ITermBridge.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Tests/VoicePickerModelTests.swift \
	       -o .build/voice-picker-tests
	.build/voice-picker-tests

test-persona-injection-strategy:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellOutputRunner.swift \
	       Sources/KeyMic/Output/iTerm/ITermAvailability.swift \
	       Sources/KeyMic/Output/iTerm/ITermBridge.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Tests/PersonaInjectionStrategyTests.swift \
	       -o .build/persona-injection-tests
	.build/persona-injection-tests

test-persona-engine:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellOutputRunner.swift \
	       Sources/KeyMic/Output/iTerm/ITermAvailability.swift \
	       Sources/KeyMic/Output/iTerm/ITermBridge.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Tests/PersonaEngineTests.swift \
	       -o .build/persona-engine-tests
	.build/persona-engine-tests

test-output-router:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellOutputRunner.swift \
	       Sources/KeyMic/Output/iTerm/ITermAvailability.swift \
	       Sources/KeyMic/Output/iTerm/ITermBridge.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Tests/OutputRouterTests.swift \
	       -o .build/output-router-tests
	.build/output-router-tests

test-hotkey-registry:
	mkdir -p .build
	swiftc Sources/KeyMic/Hotkey/HotkeyConfig.swift \
	       Sources/KeyMic/Hotkey/HotkeyRegistry.swift \
	       Tests/HotkeyRegistryTests.swift \
	       -o .build/hotkey-registry-tests
	.build/hotkey-registry-tests

test-input-state:
	mkdir -p .build
	swiftc Sources/KeyMic/Input/InputState.swift \
	       Tests/InputStateTests.swift \
	       -o .build/input-state-tests
	.build/input-state-tests

test-secure-input-monitor:
	mkdir -p .build
	swiftc Sources/KeyMic/Input/SecureInputMonitor.swift \
	       Tests/SecureInputMonitorTests.swift \
	       -o .build/secure-input-monitor-tests
	.build/secure-input-monitor-tests

test-shell-logger:
	mkdir -p .build
	swiftc Tests/ShellLoggerTests.swift \
	       Sources/KeyMic/Tools/Shell/ShellLogger.swift \
	       -o .build/shell-logger-tests
	.build/shell-logger-tests

test-shell-snapshot:
	mkdir -p .build
	swiftc Tests/ShellSnapshotTests.swift \
	       Sources/KeyMic/Tools/Shell/ShellSnapshot.swift \
	       Sources/KeyMic/Tools/Shell/ShellLogger.swift \
	       -o .build/shell-snapshot-tests
	.build/shell-snapshot-tests

test-shell-runner:
	mkdir -p .build
	swiftc Tests/ShellRunnerTests.swift \
	       Sources/KeyMic/Tools/Shell/ShellRunner.swift \
	       Sources/KeyMic/Tools/Shell/ShellSnapshot.swift \
	       Sources/KeyMic/Tools/Shell/ShellLogger.swift \
	       -o .build/shell-runner-tests
	.build/shell-runner-tests

test-pasteboard-snapshot:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Tests/PasteboardSnapshotTests.swift \
	       -o .build/pasteboard-snapshot-tests
	.build/pasteboard-snapshot-tests

test-selection-copy-wait:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Tests/SelectionCopyWaitTests.swift \
	       -o .build/selection-copy-wait-tests
	.build/selection-copy-wait-tests

test-context-source:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Tests/ContextSourceTests.swift \
	       -o .build/context-source-tests
	.build/context-source-tests

test-selected-text-editor:
	mkdir -p .build
	swiftc Sources/KeyMic/SelectedTextEditor/EditorAction.swift \
	       Sources/KeyMic/SelectedTextEditor/EditorPrompt.swift \
	       Tests/SelectedTextEditorTests.swift \
	       -o .build/selected-text-editor-tests
	.build/selected-text-editor-tests

test-shell-output:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellOutputRunner.swift \
	       Tests/ShellOutputTests.swift \
	       -framework AppKit \
	       -framework Carbon \
	       -o .build/shell-output-tests
	.build/shell-output-tests

test-window-ocr:
	mkdir -p .build
	swiftc Sources/KeyMic/Context/WindowOCRProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContextBuilder.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Tests/WindowOCRTests.swift \
	       -framework ScreenCaptureKit \
	       -framework AppKit \
	       -framework Vision \
	       -framework Carbon \
	       -o .build/window-ocr-tests
	.build/window-ocr-tests

test-context-resolver:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/PersonaContext.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/ContextSource.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaContextBuilder.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PasteboardSnapshot.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/SelectionCopyWait.swift \
	       Tests/ContextResolverTests.swift \
	       -framework AppKit \
	       -framework Carbon \
	       -o .build/context-resolver-tests
	.build/context-resolver-tests

test-all: test test-clipboard-store test-clipboard-monitor test-cleanup-policy test-hotkey-config test-hotkey-action test-hotkey-bindings-store test-hotkey-settings-store test-toml-parser test-kind-classifier test-hotkey-action-runner test-keymonitor-clipboard-panel test-clipboard-history-keyboard test-app-tips test-clipboard-switcher test-clipboard-selection-bridge test-single-instance test-speech-engine test-keychain-vault test-secret-scanner test-vault-store test-annotation-model test-pixelator test-renderer test-selection-handles test-toolbar-positioner test-overlay-state test-persona test-persona-store test-persona-context test-persona-mru test-persona-injection-strategy test-output-router test-hotkey-registry test-shell-logger test-shell-snapshot test-shell-runner test-clipboard-store-binary test-clipboard-monitor-types test-thumbnail-cache test-input-state test-secure-input-monitor test-voice-session test-speech-protocol test-voice-state-machine test-pasteboard-snapshot test-selection-copy-wait test-selected-text-editor test-context-source test-window-ocr test-shell-output test-audio-capture-16k test-sensevoice-vocab test-fbank-extractor test-sensevoice-model-store test-speech-factory test-speech-status test-ctc-decoder test-sensevoice-model-input test-sensevoice-padding-parity test-voice-model-catalog test-asset-store test-context-resolver test-account test-sync-section test-sync-engine test-voice-picker test-keymonitor-persona-cycle test-persona-engine
	@echo "\n✅ All tests passed"

## Format all Swift sources in-place using swift-format (brew install swift-format)
format:
	@command -v swift-format >/dev/null 2>&1 || { echo "swift-format not found. Install with: brew install swift-format"; exit 1; }
	swift-format format --in-place --recursive Sources Tests

## Check formatting without modifying files (useful in CI)
format-check:
	@command -v swift-format >/dev/null 2>&1 || { echo "swift-format not found. Install with: brew install swift-format"; exit 1; }
	swift-format lint --recursive Sources Tests

## Lint Swift sources using SwiftLint (brew install swiftlint)
lint:
	@command -v swiftlint >/dev/null 2>&1 || { echo "swiftlint not found. Install with: brew install swiftlint"; exit 1; }
	swiftlint lint --strict

## Auto-fix SwiftLint violations where possible
lint-fix:
	@command -v swiftlint >/dev/null 2>&1 || { echo "swiftlint not found. Install with: brew install swiftlint"; exit 1; }
	swiftlint --fix

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

install: build
	rm -rf /Applications/$(APP_BUNDLE)
	cp -r $(APP_BUNDLE) /Applications/
	@echo "✅ Installed to /Applications/$(APP_BUNDLE)"

## Enable the repo's git hooks (swift-format + swiftlint on commit).
install-hooks:
	@chmod +x scripts/git-hooks/pre-commit
	@git config core.hooksPath scripts/git-hooks
	@echo "✅ core.hooksPath -> scripts/git-hooks"

## Disable the repo's git hooks (revert to .git/hooks).
uninstall-hooks:
	@git config --unset core.hooksPath || true
	@echo "✅ core.hooksPath cleared"

release:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make release VERSION=1.1.0 [FORCE=1]"; exit 1; fi
	@if [ "$(FORCE)" = "1" ]; then \
		./scripts/release.sh -f $(VERSION); \
	else \
		./scripts/release.sh $(VERSION); \
	fi

# --- ONNX engine unit tests (standalone swiftc runners) ---
test-voice-model-catalog:
	@mkdir -p .build
	swiftc -parse-as-library -o .build/t-catalog \
	    Tests/VoiceModelCatalogTests.swift \
	    Sources/KeyMic/Speech/ONNX/VoiceModelCatalog.swift
	.build/t-catalog

test-asset-store:
	@mkdir -p .build
	swiftc -parse-as-library -o .build/t-store \
	    Tests/AssetStoreTests.swift \
	    Sources/KeyMic/Speech/ONNX/AssetStore.swift \
	    Sources/KeyMic/Speech/ONNX/VoiceModelCatalog.swift
	.build/t-store

# 手动真机冒烟(需预放/下载 runtime+模型;非 CI)。用真实 AR 模型转写 Tests/fixtures/zh.wav。
smoke-onnx:
	@echo "manual: ensure ~/Library/Application Support/KeyMic/{onnx-runtime,models/funasr-nano-ar} populated"
	swift build
	@echo "(invoke ONNX path via the running app; this target only builds)"

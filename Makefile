APP_NAME := KeyMic
APP_BUNDLE := $(APP_NAME).app
ENTITLEMENTS := $(APP_NAME).entitlements
BUILD_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/release)
CODESIGN_IDENTITY ?= -

.PHONY: build build-arm64 build-x86_64 clean install install-hooks uninstall-hooks run test release format lint test-annotation-model test-pixelator test-renderer test-selection-handles test-toolbar-positioner test-overlay-state test-persona test-persona-store test-hotkey-registry test-hotkey-settings-store test-tool-protocol test-bash-tool test-filesystem-actor test-read-tool test-write-tool test-edit-tool test-multi-edit-tool test-glob-tool test-grep-tool test-mcp-config test-mcp-config-store test-mcp-adapter test-mcp-manager test-skill-frontmatter-parser


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
	xcrun --sdk macosx xcstringstool compile Sources/KeyMic/Resources/Localizable.xcstrings -o $(APP_BUNDLE)/Contents/Resources/
	xcrun --sdk macosx xcstringstool compile Sources/KeyMic/Resources/InfoPlist.xcstrings -o $(APP_BUNDLE)/Contents/Resources/
	mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	rm -rf $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	cp -R $(BUILD_DIR)/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	codesign --force --sign "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) --identifier io.keymic.app $(APP_BUNDLE)
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
	xcrun --sdk macosx xcstringstool compile Sources/KeyMic/Resources/Localizable.xcstrings -o $(APP_BUNDLE)/Contents/Resources/
	xcrun --sdk macosx xcstringstool compile Sources/KeyMic/Resources/InfoPlist.xcstrings -o $(APP_BUNDLE)/Contents/Resources/
	cp -R $(ARM64_BUILD)/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	codesign --force --sign "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) --identifier io.keymic.app $(APP_BUNDLE)
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
	       Sources/KeyMic/LLM/Persona.swift \
	       Sources/KeyMic/LLM/PersonaStore.swift \
	       Sources/KeyMic/Hotkey/HotkeySettingsStore.swift \
	       Tests/HotkeySettingsStoreTests.swift \
	       -o .build/hotkey-settings-store-tests
	.build/hotkey-settings-store-tests

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
	       Sources/KeyMic/Hotkey/HotkeyActionRunner.swift \
	       Sources/KeyMic/Tools/Bash/ShellRunner.swift \
	       Sources/KeyMic/Tools/Bash/ShellSnapshot.swift \
	       Sources/KeyMic/Tools/Bash/ShellLogger.swift \
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
	       Sources/KeyMic/LLM/Persona.swift \
	       Sources/KeyMic/LLM/PersonaStore.swift \
	       Sources/KeyMic/Input/InputState.swift \
	       Sources/KeyMic/Input/InputResetReason.swift \
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

test-speech-engine:
	mkdir -p .build
	swiftc Sources/KeyMic/Speech/VoiceError.swift \
	       Sources/KeyMic/Speech/VoiceState.swift \
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

test-persona:
	mkdir -p .build
	swiftc Sources/KeyMic/LLM/Persona.swift \
	       Tests/PersonaTests.swift \
	       -o .build/persona-tests
	.build/persona-tests

test-persona-store:
	mkdir -p .build
	swiftc Sources/KeyMic/LLM/Persona.swift \
	       Sources/KeyMic/LLM/PersonaStore.swift \
	       Tests/PersonaStoreTests.swift \
	       -o .build/persona-store-tests
	.build/persona-store-tests

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
	       Sources/KeyMic/Tools/Bash/ShellLogger.swift \
	       -o .build/shell-logger-tests
	.build/shell-logger-tests

test-tool-protocol:
	mkdir -p .build
	swiftc Tests/ToolProtocolTests.swift \
	       Sources/KeyMic/Tools/Protocol/Tool.swift \
	       Sources/KeyMic/Tools/Protocol/ToolContext.swift \
	       Sources/KeyMic/Tools/Protocol/ToolRegistry.swift \
	       -o .build/tool-protocol-tests
	.build/tool-protocol-tests

test-bash-tool:
	mkdir -p .build
	swiftc Tests/BashToolTests.swift \
	       Sources/KeyMic/Tools/Bash/BashTool.swift \
	       Sources/KeyMic/Tools/Bash/ShellRunner.swift \
	       Sources/KeyMic/Tools/Bash/ShellSnapshot.swift \
	       Sources/KeyMic/Tools/Bash/ShellLogger.swift \
	       Sources/KeyMic/Tools/Protocol/Tool.swift \
	       Sources/KeyMic/Tools/Protocol/ToolContext.swift \
	       -o .build/bash-tool-tests
	.build/bash-tool-tests

test-filesystem-actor:
	mkdir -p .build
	swiftc Tests/FileSystemActorTests.swift \
	       Sources/KeyMic/Tools/File/FileSystemActor.swift \
	       Sources/KeyMic/Tools/File/FileSystemError.swift \
	       -o .build/filesystem-actor-tests
	.build/filesystem-actor-tests

test-read-tool:
	mkdir -p .build
	swiftc Tests/ReadToolTests.swift \
	       Sources/KeyMic/Tools/File/ReadTool.swift \
	       Sources/KeyMic/Tools/File/FileSystemActor.swift \
	       Sources/KeyMic/Tools/File/FileSystemError.swift \
	       Sources/KeyMic/Tools/Protocol/Tool.swift \
	       Sources/KeyMic/Tools/Protocol/ToolContext.swift \
	       -o .build/read-tool-tests
	.build/read-tool-tests

test-write-tool:
	mkdir -p .build
	swiftc Tests/WriteToolTests.swift \
	       Sources/KeyMic/Tools/File/WriteTool.swift \
	       Sources/KeyMic/Tools/File/FileSystemActor.swift \
	       Sources/KeyMic/Tools/File/FileSystemError.swift \
	       Sources/KeyMic/Tools/Protocol/Tool.swift \
	       Sources/KeyMic/Tools/Protocol/ToolContext.swift \
	       -o .build/write-tool-tests
	.build/write-tool-tests

test-edit-tool:
	mkdir -p .build
	swiftc Tests/EditToolTests.swift \
	       Sources/KeyMic/Tools/File/EditTool.swift \
	       Sources/KeyMic/Tools/File/FileSystemActor.swift \
	       Sources/KeyMic/Tools/File/FileSystemError.swift \
	       Sources/KeyMic/Tools/Protocol/Tool.swift \
	       Sources/KeyMic/Tools/Protocol/ToolContext.swift \
	       -o .build/edit-tool-tests
	.build/edit-tool-tests

test-multi-edit-tool:
	mkdir -p .build
	swiftc Tests/MultiEditToolTests.swift \
	       Sources/KeyMic/Tools/File/MultiEditTool.swift \
	       Sources/KeyMic/Tools/File/FileSystemActor.swift \
	       Sources/KeyMic/Tools/File/FileSystemError.swift \
	       Sources/KeyMic/Tools/Protocol/Tool.swift \
	       Sources/KeyMic/Tools/Protocol/ToolContext.swift \
	       -o .build/multi-edit-tool-tests
	.build/multi-edit-tool-tests

test-glob-tool:
	mkdir -p .build
	swiftc Tests/GlobToolTests.swift \
	       Sources/KeyMic/Tools/Search/GlobTool.swift \
	       Sources/KeyMic/Tools/File/FileSystemActor.swift \
	       Sources/KeyMic/Tools/File/FileSystemError.swift \
	       Sources/KeyMic/Tools/Protocol/Tool.swift \
	       Sources/KeyMic/Tools/Protocol/ToolContext.swift \
	       -o .build/glob-tool-tests
	.build/glob-tool-tests

test-grep-tool:
	mkdir -p .build
	swiftc Tests/GrepToolTests.swift \
	       Sources/KeyMic/Tools/Search/GrepTool.swift \
	       Sources/KeyMic/Tools/Search/GlobTool.swift \
	       Sources/KeyMic/Tools/File/FileSystemActor.swift \
	       Sources/KeyMic/Tools/File/FileSystemError.swift \
	       Sources/KeyMic/Tools/Protocol/Tool.swift \
	       Sources/KeyMic/Tools/Protocol/ToolContext.swift \
	       -o .build/grep-tool-tests
	.build/grep-tool-tests

test-mcp-config:
	mkdir -p .build
	swiftc Tests/MCPServerConfigTests.swift \
	       Sources/KeyMic/Tools/MCP/MCPServerConfig.swift \
	       Sources/KeyMic/Tools/MCP/MCPClientError.swift \
	       -o .build/mcp-config-tests
	.build/mcp-config-tests

test-mcp-config-store:
	mkdir -p .build
	swiftc Tests/MCPConfigStoreTests.swift \
	       Sources/KeyMic/Tools/MCP/MCPServerConfig.swift \
	       Sources/KeyMic/Tools/MCP/MCPConfigStore.swift \
	       Sources/KeyMic/Tools/MCP/MCPClientError.swift \
	       -o .build/mcp-config-store-tests
	.build/mcp-config-store-tests

test-mcp-adapter:
	mkdir -p .build
	swift build
	$(eval MCP_DEBUG_BUILD_DIR := $(shell swift build --show-bin-path))
	swiftc -I $(MCP_DEBUG_BUILD_DIR)/Modules \
	       Tests/MCPToolAdapterTests.swift \
	       Sources/KeyMic/Tools/MCP/MCPToolAdapter.swift \
	       Sources/KeyMic/Tools/MCP/MCPClientProtocol.swift \
	       Sources/KeyMic/Tools/MCP/MCPClientError.swift \
	       Sources/KeyMic/Tools/Protocol/Tool.swift \
	       Sources/KeyMic/Tools/Protocol/ToolContext.swift \
	       $(MCP_DEBUG_BUILD_DIR)/MCP.build/Value.swift.o \
	       $(MCP_DEBUG_BUILD_DIR)/MCP.build/Data+Extensions.swift.o \
	       $(MCP_DEBUG_BUILD_DIR)/MCP.build/Messages.swift.o \
	       $(MCP_DEBUG_BUILD_DIR)/MCP.build/ID.swift.o \
	       $(MCP_DEBUG_BUILD_DIR)/MCP.build/Error.swift.o \
	       $(MCP_DEBUG_BUILD_DIR)/MCP.build/Progress.swift.o \
	       $(MCP_DEBUG_BUILD_DIR)/MCP.build/Tools.swift.o \
	       $(MCP_DEBUG_BUILD_DIR)/MCP.build/Resources.swift.o \
	       $(MCP_DEBUG_BUILD_DIR)/MCP.build/Icon.swift.o \
	       -o .build/mcp-tool-adapter-tests
	.build/mcp-tool-adapter-tests


test-mcp-manager:
	mkdir -p .build
	swift build
	$(eval MCP_DEBUG_BUILD_DIR := $(shell swift build --show-bin-path))
	swiftc -I $(MCP_DEBUG_BUILD_DIR)/Modules \
	       Tests/MCPClientManagerTests.swift \
	       Sources/KeyMic/Tools/MCP/MCPClientManager.swift \
	       Sources/KeyMic/Tools/MCP/MCPClient.swift \
	       Sources/KeyMic/Tools/MCP/MCPToolAdapter.swift \
	       Sources/KeyMic/Tools/MCP/MCPClientProtocol.swift \
	       Sources/KeyMic/Tools/MCP/MCPConfigStore.swift \
	       Sources/KeyMic/Tools/MCP/MCPServerConfig.swift \
	       Sources/KeyMic/Tools/MCP/MCPTokenStore.swift \
	       Sources/KeyMic/Tools/MCP/MCPClientError.swift \
	       Sources/KeyMic/Vault/KeychainBackend.swift \
	       Sources/KeyMic/Tools/Protocol/Tool.swift \
	       Sources/KeyMic/Tools/Protocol/ToolContext.swift \
	       Sources/KeyMic/Tools/Protocol/ToolRegistry.swift \
	       $(MCP_DEBUG_BUILD_DIR)/MCP.build/*.swift.o \
	       $(MCP_DEBUG_BUILD_DIR)/EventSource.build/*.swift.o \
	       $(MCP_DEBUG_BUILD_DIR)/Logging.build/*.swift.o \
	       $(MCP_DEBUG_BUILD_DIR)/SystemPackage.build/*.swift.o \
	       -o .build/mcp-client-manager-tests
	.build/mcp-client-manager-tests

test-shell-snapshot:
	mkdir -p .build
	swiftc Tests/ShellSnapshotTests.swift \
	       Sources/KeyMic/Tools/Bash/ShellSnapshot.swift \
	       Sources/KeyMic/Tools/Bash/ShellLogger.swift \
	       -o .build/shell-snapshot-tests
	.build/shell-snapshot-tests

test-shell-runner:
	mkdir -p .build
	swiftc Tests/ShellRunnerTests.swift \
	       Sources/KeyMic/Tools/Bash/ShellRunner.swift \
	       Sources/KeyMic/Tools/Bash/ShellSnapshot.swift \
	       Sources/KeyMic/Tools/Bash/ShellLogger.swift \
	       -o .build/shell-runner-tests
	.build/shell-runner-tests

test-skill-frontmatter-parser:
	mkdir -p .build
	swiftc Tests/SkillFrontmatterParserTests.swift \
	       Sources/KeyMic/Tools/Skill/Skill.swift \
	       Sources/KeyMic/Tools/Skill/SkillError.swift \
	       Sources/KeyMic/Tools/Skill/SkillFrontmatterParser.swift \
	       -o .build/skill-frontmatter-parser-tests
	.build/skill-frontmatter-parser-tests

test-all: test test-clipboard-store test-clipboard-monitor test-cleanup-policy test-hotkey-config test-hotkey-action test-hotkey-bindings-store test-hotkey-settings-store test-toml-parser test-kind-classifier test-hotkey-action-runner test-keymonitor-clipboard-panel test-single-instance test-speech-engine test-keychain-vault test-secret-scanner test-vault-store test-annotation-model test-pixelator test-renderer test-selection-handles test-toolbar-positioner test-overlay-state test-persona test-persona-store test-hotkey-registry test-shell-logger test-shell-snapshot test-shell-runner test-skill-frontmatter-parser test-clipboard-store-binary test-clipboard-monitor-types test-thumbnail-cache test-input-state test-secure-input-monitor test-tool-protocol test-bash-tool test-filesystem-actor test-read-tool test-write-tool test-edit-tool test-multi-edit-tool test-glob-tool test-grep-tool test-mcp-config test-mcp-config-store test-mcp-adapter test-mcp-manager test-voice-session test-voice-state-machine
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

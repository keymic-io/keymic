# Hotkey Settings Store Design

## Goal

Centralize all KeyMic hotkey configuration in one persisted store. This includes app feature hotkeys and Persona hotkeys. The store becomes the single source of truth for runtime hotkey loading, settings UI updates, and Persona hotkey registration.

## Scope

This design covers:

- Default hotkeys for built-in app features.
- User-customized feature hotkeys recorded in Settings.
- User-customized Persona hotkeys recorded in the Persona settings UI.
- Startup initialization when no centralized store exists.

This design does not include migration from legacy scattered UserDefaults keys. On first launch with the new store, the app creates a complete initial snapshot from centralized defaults and the current Persona list.

## Architecture

Add `HotkeySettingsStore` under `Sources/KeyMic/Hotkey/`. It owns all hotkey storage and exposes read/write APIs for feature and Persona hotkeys.

Core concepts:

- `HotkeyFeature`: a `Codable` enum for first-party app features.
- `HotkeySettingsSnapshot`: a `Codable` persisted value containing versioned feature and Persona hotkey maps.
- `HotkeySettingsStore`: an observable singleton that loads, initializes, validates, updates, and saves the snapshot.

The store persists to a single `UserDefaults` key:

- `hotkeySettings.v1`

## Feature Hotkeys

`HotkeyFeature` should include the current first-party hotkeys:

- `voiceTrigger` — press and hold to start voice input.
- `clipboardPanel` — open the clipboard history panel.
- `vaultPanel` — open the Vault panel.
- `settingsWindow` — open the Settings window.
- `screenshot` — open the screenshot selection and annotation UI.

The centralized default definitions should include one short comment per entry explaining what the hotkey does. These comments are intentional documentation because these defaults are now the canonical registry for feature hotkeys.

Suggested default raw values:

- `voiceTrigger`: `fn`
- `clipboardPanel`: `alt+v`
- `vaultPanel`: `alt+b`
- `settingsWindow`: `cmd+shift+comma`
- `screenshot`: `ctrl+alt+a`

If a default cannot be parsed by `HotkeyConfig`, that is a code bug and should be caught during build-time review or tests.

## Persisted Snapshot

Suggested structure:

```swift
struct HotkeySettingsSnapshot: Codable, Equatable {
    var version: Int
    var featureHotkeys: [String: String]
    var personaHotkeys: [String: String]
}
```

`featureHotkeys` stores every `HotkeyFeature.rawValue` mapped to a `HotkeyConfig.encode()` string. It is a full snapshot, not only overrides.

`personaHotkeys` maps `Persona.id` to a `HotkeyConfig.encode()` string. Personas with no configured hotkey are omitted from this dictionary.

## Startup Initialization

At application startup, initialize the store once:

1. If `hotkeySettings.v1` exists and decodes successfully, load it.
2. If it does not exist, create a new full snapshot using centralized feature defaults and the current Persona list.
3. Persist the created snapshot immediately.

No legacy UserDefaults migration is performed. Legacy scattered keys can remain in storage, but runtime code should stop reading them for hotkey behavior after this change.

## Data Flow

### Runtime loading

`KeyMonitor` should load all app feature hotkeys from `HotkeySettingsStore` instead of reading scattered keys such as `clipboardHotkey`, `vaultHotkey`, `settingsHotkey`, `screenshotHotkey`, or `voiceTriggerKey`.

Persona hotkey registration should also use `HotkeySettingsStore.personaHotkey(for:)` instead of `Persona.hotkey` as the runtime source of truth.

### Settings UI

Settings views should read and write through `HotkeySettingsStore`.

Feature hotkey recorders should update `featureHotkeys` through Store APIs. The UI can still use local SwiftUI state for editing, but commits must call the Store.

Persona hotkey recorders should update `personaHotkeys` through Store APIs. `Persona.hotkey` should no longer be the authoritative runtime value.

### AppDelegate refresh

`AppDelegate` should trigger runtime refreshes after Store changes so `KeyMonitor` and menus reflect the latest hotkey configuration.

## Public API Shape

Suggested Store API:

```swift
final class HotkeySettingsStore {
    static let shared: HotkeySettingsStore

    func rawHotkey(for feature: HotkeyFeature) -> String
    func hotkey(for feature: HotkeyFeature) -> HotkeyConfig?
    func setHotkey(_ config: HotkeyConfig, for feature: HotkeyFeature) throws
    func resetHotkey(for feature: HotkeyFeature)

    func rawPersonaHotkey(personaId: String) -> String?
    func personaHotkey(personaId: String) -> HotkeyConfig?
    func setPersonaHotkey(_ config: HotkeyConfig?, personaId: String) throws
}
```

The exact names can follow existing project style, but callers should not access the persisted snapshot directly.

## Validation and Conflicts

Store writes should validate that recorded hotkeys parse successfully and are not system-reserved.

Conflict checks should happen in one place. The Store should be able to compare feature hotkeys and Persona hotkeys together so a newly recorded hotkey cannot silently duplicate another active hotkey.

If a conflict exists, the Store should reject the update with a user-readable error string that Settings UI can display through the existing `HotkeyRecorder` validation flow.

## Error Handling

- Decode failure: log the failure and fall back to a fresh default snapshot.
- Invalid stored feature hotkey: fall back to that feature's centralized default.
- Invalid stored Persona hotkey: ignore that Persona hotkey.
- Failed encode: leave the current in-memory snapshot unchanged and do not overwrite persisted data.

## Testing

Minimum test coverage:

1. Store initializes a complete snapshot when no persisted value exists.
2. Store loads an existing persisted snapshot.
3. Feature hotkey updates persist and reload.
4. Persona hotkey updates persist and reload.
5. Invalid Persona hotkey values are ignored.
6. Invalid feature hotkey values fall back to defaults.
7. Duplicate hotkeys across features and Personas are rejected.
8. `make build` succeeds after runtime callers switch to the Store.

## Implementation Notes

Keep `HotkeyConfig` as the parser, display formatter, and encoder. Do not duplicate hotkey parsing logic inside the new Store.

Keep `HotkeyBindingsStore` separate. It represents custom action bindings, while `HotkeySettingsStore` represents first-party feature and Persona hotkey configuration. Combining the two would blur distinct concepts.

/// Which entry point started the current voice session. Both sources show the
/// picker (a `.personaHotkey` pre-highlights its persona for context preview),
/// but only `.defaultTrigger` is interactive and can open the context console;
/// `.personaHotkey` runs its persona directly on release.
enum VoiceTriggerSource: Equatable {
    case defaultTrigger
    case personaHotkey(personaId: String)
}

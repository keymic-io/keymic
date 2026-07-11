/// Which entry point started the current voice session. The picker + console
/// apply ONLY to `.defaultTrigger`; `.personaHotkey` runs its persona directly.
enum VoiceTriggerSource: Equatable {
    case defaultTrigger
    case personaHotkey(personaId: String)
}

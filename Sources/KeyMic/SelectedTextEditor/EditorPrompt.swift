import Foundation

/// Pure prompt-assembly helpers for the Selected Text Editor.
/// Kept Foundation-only so the standalone test runner can exercise it
/// without dragging in AppKit / SwiftUI / Observation.
enum EditorPrompt {
    /// Base system prompt for the GeneralEditor persona (spec §6).
    /// Mirrored in `Persona.builtInSeeds()`. The controller prefers the persona's
    /// `stylePrompt` (which the user may have edited) and falls back to this constant.
    static let systemPrompt: String = """
        You are a precise editor that rewrites a user's SELECTED text according to a brief \
        INSTRUCTION. Return ONLY the rewritten text — no preamble, no explanations, no quotes, \
        no markdown fences. Preserve the original language unless the instruction asks otherwise.
        """

    /// Resolves the final instruction string sent to the LLM.
    ///
    /// - `.freeForm` → the user's typed/spoken text verbatim (may be empty — caller must gate).
    /// - Any other action with empty `typed` → the action's template only.
    /// - Any other action with non-empty `typed` → `<template>\n\n<typed>` (template first).
    static func buildInstruction(action: EditorAction, typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .freeForm:
            return trimmed
        default:
            if trimmed.isEmpty {
                return action.promptTemplate
            }
            return action.promptTemplate + "\n\n" + trimmed
        }
    }

    /// Two-section user message: `[Selected text]\n<sel>\n\n[Instruction]\n<inst>`.
    /// Caller passes full (non-truncated) selection text.
    static func composeUserMessage(selection: String, instruction: String) -> String {
        return "[Selected text]\n\(selection)\n\n[Instruction]\n\(instruction)"
    }
}

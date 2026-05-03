//
//  ClickyPetHatchCoordinator.swift
//  OpenClicky
//
//  Kicks off a "Hatch a buddy" run by creating a Codex Agent Mode session
//  and submitting a prompt that triggers the installed `hatch-pet` skill.
//
//  We deliberately keep the prompt as a plain top-level string so it can be
//  tweaked without touching unrelated code if the skill's auto-trigger
//  phrasing changes.
//

import AppKit
import Foundation

@MainActor
final class ClickyPetHatchCoordinator {
    static let shared = ClickyPetHatchCoordinator()

    private init() {}

    /// Begins a hatch run. Creates a fresh agent session, submits the prompt,
    /// and returns the session ID so callers can show progress in the HUD.
    @discardableResult
    func beginHatch(
        name: String,
        description: String,
        accentTheme: ClickyAccentTheme,
        companionManager: CompanionManager
    ) -> UUID? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let title = "Hatch \(trimmedName)"
        let prompt = Self.hatchPrompt(name: trimmedName, description: trimmedDescription)
        let session = companionManager.createAndLaunchCodexAgentSession(
            title: title,
            prompt: prompt,
            accentTheme: accentTheme,
            includeScreenContext: false
        )
        return session.id
    }

    /// Auto-triggers the hatch-pet skill installed at
    /// `~/.codex/skills/hatch-pet`. The phrasing matches the skill's own
    /// trigger description so it routes correctly without an explicit
    /// `/skill` invocation.
    static func hatchPrompt(name: String, description: String) -> String {
        let descLine: String
        if description.isEmpty {
            descLine = "Use a fitting one-sentence description."
        } else {
            descLine = "Description: \(description)"
        }
        return """
        Use the hatch-pet skill to hatch a new Codex pet for OpenClicky.

        Name: \(name)
        \(descLine)

        Acceptance:
        - Final files saved to ${CODEX_HOME:-$HOME/.codex}/pets/\(slug(name))/pet.json and spritesheet.webp.
        - Atlas dimensions 1536x1872 with 8x9 192x208 cells.
        - Reply with the absolute path to the saved pet folder when done.
        """
    }

    /// Approximate the slug `prepare_pet_run.py` will pick. Used only inside
    /// the prompt for verification — the actual folder name is decided by
    /// the skill, not by us.
    private static func slug(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        var out = ""
        var lastWasDash = false
        for scalar in name.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = scalar == "-"
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

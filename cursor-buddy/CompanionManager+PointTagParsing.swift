//
//  CompanionManager+PointTagParsing.swift
//  cursor-buddy
//

@preconcurrency import AVFoundation
import OCComputerUseCore
import AppKit
import Combine
import CoreAudio
import Foundation
import os
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import OCCore
import OCUI
@preconcurrency import OCBrowser
import OCMarkdown
import OCMemory

extension CompanionManager {
    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
        /// Optional temporary visual overlay parsed from a voice-lane draw/highlight tag.
        let visualOverlay: OpenClickyVisualGuidanceOverlay?
        let visualOverlayScreenNumber: Int?
        let visualGuidanceActions: [ParsedVisualGuidanceAction]

        init(
            spokenText: String,
            coordinate: CGPoint?,
            elementLabel: String?,
            screenNumber: Int?,
            visualOverlay: OpenClickyVisualGuidanceOverlay?,
            visualOverlayScreenNumber: Int? = nil,
            visualGuidanceActions: [ParsedVisualGuidanceAction] = []
        ) {
            self.spokenText = spokenText
            self.coordinate = coordinate
            self.elementLabel = elementLabel
            self.screenNumber = screenNumber
            self.visualOverlay = visualOverlay
            self.visualOverlayScreenNumber = visualOverlayScreenNumber
            self.visualGuidanceActions = visualGuidanceActions
        }
    }

    struct ParsedVisualGuidanceAction {
        let coordinate: CGPoint?
        let elementLabel: String?
        let screenNumber: Int?
        let overlay: OpenClickyVisualGuidanceOverlay?
        let isExplicitNone: Bool
        let threeDPrompt: String?

        init(
            coordinate: CGPoint?,
            elementLabel: String?,
            screenNumber: Int?,
            overlay: OpenClickyVisualGuidanceOverlay?,
            isExplicitNone: Bool,
            threeDPrompt: String? = nil
        ) {
            self.coordinate = coordinate
            self.elementLabel = elementLabel
            self.screenNumber = screenNumber
            self.overlay = overlay
            self.isExplicitNone = isExplicitNone
            self.threeDPrompt = threeDPrompt
        }
    }

    private struct VisualGuidanceTagMatch {
        let range: NSRange
        let action: ParsedVisualGuidanceAction
    }

    /// Strips a trailing partial private visual-guidance control tag from a
    /// parsed spoken-text string. During streaming the `[POINT:]`, `[RECT:]`,
    /// `[SCRIBBLE:]`, or `[ARROW:]` tag arrives one token at a time; until `]`
    /// lands, `parsePointingCoordinates` can't match it and the half-formed tag
    /// would otherwise leak into the TTS pipeline. This keeps overlays as a
    /// separate control action instead of spoken instructions.
    static func stripTrailingVisualGuidanceTagFragment(_ text: String) -> String {
        guard let openBracket = text.lastIndex(of: "[") else { return text }
        let fragment = text[openBracket...]
        guard !fragment.contains("]") else { return text }

        let upperFragment = fragment.uppercased()
        let visualPrefixes = ["[POINT", "[RECT", "[SCRIBBLE", "[ARROW", "[SCENE3D"]
        let isPartialVisualTag = visualPrefixes.contains { prefix in
            prefix.hasPrefix(upperFragment) || upperFragment.hasPrefix(prefix + ":")
        }
        guard isPartialVisualTag else { return text }
        return String(text[..<openBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func combinedVoiceResponseText(prefill: String, continuation: String) -> String {
        let trimmedPrefill = prefill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefill.isEmpty else { return continuation }
        guard !continuation.isEmpty else { return trimmedPrefill }
        if continuation.first?.isWhitespace == true {
            return trimmedPrefill + continuation
        }
        return trimmedPrefill + " " + continuation
    }

    /// Parses [POINT], [RECT], [SCRIBBLE], and [ARROW] tags in Claude's response.
    /// Also accepts multiple inline visual tags so cues can appear between spoken beats.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        let matches = visualGuidanceTagMatches(in: responseText)
        let spokenText = stripVisualGuidanceTags(from: responseText, matches: matches)
        let pointAction = matches.reversed().map(\.action).first { $0.coordinate != nil }
        let overlayAction = matches.reversed().map(\.action).first { $0.overlay != nil }
        let explicitNone = matches.contains { $0.action.isExplicitNone }
        return PointingParseResult(
            spokenText: spokenText,
            coordinate: pointAction?.coordinate,
            elementLabel: pointAction?.elementLabel ?? (explicitNone ? "none" : overlayAction?.elementLabel),
            screenNumber: pointAction?.screenNumber,
            visualOverlay: overlayAction?.overlay,
            visualOverlayScreenNumber: overlayAction?.screenNumber,
            visualGuidanceActions: matches.map(\.action)
        )
    }

    static func stripVisualGuidanceTags(from responseText: String) -> String {
        stripVisualGuidanceTags(from: responseText, matches: visualGuidanceTagMatches(in: responseText))
    }

    private static func stripVisualGuidanceTags(from responseText: String, matches: [VisualGuidanceTagMatch]) -> String {
        var spokenText = responseText
        for match in matches.reversed() {
            guard let range = Range(match.range, in: spokenText) else { continue }
            spokenText.removeSubrange(range)
        }
        return spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func visualGuidanceTagMatches(in responseText: String) -> [VisualGuidanceTagMatch] {
        var matches: [VisualGuidanceTagMatch] = []
        let fullRange = NSRange(responseText.startIndex..., in: responseText)

        let rectanglePattern = #"\[RECT:(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]"#
        if let regex = try? NSRegularExpression(pattern: rectanglePattern, options: []) {
            for match in regex.matches(in: responseText, range: fullRange) {
                guard let x = match.double(at: 1, in: responseText),
                      let y = match.double(at: 2, in: responseText),
                      let width = match.double(at: 3, in: responseText),
                      let height = match.double(at: 4, in: responseText) else { continue }
                let label = match.string(at: 5, in: responseText)
                let screenNumber = match.int(at: 6, in: responseText)
                let overlay = OpenClickyVisualGuidanceOverlay.rectangle(
                    rect: CGRect(x: x, y: y, width: width, height: height),
                    caption: label
                )
                matches.append(VisualGuidanceTagMatch(
                    range: match.range,
                    action: ParsedVisualGuidanceAction(
                        coordinate: nil,
                        elementLabel: label,
                        screenNumber: screenNumber,
                        overlay: overlay,
                        isExplicitNone: false
                    )
                ))
            }
        }

        let pathPattern = #"\[(SCRIBBLE|ARROW):([^:\]]+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]"#
        if let regex = try? NSRegularExpression(pattern: pathPattern, options: [.caseInsensitive]) {
            for match in regex.matches(in: responseText, range: fullRange) {
                guard let rawPoints = match.string(at: 2, in: responseText) else { continue }
                let points = rawPoints.split(separator: ";").compactMap { rawPair -> CGPoint? in
                    let values = rawPair.split(separator: ",", maxSplits: 1).map {
                        Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    guard values.count == 2, let x = values[0], let y = values[1] else { return nil }
                    return CGPoint(x: x, y: y)
                }
                guard points.count >= 2 else { continue }
                let kind = match.string(at: 1, in: responseText)?.uppercased()
                let label = match.string(at: 3, in: responseText)
                let screenNumber = match.int(at: 4, in: responseText)
                let overlay = kind == "ARROW"
                    ? OpenClickyVisualGuidanceOverlay.arrow(points: points, caption: label)
                    : OpenClickyVisualGuidanceOverlay.scribble(points: points, caption: label)
                matches.append(VisualGuidanceTagMatch(
                    range: match.range,
                    action: ParsedVisualGuidanceAction(
                        coordinate: nil,
                        elementLabel: label,
                        screenNumber: screenNumber,
                        overlay: overlay,
                        isExplicitNone: false
                    )
                ))
            }
        }

        let pointPattern = #"\[POINT:(none|(-?\d+)\s*,\s*(-?\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]"#
        if let regex = try? NSRegularExpression(pattern: pointPattern, options: [.caseInsensitive]) {
            for match in regex.matches(in: responseText, range: fullRange) {
                let payload = match.string(at: 1, in: responseText)?.lowercased()
                let coordinate: CGPoint? = {
                    guard let x = match.double(at: 2, in: responseText),
                          let y = match.double(at: 3, in: responseText) else { return nil }
                    return CGPoint(x: x, y: y)
                }()
                let label = match.string(at: 4, in: responseText)
                matches.append(VisualGuidanceTagMatch(
                    range: match.range,
                    action: ParsedVisualGuidanceAction(
                        coordinate: coordinate,
                        elementLabel: coordinate == nil ? "none" : label,
                        screenNumber: match.int(at: 5, in: responseText),
                        overlay: nil,
                        isExplicitNone: payload == "none"
                    )
                ))
            }
        }

        let scene3DPattern = #"\[SCENE3D:([^\]\n]{1,300})\]"#
        if let regex = try? NSRegularExpression(pattern: scene3DPattern, options: [.caseInsensitive]) {
            for match in regex.matches(in: responseText, range: fullRange) {
                guard let prompt = match.string(at: 1, in: responseText) else { continue }
                matches.append(VisualGuidanceTagMatch(
                    range: match.range,
                    action: ParsedVisualGuidanceAction(
                        coordinate: nil,
                        elementLabel: "3D scene",
                        screenNumber: nil,
                        overlay: nil,
                        isExplicitNone: false,
                        threeDPrompt: String(prompt.prefix(300))
                    )
                ))
            }
        }

        return matches.sorted { $0.range.location < $1.range.location }
    }

}

private extension NSTextCheckingResult {
    func string(at index: Int, in text: String) -> String? {
        guard numberOfRanges > index,
              let range = Range(self.range(at: index), in: text) else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func double(at index: Int, in text: String) -> Double? {
        guard let value = string(at: index, in: text) else { return nil }
        return Double(value)
    }

    func int(at index: Int, in text: String) -> Int? {
        guard let value = string(at: index, in: text) else { return nil }
        return Int(value)
    }
}

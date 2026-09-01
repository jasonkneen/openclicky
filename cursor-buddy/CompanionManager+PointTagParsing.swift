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
import OpenClickyCore
import OpenClickyUI
@preconcurrency import OpenClickyBrowser
import OpenClickyMarkdown
import OpenClickyMemory

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
    }

    /// Strips a trailing partial private visual-guidance control tag from a
    /// parsed spoken-text string. During streaming the `[POINT:]`, `[RECT:]`,
    /// or `[SCRIBBLE:]` tag arrives one token at a time; until the closing `]`
    /// lands, `parsePointingCoordinates` can't match it and the half-formed tag
    /// would otherwise leak into the TTS pipeline. This keeps overlays as a
    /// separate control action instead of spoken instructions.
    static func stripTrailingVisualGuidanceTagFragment(_ text: String) -> String {
        guard let openBracket = text.lastIndex(of: "[") else { return text }
        let fragment = text[openBracket...]
        guard !fragment.contains("]") else { return text }

        let upperFragment = fragment.uppercased()
        let visualPrefixes = ["[POINT", "[RECT", "[SCRIBBLE"]
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

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        if let rectangleResult = parseRectangleGuidance(from: responseText) {
            return rectangleResult
        }
        if let scribbleResult = parseScribbleGuidance(from: responseText) {
            return scribbleResult
        }

        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil, visualOverlay: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil, visualOverlay: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber,
            visualOverlay: nil
        )
    }

    private static func parseRectangleGuidance(from responseText: String) -> PointingParseResult? {
        let pattern = #"\[RECT:(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let tagRange = Range(match.range, in: responseText),
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let widthRange = Range(match.range(at: 3), in: responseText),
              let heightRange = Range(match.range(at: 4), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]),
              let width = Double(responseText[widthRange]),
              let height = Double(responseText[heightRange]) else { return nil }

        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let label = guidanceLabel(from: responseText, match: match, index: 5)
        let screenNumber = guidanceScreenNumber(from: responseText, match: match, index: 6)
        let overlay = OpenClickyVisualGuidanceOverlay.rectangle(
            rect: CGRect(x: x, y: y, width: width, height: height),
            caption: label
        )

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: nil,
            elementLabel: label,
            screenNumber: screenNumber,
            visualOverlay: overlay
        )
    }

    private static func parseScribbleGuidance(from responseText: String) -> PointingParseResult? {
        let pattern = #"\[SCRIBBLE:([^:\]]+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let tagRange = Range(match.range, in: responseText),
              let pointsRange = Range(match.range(at: 1), in: responseText) else { return nil }

        let points = responseText[pointsRange]
            .split(separator: ";")
            .compactMap { rawPair -> CGPoint? in
                let values = rawPair.split(separator: ",", maxSplits: 1).map {
                    Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                guard values.count == 2, let x = values[0], let y = values[1] else { return nil }
                return CGPoint(x: x, y: y)
            }
        guard points.count >= 2 else { return nil }

        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let label = guidanceLabel(from: responseText, match: match, index: 2)
        let screenNumber = guidanceScreenNumber(from: responseText, match: match, index: 3)
        let overlay = OpenClickyVisualGuidanceOverlay.scribble(points: points, caption: label)

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: nil,
            elementLabel: label,
            screenNumber: screenNumber,
            visualOverlay: overlay
        )
    }

    private static func guidanceLabel(from responseText: String, match: NSTextCheckingResult, index: Int) -> String? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: responseText) else { return nil }
        let label = String(responseText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    private static func guidanceScreenNumber(from responseText: String, match: NSTextCheckingResult, index: Int) -> Int? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: responseText) else { return nil }
        return Int(responseText[range])
    }
}

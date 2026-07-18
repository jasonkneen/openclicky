#!/usr/bin/env bash
# Compile and run pure catalog + discovery + auto-hide policy tests against
# SHIPPED sources (OpenClickyModelCatalog, OpenClickyProviderDiscovery,
# CodexRuntimeLocator, ResponseOverlayAutoHidePolicy).
# Avoids xcodebuild (forbidden for day-to-day agent work per AGENTS.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/openclicky-provider-catalog-tests-$$"
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT

SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="arm64-apple-macos15.0"

# Minimal AppBundleConfiguration surface used only by discovery key probes.
cat > "$OUT/AppBundleConfigurationStub.swift" <<'SWIFT'
import Foundation

nonisolated enum AppBundleConfiguration {
    static func openAIAPIKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env["OPENAI_API_KEY"], !v.isEmpty { return v }
        return UserDefaults.standard.string(forKey: "openClickyCodexAgentAPIKey")
    }

    static func anthropicAPIKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env["ANTHROPIC_API_KEY"], !v.isEmpty {
            return v.hasPrefix("sk-ant-api") ? v : nil
        }
        if let v = UserDefaults.standard.string(forKey: "openClickyAnthropicAPIKey"), !v.isEmpty {
            return v.hasPrefix("sk-ant-api") ? v : nil
        }
        return nil
    }
}
SWIFT

cat > "$OUT/main.swift" <<'SWIFT'
import Foundation

var failures = 0
func expect(_ cond: @autoclosure () -> Bool, _ msg: String) {
    if !cond() {
        print("FAIL: \(msg)")
        failures += 1
    } else {
        print("PASS: \(msg)")
    }
}

// --- Catalog family mapping ---
let apple = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyModelCatalog.appleFoundationModelID)
expect(apple.id == OpenClickyModelCatalog.appleFoundationModelID, "apple model id resolves")
expect(apple.provider == .apple, "apple model has provider .apple")
expect(apple.provider.voiceBackendFamily == .apple, "apple maps to apple family")
expect(apple.maxOutputTokens >= 64_000, "apple has non-short TTS budget")

let claudeDefault = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyVoiceBackendFamily.claude.defaultModelID)
expect(claudeDefault.provider == .anthropic, "claude family default is anthropic")
expect(claudeDefault.provider.voiceBackendFamily == .claude, "claude family maps")

let codexDefault = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyVoiceBackendFamily.codex.defaultModelID)
expect(codexDefault.provider.voiceBackendFamily == .codex, "codex family default maps to codex family")
expect(OpenClickyVoiceBackendFamily.apple.defaultModelID == OpenClickyModelCatalog.appleFoundationModelID, "apple default model id")
expect(OpenClickyVoiceBackendFamily.claude.defaultModelID == "claude-haiku-4-5", "claude default model id")
expect(OpenClickyVoiceBackendFamily.codex.defaultModelID == OpenClickyModelCatalog.defaultCodexActionsModelID, "codex default model id")
expect(OpenClickyVoiceBackendFamily.allCases.count == 3, "exactly three families")
expect(Set(OpenClickyVoiceBackendFamily.allCases.map(\.rawValue)) == Set(["apple", "codex", "claude"]), "family raw values")

let speech = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyModelCatalog.defaultSpeechModelID)
expect(OpenClickyModelCatalog.isSpeechModelID(speech.id), "default speech is speech model")
expect(speech.provider == .openAI, "realtime speech provider is openAI")

// --- Discovery ---
let rows = OpenClickyProviderDiscovery.availability()
expect(rows.count == 3, "discovery returns 3 rows")
expect(rows.map(\.family) == [.apple, .codex, .claude], "discovery order apple,codex,claude")
for row in rows {
    expect(!row.statusLabel.isEmpty, "\(row.family) has status label")
    expect(!row.detail.isEmpty, "\(row.family) has detail")
    print("  discovery \(row.family.rawValue): available=\(row.isAvailable) status=\(row.statusLabel)")
}

for family in OpenClickyVoiceBackendFamily.allCases {
    let fromRows = rows.first { $0.family == family }?.isAvailable ?? false
    expect(OpenClickyProviderDiscovery.isAvailable(family) == fromRows, "isAvailable(\(family)) matches row")
}

// --- Auto-hide cancel-before-reschedule (response bubble lifetime) ---
var policy = ResponseOverlayAutoHidePolicy()
let first = policy.schedule(now: 0, holdSeconds: 6)
expect(policy.shouldHide(now: 6, generation: first), "first schedule fires at T+6")
let second = policy.schedule(now: 1.5, holdSeconds: 6)
expect(!policy.shouldHide(now: 6, generation: first), "stale first-chunk hide must NOT fire after reschedule")
expect(policy.shouldHide(now: 7.5, generation: second), "second schedule fires at 1.5+6")
expect(!policy.shouldHide(now: 7.4, generation: second), "second schedule not early")
policy.cancel()
expect(policy.scheduledHideAt == nil, "cancel clears pending hide")
expect(!policy.shouldHide(now: 100, generation: second), "cancelled gen never fires")

var stream = ResponseOverlayAutoHidePolicy()
var gens: [UInt64] = []
for t in [0.0, 0.5, 1.0, 2.0] {
    stream.cancel()
    gens.append(stream.schedule(now: t, holdSeconds: 6))
}
let last = gens.last!
for (i, g) in gens.dropLast().enumerated() {
    expect(!stream.shouldHide(now: 100, generation: g), "stale gen \(i) must not fire")
}
expect(stream.shouldHide(now: 2.0 + 6, generation: last), "only last chunk schedule fires")
expect(ResponseOverlayAutoHidePolicy.defaultHoldSeconds > 1.2, "bubble hold outlives 1.2s cursor clear")
expect(ResponseOverlayAutoHidePolicy.defaultHoldSeconds >= 6, "default hold is 6s")

if failures == 0 {
    print("\nALL PASSED")
    exit(0)
} else {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
SWIFT

xcrun swiftc -O -sdk "$SDK" -target "$TARGET" \
  -o "$OUT/provider_tests" \
  "$ROOT/cursor-buddy/OpenClickyModelCatalog.swift" \
  "$ROOT/cursor-buddy/CodexRuntimeLocator.swift" \
  "$ROOT/cursor-buddy/OpenClickyProviderDiscovery.swift" \
  "$ROOT/cursor-buddy/ResponseOverlayAutoHidePolicy.swift" \
  "$OUT/AppBundleConfigurationStub.swift" \
  "$OUT/main.swift"

exec "$OUT/provider_tests"

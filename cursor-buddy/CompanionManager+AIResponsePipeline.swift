//
//  CompanionManager+AIResponsePipeline.swift
//  cursor-buddy
//

@preconcurrency import AVFoundation
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
    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        rememberMainConversationUserPrompt(transcript, source: "voice_response")
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let plannedVoiceAnalysisModelID: String? = {
            let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
            guard OpenClickyModelCatalog.isSpeechModelID(selectedVoiceResponseModel.id),
                  Self.shouldAttachScreenContext(to: transcript) else {
                return nil
            }
            return OpenClickyModelCatalog.voiceAnalysisModel(withID: selectedVoiceResponseModel.id).id
        }()
        var executionFields = voiceResponseExecutionFields(effectiveModelID: plannedVoiceAnalysisModelID)
        executionFields["transcriptLength"] = transcript.count
        let executionStartedAt = markRequestExecutionStarted(
            route: "voice.response",
            timing: timing,
            extra: executionFields
        )
        let requestID = timing?.requestID
        let completionToken = UUID()
        let completionState = OpenClickyRequestCompletionState()
        currentVoiceResponseRequestID = requestID
        currentVoiceResponseCompletionToken = completionToken
        currentVoiceResponseCancellationHandler = { [weak self] reason in
            guard let self, !completionState.didComplete else { return }
            completionState.didComplete = true
            var completionFields = self.voiceResponseExecutionFields(effectiveModelID: plannedVoiceAnalysisModelID)
            completionFields["cancelledAt"] = reason
            completionFields["audioPlaybackState"] = "interrupted"
            self.markRequestCompleted(
                route: "voice.response",
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "cancelled",
                extra: completionFields
            )
            if self.currentVoiceResponseCompletionToken == completionToken {
                self.currentVoiceResponseCancellationHandler = nil
                self.currentVoiceResponseRequestID = nil
                self.currentVoiceResponseCompletionToken = nil
            }
        }

        let responseTaskToken = UUID()
        currentResponseTaskToken = responseTaskToken
        currentResponseTask = Task {
            defer { self.clearCurrentResponseTask(ifMatches: responseTaskToken) }
            // Stay in processing (spinner) state — no streaming text displayed
            self.voiceState = .processing

            func completeRequest(status: String = "success", extra: [String: Any] = [:]) async {
                await MainActor.run {
                    guard !completionState.didComplete else { return }
                    completionState.didComplete = true
                    if self.currentVoiceResponseCompletionToken == completionToken {
                        self.currentVoiceResponseCancellationHandler = nil
                        self.currentVoiceResponseRequestID = nil
                        self.currentVoiceResponseCompletionToken = nil
                    }
                    self.scheduleVoiceResponseCaptionClear()
                    var completionFields = self.voiceResponseExecutionFields(effectiveModelID: plannedVoiceAnalysisModelID)
                    extra.forEach { completionFields[$0.key] = $0.value }
                    self.markRequestCompleted(
                        route: "voice.response",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: status,
                        extra: completionFields
                    )
                }
            }

            do {
                OpenClickyApplicationUsageLogStore.shared.recordFrontmostApplication(source: "voice_question")
                let historyForAPI = self.voiceConversationHistoryForAPI()

                // Circle-while-talking: if the user drew a freehand trail during
                // this PTT hold, always attach visual context (crop + full screen).
                let circleHandoff = await self.consumePendingCircleSelectHandoff(instruction: transcript)

                // Only attach screenshots when the utterance actually needs
                // visual context. Text-only turns should not pay the capture,
                // base64, upload, and vision-processing latency tax.
                let captureStartedAt = Date()
                let shouldAttachScreenContext = circleHandoff != nil || Self.shouldAttachScreenContext(
                    to: transcript,
                    recentConversationHistory: historyForAPI
                )
                let screenCaptures: [CompanionScreenCapture]
                if shouldAttachScreenContext {
                    screenCaptures = try await captureAllScreensForVoiceResponseIfAvailable()
                } else {
                    prewarmedScreenshotTask?.cancel()
                    prewarmedScreenshotTask = nil
                    prewarmedScreenshotStartedAt = nil
                    screenCaptures = []
                }
                let cameraFrame = await captureCameraFrameForVoiceResponseIfAvailable(transcript: transcript)
                self.markRequestStageCompleted(
                    route: "voice.response",
                    stage: "screen_capture",
                    stageStartedAt: captureStartedAt,
                    timing: timing,
                    extra: [
                        "executor": "screen_capture",
                        "executionMethod": shouldAttachScreenContext ? "captureAllScreensForVoiceResponseIfAvailable" : "skipped_text_only_turn",
                        "controller": "ScreenCaptureKit",
                        "screenContextNeeded": shouldAttachScreenContext,
                        "screenCount": screenCaptures.count,
                        "circleSelectAttached": circleHandoff != nil,
                        "cameraContextAttached": cameraFrame != nil,
                        "imageBytes": screenCaptures.reduce(0) { $0 + $1.imageData.count }
                            + (circleHandoff?.imageData.count ?? 0)
                            + (cameraFrame?.data.count ?? 0)
                    ]
                )

                guard !Task.isCancelled else {
                    await completeRequest(status: "cancelled", extra: ["cancelledAt": "after_screen_capture"])
                    return
                }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                var labeledImages: [(data: Data, label: String)] = []
                if let circleHandoff {
                    let rect = circleHandoff.selection.captureRect
                    labeledImages.append((
                        data: circleHandoff.imageData,
                        label: "circled region crop (primary focus; \(Int(rect.width))x\(Int(rect.height)) pt) — user freehand-selected this area while speaking"
                    ))
                }
                labeledImages.append(contentsOf: screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                })
                if let cameraFrame {
                    labeledImages.append((data: cameraFrame.data, label: cameraFrame.label))
                }

                let userPromptForClaude: String
                if labeledImages.isEmpty {
                    userPromptForClaude = "\(transcript)\n\nNo screenshot is available. Answer from the transcript only and use [POINT:none]."
                } else if let circleHandoff {
                    let note = circleHandoff.selection.ambientSummary.isEmpty
                        ? "The user circled a screen region while speaking. The first image is the cropped circled area; following images show broader screen context."
                        : "The user circled a screen region while speaking. The first image is the cropped circled area; following images show broader screen context.\n\(circleHandoff.selection.ambientSummary)"
                    userPromptForClaude = "\(transcript)\n\n\(note)"
                } else {
                    userPromptForClaude = transcript
                }

                let hasVisualContext = !labeledImages.isEmpty
                let isRealtimeResponseModel = OpenClickyModelCatalog.isSpeechModelID(self.selectedModel)
                let visualAnalysisModelID = isRealtimeResponseModel && hasVisualContext
                    ? OpenClickyModelCatalog.voiceAnalysisModel(withID: self.selectedModel).id
                    : self.selectedModel

                // Realtime speech turns are audio-first. They do not currently
                // carry OpenClicky's screenshot payload into the response model,
                // so visual requests must continue through the screenshot-aware
                // voice path below. The playback engine can still be Realtime.
                if isRealtimeResponseModel && !hasVisualContext {
                    let realtimeStartedAt = Date()
                    var didMarkRealtimeAudioStarted = false
                    let realtimeText = try await self.openAIRealtimeSpeechClient.speakResponse(
                        systemPrompt: currentRealtimeVoiceSystemPrompt(),
                        conversationHistory: historyForAPI,
                        userPrompt: userPromptForClaude,
                        onTextChunk: { accumulatedText in
                            let trimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            self.latestVoiceResponseCard = ClickyResponseCard(
                                source: .voice,
                                rawText: trimmed,
                                contextTitle: transcript
                            )
                            self.updateVoiceResponseCaption(trimmed)
                        },
                        onPlaybackStarted: {
                            guard !didMarkRealtimeAudioStarted else { return }
                            didMarkRealtimeAudioStarted = true
                            self.voiceState = .responding
                            self.markRequestStageCompleted(
                                route: "voice.response",
                                stage: "tts_audio_started",
                                stageStartedAt: realtimeStartedAt,
                                timing: timing,
                                extra: [
                                    "executor": "realtime_voice",
                                    "executionMethod": "OpenAIRealtimeSpeechClient.speakResponse",
                                    "controller": "OpenAIRealtimeSpeechClient",
                                    "speechModel": self.selectedModel,
                                    "speechVoice": self.openAIRealtimeSpeechClient.voiceID
                                ]
                            )
                        }
                    )
                    let spokenText = realtimeText.isEmpty ? "Done." : realtimeText
                    self.markRequestStageCompleted(
                        route: "voice.response",
                        stage: "model_response",
                        stageStartedAt: realtimeStartedAt,
                        timing: timing,
                        extra: {
                            var fields = self.voiceResponseExecutionFields()
                            fields["responseLength"] = spokenText.count
                            fields["imageCount"] = labeledImages.count
                            fields["realtimeResponseModelOverride"] = true
                            return fields
                        }()
                    )

                    self.rememberVoiceExchange(
                        userTranscript: transcript,
                        assistantResponse: spokenText,
                        reason: "realtime_response"
                    )
                    do {
                        try codexHomeManager.appendPersistentMemoryEvent(
                            userRequest: transcript,
                            agentResponse: spokenText
                        )
                    } catch {
                        print("⚠️ OpenClicky memory update failed: \(error)")
                    }
                    ClickyAnalytics.trackAIResponseReceived(response: spokenText)
                    self.latestVoiceResponseCard = ClickyResponseCard(
                        source: .voice,
                        rawText: spokenText,
                        contextTitle: transcript
                    )
                    self.updateVoiceResponseCaption(spokenText)
                    self.scheduleWidgetSnapshotPublish()
                    self.pendingAgentOfferInstruction = nil
                    self.pendingAgentOfferAt = nil
                    await completeRequest(extra: [
                        "audioPlaybackState": "finished",
                        "realtimeResponseModelOverride": true
                    ])
                    return
                }

                // Only use a pre-response filler when it is buying real
                // latency cover. For text-only Haiku turns the logs show
                // first audio is already ~1s away, and prepended phrases
                // sound unnatural on short replies ("one moment. sounds
                // good..."). Screen/visual turns still benefit from a
                // neutral filler while capture + vision processing happens.
                let shouldUseFiller = Self.shouldUsePreResponseFiller(
                    transcript: transcript,
                    screenContextNeeded: hasVisualContext,
                    modelProvider: OpenClickyModelCatalog.voiceResponseModel(withID: visualAnalysisModelID).provider,
                    ttsProvider: self.selectedTTSProvider
                )
                let chosenFiller = shouldUseFiller
                    ? FillerPhraseLibrary.shared.contextualFiller(
                        for: transcript,
                        screenContextNeeded: hasVisualContext
                    )
                    : nil
                let voiceSystemPrompt: String = {
                    let base = currentVoiceResponseSystemPrompt()
                    guard let chosenFiller else { return base }
                    return base + """


                    OPENER ALREADY SPOKEN:
                    The user has already heard you say: "\(chosenFiller.phrase)" — that audio plays the instant they release the push-to-talk key, before you have produced a single token. Your reply will be appended directly after it, so write a NATURAL CONTINUATION:
                    - Do NOT repeat or paraphrase the opener (no "one moment", "give me a second", "let me check", "take a look", "that makes sense", "working on it", "checking now", "okay", "alright", "got it", "let's see").
                    - Start with the substance, not a greeting. The first words you generate should be the next words the user hears after the opener.
                    """
                }()

                let modelStartedAt = Date()
                var modelResponseFields = self.voiceResponseExecutionFields(
                    effectiveModelID: visualAnalysisModelID == self.selectedModel ? nil : visualAnalysisModelID
                )
                if visualAnalysisModelID != self.selectedModel {
                    modelResponseFields["visualAnalysisModel"] = visualAnalysisModelID
                    modelResponseFields["realtimeVisualPathOverride"] = true
                }
                let ttsStartedAt = Date()
                var didMarkAudioStarted = false

                // Open a sentence-pipelined TTS session BEFORE the LLM
                // call starts. As tokens arrive, we push deltas to the
                // session, which fires per-sentence TTS requests in
                // parallel and plays them in order. First audio reaches
                // the speaker as soon as the FIRST sentence completes,
                // not after the whole response.
                let streamingTTSSession = self.voiceTTSClient.beginStreamingResponse {
                    guard !didMarkAudioStarted else { return }
                    didMarkAudioStarted = true
                    self.voiceState = .responding
                    self.markRequestStageCompleted(
                        route: "voice.response",
                        stage: "tts_audio_started",
                        stageStartedAt: ttsStartedAt,
                        timing: timing,
                        extra: [
                            "executor": "tts",
                            "executionMethod": self.activeTTSExecutionMethodBeginStreaming,
                            "controller": self.activeTTSControllerName,
                            "preResponseFillerUsed": chosenFiller != nil,
                            "preResponseFillerPhrase": chosenFiller?.phrase ?? "",
                            "preResponseFillerDelayMs": chosenFiller == nil
                                ? 0
                                : StreamingTTSSession.preResponseFillerDelayMilliseconds
                        ]
                    )
                }

                // Schedule the pre-baked filler after a short natural
                // thinking beat. The first LLM sentence enqueues behind
                // it via the chain ordering, so the user hears the filler
                // at roughly 300-500ms, then the substantive continuation.
                // The system prompt was already augmented above with the
                // exact text of this filler so Haiku's reply continues
                // from it instead of restarting.
                if let chosenFiller {
                    streamingTTSSession.enqueuePrebakedSamples(chosenFiller.samples)
                }

                // Track the cumulative spoken text we've already pushed
                // into the TTS pipeline. We only emit a delta when the
                // newly-parsed safe-spoken text strictly extends what
                // we've emitted — never re-emit, never speak retracted
                // text (e.g. when a `[POINT:...]` tag completes mid-
                // stream and the parser strips it).
                var emittedSpokenSoFar = ""
                // Throttle the response-card publish so we don't re-render
                // SwiftUI on every LLM token (which can be 10+ per second).
                // Each publish hits the main actor, contending with the
                // cursor-tracking timer and audio scheduler. 100ms cadence
                // is plenty for visible "live caption" feedback.
                var lastCardPublishedAt: Date = .distantPast
                let cardPublishInterval: TimeInterval = 0.1
                // Build the assistant prefill so Haiku's reply continues
                // from the spoken filler at the autoregressive level
                // (Anthropic-only; OpenAI/Codex paths fall back to the
                // system-prompt directive). We keep the prefill trimmed
                // for Anthropic's assistant-prefix rules, then rejoin it
                // with the continuation when building local display text.
                //
                // The streamed `accumulatedText` we get back from the
                // Claude API path is ONLY the continuation; the prefill
                // is not echoed. That matches our pipeline exactly: the
                // filler is already playing from the pre-baked PCM, so
                // we only want to push the continuation through the
                // sentence-streaming TTS. The prefill text is folded
                // back into `fullResponseText` AFTER streaming so logs
                // and conversation history record the complete utterance.
                let assistantPrefillText: String? = chosenFiller.map {
                    $0.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let continuationText = try await analyzeVoiceResponse(
                    images: labeledImages,
                    modelID: visualAnalysisModelID,
                    systemPrompt: voiceSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: userPromptForClaude,
                    assistantPrefill: assistantPrefillText,
                    onTextChunk: { accumulatedText in
                        let parsedSpoken = Self.parsePointingCoordinates(from: accumulatedText).spokenText
                        let trimmed = parsedSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            let now = Date()
                            if now.timeIntervalSince(lastCardPublishedAt) >= cardPublishInterval {
                                lastCardPublishedAt = now
                                // Prepend the filler text so the card
                                // matches what the user actually hears
                                // (cached filler PCM plays before the
                                // continuation).
                                let displayed: String
                                if let prefill = assistantPrefillText {
                                    displayed = Self.combinedVoiceResponseText(
                                        prefill: prefill,
                                        continuation: trimmed
                                    )
                                } else {
                                    displayed = trimmed
                                }
                                self.latestVoiceResponseCard = ClickyResponseCard(
                                    source: .voice,
                                    rawText: displayed,
                                    contextTitle: transcript
                                )
                                self.updateVoiceResponseCaption(displayed)
                            }
                        }

                        // Strip a trailing partial visual-guidance tag so we
                        // never push "[POI", "[RECT", or "[SCRIBBLE" into TTS.
                        let safeSpoken = Self.stripTrailingVisualGuidanceTagFragment(parsedSpoken)

                        guard safeSpoken.hasPrefix(emittedSpokenSoFar),
                              safeSpoken.count > emittedSpokenSoFar.count else {
                            return
                        }
                        let delta = String(safeSpoken.dropFirst(emittedSpokenSoFar.count))
                        emittedSpokenSoFar = safeSpoken
                        streamingTTSSession.appendText(delta)
                    }
                )
                // Reassemble the full utterance: filler text (already
                // spoken from cached PCM) + Claude's continuation.
                // Used for [POINT:...] parsing, conversation history,
                // and logging. Without this, the next turn's history
                // would be missing the opener and Claude would drift.
                let fullResponseText: String = {
                    if let prefill = assistantPrefillText, !prefill.isEmpty {
                        return Self.combinedVoiceResponseText(
                            prefill: prefill,
                            continuation: continuationText
                        )
                    }
                    return continuationText
                }()
                self.markRequestStageCompleted(
                    route: "voice.response",
                    stage: "model_response",
                    stageStartedAt: modelStartedAt,
                    timing: timing,
                    extra: {
                        modelResponseFields["responseLength"] = fullResponseText.count
                        modelResponseFields["imageCount"] = labeledImages.count
                        modelResponseFields["assistantPrefillUsed"] = assistantPrefillText != nil
                        modelResponseFields["preResponseFillerUsed"] = chosenFiller != nil
                        modelResponseFields["preResponseFillerPhrase"] = chosenFiller?.phrase ?? ""
                        modelResponseFields["preResponseFillerDelayMs"] = chosenFiller == nil
                            ? 0
                            : StreamingTTSSession.preResponseFillerDelayMilliseconds
                        return modelResponseFields
                    }()
                )

                guard !Task.isCancelled else {
                    await completeRequest(status: "cancelled", extra: ["cancelledAt": "after_model_response"])
                    return
                }

                // Parse the visual guidance tag from Claude's response.
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                if self.autoEscalateVoiceResponseToAgentIfNeeded(
                    responseText: spokenText,
                    transcript: transcript,
                    source: "voice_response"
                ) {
                    streamingTTSSession.cancel()
                    await completeRequest(
                        status: "cancelled",
                        extra: [
                            "cancelledAt": "auto_escalated_to_agent",
                            "autoEscalatedToAgent": true
                        ]
                    )
                    return
                }

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasVisualGuidance = parseResult.coordinate != nil || parseResult.visualOverlay != nil
                if hasVisualGuidance {
                    self.voiceState = .idle
                }

                // Pick the screen capture for the buddy to point on.
                //
                // Resolution order:
                //   1. If Claude returned a screenNumber tag, trust it —
                //      that's a deliberate signal that the element lives on
                //      that specific screen. Honor it even when the cursor
                //      is on a different display (the user may have looked
                //      at screen 2 while the cursor stayed on screen 1).
                //   2. If no screenNumber, use the cursor's current screen
                //      (re-read live, not the stale `isCursorScreen` flag
                //      from capture time — Claude can take several seconds
                //      to respond and the user may have moved in that window).
                //   3. Last resort: the captured `isCursorScreen` flag.
                //
                // Earlier versions of this logic preferred the cursor screen
                // even when Claude returned screenNumber, which broke the
                // common "Claude correctly identified an element on the
                // other screen" case. The current logic keeps the live-cursor
                // benefit when Claude *didn't* tag a screen, and trusts
                // Claude when it did.
                let liveMouseLocation = NSEvent.mouseLocation
                let liveCursorCapture = screenCaptures.first { capture in
                    capture.displayFrame.contains(liveMouseLocation)
                }
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return liveCursorCapture
                        ?? screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let calibrationOffset = Self.visualGuidanceCalibrationOffset(for: displayFrame)
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    ).applying(
                        CGAffineTransform(
                            translationX: calibrationOffset.width,
                            y: calibrationOffset.height
                        )
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    detectedElementBubbleText = Self.pointingBubbleText(for: parseResult.elementLabel)
                    rememberPointedElement(
                        at: globalLocation,
                        displayFrame: displayFrame,
                        label: parseResult.elementLabel
                    )
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else if let visualOverlay = parseResult.visualOverlay,
                          let targetScreenCapture {
                    self.showVisualGuidanceOverlay(
                        self.globalVisualGuidanceOverlay(
                            fromScreenshotOverlay: visualOverlay,
                            in: targetScreenCapture
                        ),
                        sourceCapture: targetScreenCapture
                    )
                    print("🎯 Visual guidance overlay: \(visualOverlay.kind.rawValue) → \"\(parseResult.elementLabel ?? "overlay")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                    await attemptProactiveElementPointingIfUseful(
                        transcript: transcript,
                        spokenText: spokenText,
                        screenCaptures: screenCaptures
                    )
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                self.rememberVoiceExchange(
                    userTranscript: transcript,
                    assistantResponse: spokenText,
                    reason: "voice_response"
                )

                print("🧠 Conversation history: \(self.conversationHistory.count) active exchanges")
                do {
                    try codexHomeManager.appendPersistentMemoryEvent(
                        userRequest: transcript,
                        agentResponse: spokenText
                    )
                } catch {
                    print("⚠️ OpenClicky memory update failed: \(error)")
                }

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)
                self.latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: spokenText,
                    contextTitle: transcript
                )
                self.updateVoiceResponseCaption(spokenText)
                self.scheduleWidgetSnapshotPublish()

                // If Haiku just offered to spin up an agent, remember
                // the user's transcript as the candidate task so a
                // confirmation on the next turn ("yes", "okay then")
                // can actually spawn an agent. Otherwise clear any
                // stale offer so a much-later "yes" doesn't suddenly
                // launch unrelated work.
                if Self.responseOffersAgentSpawn(spokenText) {
                    self.pendingAgentOfferInstruction = transcript
                    self.pendingAgentOfferAt = Date()
                } else {
                    self.pendingAgentOfferInstruction = nil
                    self.pendingAgentOfferAt = nil
                }

                // The streaming TTS session has already been speaking
                // sentences as the LLM generated them. We just need to
                // flush whatever's left in the pending buffer (e.g. a
                // tail with no sentence terminator) and wait for the
                // last sentence to finish playing before marking the
                // request done.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Sync the session's view of "what was spoken" to the
                    // final parsed text. If the parser stripped a POINT
                    // tag at the end, our streaming-time emit may have
                    // stopped a few characters short — push the remainder
                    // here so finish() flushes the full sentence.
                    //
                    // `emittedSpokenSoFar` only contains the LLM
                    // continuation (the filler is enqueued separately
                    // as pre-baked PCM and never goes through
                    // streamingTTSSession.appendText), so we compare
                    // against the continuation portion of spokenText —
                    // i.e. spokenText with the prefill prefix stripped.
                    let continuationSpoken: String
                    if assistantPrefillText != nil {
                        continuationSpoken = Self.parsePointingCoordinates(from: continuationText).spokenText
                    } else {
                        continuationSpoken = spokenText
                    }
                    if continuationSpoken.hasPrefix(emittedSpokenSoFar),
                       continuationSpoken.count > emittedSpokenSoFar.count {
                        let tailDelta = String(continuationSpoken.dropFirst(emittedSpokenSoFar.count))
                        emittedSpokenSoFar = continuationSpoken
                        streamingTTSSession.appendText(tailDelta)
                    }

                    do {
                        try await streamingTTSSession.finish()
                        guard !Task.isCancelled else {
                            await completeRequest(
                                status: "cancelled",
                                extra: [
                                    "cancelledAt": "after_tts_finish",
                                    "spokenTextLength": spokenText.count,
                                    "pointed": parseResult.coordinate != nil,
                                    "audioPlaybackState": Self.voiceResponseCompletionAudioPlaybackState(
                                        spokenText: spokenText,
                                        playbackFinished: false
                                    )
                                ]
                            )
                            return
                        }
                        self.markRequestStageCompleted(
                            route: "voice.response",
                            stage: "tts_playback_finished",
                            stageStartedAt: ttsStartedAt,
                            timing: timing,
                            extra: [
                                "executor": "tts",
                                "executionMethod": "StreamingTTSSession.finish",
                                "controller": self.activeTTSControllerName,
                                "spokenTextLength": spokenText.count
                            ]
                        )
                    } catch {
                        guard !Self.isExpectedCancellation(error) else {
                            await completeRequest(
                                status: "cancelled",
                                extra: [
                                    "cancelledAt": "tts",
                                    "spokenTextLength": spokenText.count,
                                    "pointed": parseResult.coordinate != nil,
                                    "audioPlaybackState": Self.voiceResponseCompletionAudioPlaybackState(
                                        spokenText: spokenText,
                                        playbackFinished: false
                                    )
                                ]
                            )
                            return
                        }
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs streaming TTS error: \(error)")
                        speakResponseFailureFallback(error)
                        self.markRequestStageCompleted(
                            route: "voice.response",
                            stage: didMarkAudioStarted ? "tts_playback_finished" : "tts_audio_started",
                            stageStartedAt: ttsStartedAt,
                            timing: timing,
                            status: "failed",
                            extra: [
                                "executor": "tts",
                                "executionMethod": "StreamingTTSSession.finish",
                                "controller": self.activeTTSControllerName,
                                "error": error.localizedDescription
                            ]
                        )
                    }
                } else {
                    // No spoken text — discard the streaming session so
                    // its engine tears down cleanly.
                    streamingTTSSession.cancel()
                }
                var completionFields = self.voiceResponseExecutionFields(
                    effectiveModelID: visualAnalysisModelID == self.selectedModel ? nil : visualAnalysisModelID
                )
                completionFields["spokenTextLength"] = spokenText.count
                completionFields["pointed"] = parseResult.coordinate != nil
                let audioPlaybackState = Self.voiceResponseCompletionAudioPlaybackState(
                    spokenText: spokenText,
                    playbackFinished: true,
                    audioStarted: didMarkAudioStarted
                )
                completionFields["audioPlaybackState"] = audioPlaybackState
                if audioPlaybackState == "never_started" {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice",
                        direction: "internal",
                        event: "voice.response.audio_never_started",
                        fields: [
                            "transcript": transcript,
                            "spokenTextLength": spokenText.count,
                            "controller": self.activeTTSControllerName,
                            "requestID": timing?.requestID ?? "none"
                        ]
                    )
                    self.latestVoiceResponseCard = ClickyResponseCard(
                        source: .voice,
                        rawText: spokenText,
                        contextTitle: transcript
                    )
                    self.updateVoiceResponseCaption(spokenText, force: true)
                }
                await completeRequest(extra: completionFields)
            } catch is CancellationError {
                // User spoke again — response was interrupted
                await completeRequest(status: "cancelled", extra: ["cancelledAt": "task"])
            } catch where Self.isExpectedCancellation(error) {
                // User spoke again — URLSession/AVFoundation surfaced cancellation as NSError.
                await completeRequest(status: "cancelled", extra: ["cancelledAt": "task"])
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "incoming",
                    event: "voice.response_error",
                    fields: [
                        "transcript": transcript,
                        "error": error.localizedDescription
                    ]
                )
                speakResponseFailureFallback(error)
                await completeRequest(
                    status: "failed",
                    extra: [
                        "error": error.localizedDescription
                    ]
                )
            }

            if !Task.isCancelled {
                self.lastVoiceInteractionCompletedAt = Date()
                self.voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    func startTutorIdleObservation() {
        userActivityIdleDetector.start()
        bindTutorIdleObservation()
    }

    func stopTutorIdleObservation() {
        tutorIdleCancellable?.cancel()
        tutorIdleCancellable = nil
        userActivityIdleDetector.stop()
        tutorTargetClickTracker.disarm()
        isTutorObservationInFlight = false
    }

    private func bindTutorIdleObservation() {
        tutorIdleCancellable?.cancel()
        tutorIdleCancellable = userActivityIdleDetector.$isUserIdle
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self,
                      self.isTutorModeEnabled,
                      self.voiceState == .idle,
                      !self.voiceTTSClient.isPlaying,
                      !self.isTutorObservationInFlight,
                      Date().timeIntervalSince(self.lastVoiceInteractionCompletedAt) >= Self.tutorObservationVoiceCooldown else { return }

                self.isTutorObservationInFlight = true
                Task {
                    await self.performTutorObservation()
                    self.userActivityIdleDetector.observationDidComplete()
                    self.isTutorObservationInFlight = false
                }
            }
    }

    private func performTutorObservation() async {
        do {
            tutorTargetClickTracker.disarm()
            ensureCursorOverlayVisibleForAgentTask()
            voiceState = .processing

            let screenCaptures = try await CompanionScreenCaptureUtility.captureFocusedWindowAsJPEG()
            let labeledImages = screenCaptures.map { capture in
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                return (data: capture.imageData, label: capture.label + dimensionInfo)
            }
            let historyForAPI = voiceConversationHistoryForAPI()

            let fullResponseText = try await analyzeVoiceResponse(
                images: labeledImages,
                systemPrompt: self.currentTutorModeSystemPrompt(),
                conversationHistory: historyForAPI,
                userPrompt: "observe the focused window and guide me to the next useful learning step.",
                onTextChunk: { _ in }
            )

            let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
            let spokenText = parseResult.spokenText

            if let pointCoordinate = parseResult.coordinate,
               let targetScreenCapture = tutorTargetScreenCapture(from: screenCaptures, screenNumber: parseResult.screenNumber) {
                let globalLocation = globalPoint(
                    fromScreenshotPoint: pointCoordinate,
                    in: targetScreenCapture
                )
                voiceState = .idle
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = targetScreenCapture.displayFrame
                detectedElementBubbleText = Self.pointingBubbleText(for: parseResult.elementLabel)
                rememberPointedElement(
                    at: globalLocation,
                    displayFrame: targetScreenCapture.displayFrame,
                    label: parseResult.elementLabel
                )
                armTutorTargetClickTracking(
                    at: globalLocation,
                    displayFrame: targetScreenCapture.displayFrame,
                    label: parseResult.elementLabel
                )
                ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                print("Tutor pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y)))")
            }

            rememberVoiceExchange(
                userTranscript: "[tutor observation]",
                assistantResponse: spokenText,
                reason: "tutor_observation"
            )

            if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await voiceTTSClient.speakText(spokenText) {
                    self.voiceState = .responding
                }
            }
        } catch is CancellationError {
            // A normal voice interaction interrupted the tutor observation.
        } catch where Self.isExpectedCancellation(error) {
            // A normal voice interaction interrupted the tutor observation.
        } catch {
            print("Tutor observation error: \(error)")
        }

        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func armTutorTargetClickTracking(at point: CGPoint, displayFrame: CGRect?, label: String?) {
        guard isTutorModeEnabled else { return }
        tutorTargetClickTracker.arm(targetPoint: point, targetRect: nil) { [weak self] clickPoint in
            guard let self else { return }
            self.lastVoiceInteractionCompletedAt = .distantPast
            self.userActivityIdleDetector.recordTutorStepCompleted()
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "incoming",
                event: "tutor.target_clicked",
                fields: [
                    "label": label ?? "",
                    "targetX": Int(point.x),
                    "targetY": Int(point.y),
                    "clickX": Int(clickPoint.x),
                    "clickY": Int(clickPoint.y),
                    "displayFrame": displayFrame.map { frame in
                        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
                    } ?? ""
                ]
            )
        }
    }

    private func tutorTargetScreenCapture(from screenCaptures: [CompanionScreenCapture], screenNumber: Int?) -> CompanionScreenCapture? {
        // Resolution order:
        //   1. If Claude returned a screenNumber tag, trust it — that's a
        //      deliberate signal about which screen the element lives on.
        //   2. Otherwise, fall back to the cursor's live current screen
        //      (re-read so we don't use a stale `isCursorScreen` flag from
        //      capture time).
        //   3. Last resort: the captured `isCursorScreen` flag.
        if let screenNumber,
           screenNumber >= 1,
           screenNumber <= screenCaptures.count {
            return screenCaptures[screenNumber - 1]
        }

        let liveMouseLocation = NSEvent.mouseLocation
        let liveCursorCapture = screenCaptures.first { $0.displayFrame.contains(liveMouseLocation) }

        return liveCursorCapture
            ?? screenCaptures.first(where: { $0.isCursorScreen })
            ?? screenCaptures.first
    }

    func globalPoint(
        fromScreenshotPoint point: CGPoint,
        in capture: CompanionScreenCapture,
        applyingCalibration: Bool = true
    ) -> CGPoint {
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let clampedX = max(0, min(point.x, screenshotWidth))
        let clampedY = max(0, min(point.y, screenshotHeight))
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let calibrationOffset = applyingCalibration
            ? Self.visualGuidanceCalibrationOffset(for: capture.displayFrame)
            : .zero
        return CGPoint(
            x: displayLocalX + capture.displayFrame.origin.x,
            y: (displayHeight - displayLocalY) + capture.displayFrame.origin.y
        ).applying(
            CGAffineTransform(
                translationX: calibrationOffset.width,
                y: calibrationOffset.height
            )
        )
    }

    private func globalRect(
        fromScreenshotRect rect: CGRect,
        in capture: CompanionScreenCapture,
        applyingCalibration: Bool = true
    ) -> CGRect {
        let origin = globalPoint(fromScreenshotPoint: rect.origin, in: capture, applyingCalibration: applyingCalibration)
        let opposite = globalPoint(fromScreenshotPoint: CGPoint(x: rect.maxX, y: rect.maxY), in: capture, applyingCalibration: applyingCalibration)
        return CGRect(
            x: min(origin.x, opposite.x),
            y: min(origin.y, opposite.y),
            width: abs(opposite.x - origin.x),
            height: abs(opposite.y - origin.y)
        )
    }

    private func globalVisualGuidanceOverlay(
        fromScreenshotOverlay overlay: OpenClickyVisualGuidanceOverlay,
        in capture: CompanionScreenCapture
    ) -> OpenClickyVisualGuidanceOverlay {
        switch overlay.kind {
        case .scribble:
            return OpenClickyVisualGuidanceOverlay.scribble(
                points: overlay.points.map { globalPoint(fromScreenshotPoint: $0.cgPoint, in: capture) },
                accentHex: overlay.style.accentHex,
                lineWidth: overlay.style.lineWidth,
                caption: overlay.style.caption,
                duration: overlay.duration
            )
        case .rectangle:
            guard let rect = overlay.rect else {
                return overlay
            }
            let isCalibrationAnchor = Self.isVisualGuidanceCalibrationCaption(overlay.style.caption)
            return OpenClickyVisualGuidanceOverlay.rectangle(
                rect: globalRect(
                    fromScreenshotRect: rect.cgRect,
                    in: capture,
                    applyingCalibration: !isCalibrationAnchor
                ),
                accentHex: overlay.style.accentHex,
                lineWidth: overlay.style.lineWidth,
                fillOpacity: overlay.style.fillOpacity,
                caption: overlay.style.caption,
                duration: overlay.duration
            )
        }
    }

    func analyzeVisualWorkspace(
        images: [(data: Data, label: String)],
        userPrompt: String,
        source: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let modelID = OpenClickyModelCatalog.voiceAnalysisModel(withID: selectedModel).id

        OpenClickyMessageLogStore.shared.append(
            lane: "visual",
            direction: "outgoing",
            event: "visual.workspace.request",
            fields: [
                "source": source,
                "model": modelID,
                "imageCount": images.count,
                "promptLength": userPrompt.count
            ]
        )

        let systemPrompt = """
        You are OpenClicky's Visual Intelligence workspace. Analyze attached camera and screen images carefully and answer the user's prompt.

        Capabilities to apply when relevant:
        - identify objects, products, devices, people-present/not-present, scene, setting, actions, and situations.
        - scan and transcribe visible text, labels, prices, dates, codes, warnings, UI text, document snippets, and important information.
        - infer useful lookup/search terms for visible objects, logos, documents, books, products, or places. Do not claim live web browsing unless a separate Agent Mode task actually performed it.
        - call out uncertainty, ambiguous visual evidence, and what detail would verify an identification.

        Output style:
        - concise markdown is allowed.
        - no [POINT] tags, no hidden routing syntax, no spoken-TTS constraints.
        - prioritize details that help the user act now.
        """

        return try await analyzeVoiceResponse(
            images: images,
            modelID: modelID,
            systemPrompt: systemPrompt,
            conversationHistory: [],
            userPrompt: userPrompt,
            assistantPrefill: nil,
            onTextChunk: onTextChunk
        )
    }

    func analyzeVoiceResponse(
        images: [(data: Data, label: String)],
        modelID: String? = nil,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        assistantPrefill: String? = nil,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let requestedModelID = modelID ?? selectedModel
        let selectedVoiceResponseModel = OpenClickyModelCatalog.isSpeechModelID(requestedModelID)
            ? OpenClickyModelCatalog.voiceAnalysisModel(withID: requestedModelID)
            : OpenClickyModelCatalog.voiceResponseModel(withID: requestedModelID)
        applyVoiceResponseModelSettings(selectedVoiceResponseModel)

        switch selectedVoiceResponseModel.provider {
        case .anthropic:
            return try await analyzeClaudeResponse(
                images: images,
                model: selectedVoiceResponseModel.id,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                assistantPrefill: assistantPrefill,
                onTextChunk: onTextChunk
            )
        case .openAI:
            // OpenAI Responses API uses a different shape — assistant
            // prefill is not supported the same way. The system-prompt
            // directive carries the constraint here.
            return try await analyzeOpenAIOrCodexVoiceResponse(
                images: images,
                model: selectedVoiceResponseModel.id,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        case .deepgram:
            throw NSError(
                domain: "DeepgramVoiceAgentClient",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "Deepgram Voice Agent handles live microphone turns directly; text/screenshot fallback should route through a normal response model."]
            )
        case .codex:
            return try await analyzeCodexVoiceResponse(
                images: images,
                model: selectedVoiceResponseModel.id,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        }
    }

    private func analyzeClaudeResponse(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        assistantPrefill: String? = nil,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        // Inference routing rule: Claude Agent SDK FIRST (uses the local
        // Claude Code sign-in the user already pays for), direct ClaudeAPI
        // HTTP only as fallback when the SDK is unavailable or throws.
        // Never short-circuit to HTTP for latency or capability reasons —
        // direct REST bills per token on the user's card.
        print("🧠 analyzeClaudeResponse: model=\(model) sdkAvailable=\(claudeAgentSDKAPI != nil) httpKey=\(AppBundleConfiguration.anthropicAPIKey() != nil) prefill=\(assistantPrefill?.isEmpty == false)")
        let modelOption = OpenClickyModelCatalog.voiceResponseModel(withID: model)

        if let claudeAgentSDKAPI {
            do {
                claudeAgentSDKAPI.model = modelOption.id
                claudeAgentSDKAPI.maxOutputTokens = modelOption.maxOutputTokens
                print("🧠 analyzeClaudeResponse: using Agent SDK bridge")
                let (text, _) = try await claudeAgentSDKAPI.analyzeImageStreaming(
                    images: images,
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: userPrompt,
                    // M16: forward prefill to the SDK (primary) path so it behaves
                    // like the HTTP fallback below.
                    assistantPrefill: assistantPrefill,
                    onTextChunk: onTextChunk
                )
                return text
            } catch is CancellationError {
                // Cancellation means the user interrupted the primary SDK path;
                // it is not an availability failure and must never trigger a
                // paid direct-HTTP fallback.
                throw CancellationError()
            } catch {
                guard AppBundleConfiguration.anthropicAPIKey() != nil else { throw error }
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "error",
                    event: "voice.response_fallback",
                    fields: [
                        "from": "claude_agent_sdk",
                        "to": "anthropic_api_key",
                        "error": error.localizedDescription
                    ]
                )
                print("🔁 analyzeClaudeResponse: Agent SDK failed, falling back to direct HTTP: \(error.localizedDescription)")
            }
        }

        if AppBundleConfiguration.anthropicAPIKey() != nil {
            claudeAPI.model = modelOption.id
            claudeAPI.maxOutputTokens = modelOption.maxOutputTokens
            print("🧠 analyzeClaudeResponse: using direct HTTP streaming (ClaudeAPI fallback)")
            let (text, _) = try await claudeAPI.analyzeImageStreaming(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                assistantPrefill: assistantPrefill,
                onTextChunk: onTextChunk
            )
            return text
        }

        print("❌ analyzeClaudeResponse: no SDK and no HTTP key — Claude not configured")
        throw NSError(
            domain: "ClaudeAgentSDKAPI",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Claude is not configured. Sign in to Claude Code locally or set an Anthropic API key."]
        )
    }

    private func analyzeOpenAIOrCodexVoiceResponse(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let modelOption = OpenClickyModelCatalog.voiceAnalysisModel(withID: model)
        if !OpenClickyModelCatalog.isSpeechModelID(modelOption.id) {
            do {
                return try await analyzeCodexVoiceResponse(
                    images: images,
                    model: modelOption.id,
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: userPrompt,
                    onTextChunk: onTextChunk
                )
            } catch {
                guard AppBundleConfiguration.openAIAPIKey() != nil else { throw error }
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "error",
                    event: "voice.response_fallback",
                    fields: [
                        "from": "codex_voice_session",
                        "to": "openai_api_key",
                        "model": modelOption.id,
                        "codexModel": OpenClickyModelCatalog.codexVoiceSessionModel(withID: modelOption.id).id,
                        "error": error.localizedDescription
                    ]
                )
            }
        }

        guard AppBundleConfiguration.openAIAPIKey() != nil else {
            throw NSError(
                domain: "OpenAIAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI is not configured for this voice analysis request."]
            )
        }

        openAIAPI.model = modelOption.id
        openAIAPI.maxOutputTokens = modelOption.maxOutputTokens
        let (text, _) = try await openAIAPI.analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
        return text
    }

    private func analyzeCodexVoiceResponse(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let modelOption = OpenClickyModelCatalog.codexVoiceSessionModel(withID: model)
        codexVoiceSession.model = modelOption.id
        let (text, _) = try await codexVoiceSession.analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
        return text
    }

    private static func shouldUsePreResponseFiller(
        transcript: String,
        screenContextNeeded: Bool,
        modelProvider: OpenClickyModelProvider,
        ttsProvider: OpenClickyTTSProvider
    ) -> Bool {
        let commandText = SpokenText.normalizedSpokenCommandText(transcript)
        let wordCount = commandText.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count

        // Never prepend filler to acknowledgements, corrections, or very
        // short replies. These are exactly the cases where the filler
        // sounds like Clicky is inventing work: "one moment. sounds good."
        if wordCount <= 4 { return false }
        let acknowledgementPhrases: Set<String> = [
            "yes", "yeah", "yep", "no", "nope", "ok", "okay",
            "alright", "all right", "sounds good", "thanks", "thank you",
            "continue", "go on", "stop", "cancel", "nevermind", "never mind"
        ]
        if acknowledgementPhrases.contains(commandText) { return false }

        // Do not put spoken filler in front of direct control commands.
        // Those turns should either execute immediately or produce a
        // concrete handoff/status, not "yeah, that makes sense."
        let directActionPrefixes = [
            "open ", "play ", "pause ", "click ", "press ", "type ",
            "select ", "scroll ", "switch ", "bring ", "move ",
            "close ", "quit ", "launch "
        ]
        if directActionPrefixes.contains(where: commandText.hasPrefix) {
            return false
        }

        // Speech-to-speech Realtime already provides its own immediate
        // audio path; adding cached TTS filler would create a double voice.
        if ttsProvider == .openAIRealtime {
            return false
        }

        // Deepgram Voice Agent owns the whole voice turn when selected as
        // the response model. If this path is reached for analysis only,
        // keep fillers off to avoid cross-provider audio seams.
        if modelProvider == .deepgram {
            return false
        }

        if screenContextNeeded {
            return true
        }

        // For Cartesia/ElevenLabs/Edge/Deepgram-TTS text turns, use a
        // cached opener only when the user has asked a real multi-word
        // question or investigation. Short acknowledgements stay crisp.
        switch ttsProvider {
        case .cartesia, .elevenLabs, .microsoftEdge, .deepgram:
            return wordCount >= 6
        case .openAIRealtime:
            return false
        }
    }

    private static let visualFollowUpHistoryDepth = 3

    static func shouldAttachScreenContext(
        to transcript: String,
        recentConversationHistory: [(userPlaceholder: String, assistantResponse: String)] = []
    ) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let commandText = SpokenText.normalizedSpokenCommandText(transcript)

        if shouldForceAgentClipboardSelection(for: transcript) {
            return true
        }

        if isVisualGuidanceDrawingRequest(normalized: normalized, commandText: commandText) {
            return true
        }

        let explicitVisualPhrases = [
            "my screen", "the screen", "on screen", "on the screen", "this screen",
            "start screen calibration", "begin screen calibration", "run screen calibration",
            "enter calibration mode", "calibration mode",
            "calibrate the screen", "calibrate screen", "calibrate this display",
            "calibrate our screens", "calibrate screens", "calibrate display",
            "screen calibration", "calibration anchor",
            "what am i looking", "what's on", "what is on", "what do you see",
            "look at", "take a look", "can you see", "do you see",
            "this window", "that window", "current window", "active window",
            "this app", "that app", "this page", "that page", "this button", "that button",
            "this field", "that field", "this menu", "that menu",
            "where is", "where's", "point to", "show me where", "highlight",
            "draw around", "draw round", "circle around", "circle round", "rectangle around",
            "rectangle round", "box around", "box round", "outline", "scribble", "trace",
            "selection around", "shape around", "shapes around", "logo",
            "layout", "spacing", "padding", "margin", "margins", "green symbol",
            "green mark",
            "click", "press", "select", "open this", "open that"
        ]
        if explicitVisualPhrases.contains(where: { normalized.contains($0) || commandText.contains($0) }) {
            return true
        }

        let visualTokens: Set<String> = [
            "screen", "window", "button", "field", "menu", "dialog", "popup",
            "page", "tab", "cursor", "visible", "shown", "displayed", "image",
            "screenshot", "icon", "link", "sidebar", "toolbar", "dock", "logo",
            "layout", "spacing", "padding", "margin", "margins", "size", "sized",
            "highlight", "rectangle", "rectangles", "circle", "circles",
            "shape", "shapes", "box", "outline", "scribble", "scribbles", "trace",
            "left", "right", "top", "bottom", "symbol", "green", "calibrate", "calibration"
        ]
        let tokens = commandText.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tokens.contains(where: { visualTokens.contains($0) }) { return true }

        let visualFollowUps: Set<String> = [
            "how about now",
            "what about now",
            "try again",
            "check again",
            "look again",
            "can you try again",
            "can you check again",
            "can you look again"
        ]
        if visualFollowUps.contains(commandText),
           recentConversationHistory
           .suffix(visualFollowUpHistoryDepth)
           .contains(where: { turn in
               let recentText = "\(turn.userPlaceholder) \(turn.assistantResponse)"
                   .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                   .lowercased()
               return explicitVisualPhrases.contains(where: recentText.contains)
                   || recentText
                   .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                   .contains(where: { visualTokens.contains(String($0)) })
           }) {
            return true
        }

        return false
    }

    static func isScreenCalibrationRequest(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let commandText = SpokenText.normalizedSpokenCommandText(transcript)
        let calibrationPhrases = [
            "start screen calibration", "begin screen calibration", "run screen calibration",
            "enter calibration mode", "calibration mode",
            "calibrate the screen", "calibrate screen", "calibrate this display",
            "calibrate our screens", "calibrate screens", "calibrate display",
            "screen calibration", "calibration anchor"
        ]
        return calibrationPhrases.contains { normalized.contains($0) || commandText.contains($0) }
    }

    private static func isVisualGuidanceDrawingRequest(normalized: String, commandText: String) -> Bool {
        let visualDrawPatterns = [
            #"\b(?:draw|put|place|add|show|make)\s+(?:a\s+|an\s+|the\s+)?(?:rectangle|rect|box|circle|oval|ring|outline|shape)\s+(?:around|round|over|on|onto)\b"#,
            #"\b(?:circle|box|outline|mark|highlight)\s+(?:the\s+|this\s+|that\s+|a\s+|an\s+)?[a-z0-9][a-z0-9\s-]{0,80}\b"#,
            #"\b(?:draw|trace|scribble)\s+(?:around|round|over|on|onto)\b"#
        ]

        for text in [normalized, commandText] {
            for pattern in visualDrawPatterns {
                if text.range(of: pattern, options: .regularExpression) != nil {
                    return true
                }
            }
        }

        return false
    }

    private static func shouldAttachCameraContext(to transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let commandText = SpokenText.normalizedSpokenCommandText(transcript)
        let cameraPhrases = [
            "camera", "webcam", "cam", "through the camera", "from the camera",
            "what am i holding", "what is this object", "what's this object",
            "what is in my hand", "what's in my hand", "on my desk", "behind me",
            "in the room", "in front of me", "scan this", "read this label",
            "look at this item", "identify this", "identify that", "what product is this"
        ]
        return cameraPhrases.contains { normalized.contains($0) || commandText.contains($0) }
    }

    private func captureCameraFrameForVoiceResponseIfAvailable(transcript: String) async -> OpenClickyCameraFrame? {
        let userEnabledCameraContext = UserDefaults.standard.bool(forKey: AppBundleConfiguration.userCameraVoiceContextEnabledDefaultsKey)
        guard userEnabledCameraContext || Self.shouldAttachCameraContext(to: transcript) else { return nil }
        do {
            return try await OpenClickyCameraCaptureController.shared.captureJPEGFrame(labelPrefix: "camera context")
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "error",
                event: "voice.camera_context_unavailable",
                fields: [
                    "error": error.localizedDescription,
                    "userEnabledCameraContext": userEnabledCameraContext
                ]
            )
            return nil
        }
    }

    func captureAllScreensForVoiceResponseIfAvailable() async throws -> [CompanionScreenCapture] {
        // Prefer the prewarmed capture started at keyDown if it's fresh.
        // Otherwise fall back to a synchronous capture so the AI still
        // gets a screenshot when the prewarm path was skipped (e.g. text
        // input, programmatic transcript).
        if let prewarmed = prewarmedScreenshotTask,
           let startedAt = prewarmedScreenshotStartedAt,
           Date().timeIntervalSince(startedAt) <= Self.prewarmedScreenshotMaxAge {
            prewarmedScreenshotTask = nil
            prewarmedScreenshotStartedAt = nil
            do {
                return try await prewarmed.value
            } catch {
                print("⚠️ Prewarmed screenshot failed, falling back to fresh capture: \(error)")
                return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            }
        }

        // Stale or missing prewarm — discard and capture fresh.
        prewarmedScreenshotTask?.cancel()
        prewarmedScreenshotTask = nil
        prewarmedScreenshotStartedAt = nil
        return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
    }

    /// Starts capturing a screenshot in parallel with audio recording.
    /// Called from `.pressed` so the JPEG-encoded captures are usually
    /// ready by the time the user releases the key. No-op when screen
    /// recording permission is missing — the response path falls back
    /// to text-only in that case.
    func startPrewarmedScreenshotCaptureIfPossible() {
        guard hasScreenContentPermission else { return }

        // Cancel any stale capture from a prior press that never landed
        // (e.g. user pressed and released without speaking).
        prewarmedScreenshotTask?.cancel()

        prewarmedScreenshotStartedAt = Date()
        prewarmedScreenshotTask = Task.detached(priority: .userInitiated) {
            try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        }
    }

    func analyzeComputerUsePointingResponse(
        image: (data: Data, label: String),
        capture: CompanionScreenCapture,
        systemPrompt: String,
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let selectedPointingModel = OpenClickyModelCatalog.computerUseModel(withID: selectedComputerUseModel)
        let resolver = Self.computerUsePointingResolver(
            selectedVoiceModelID: selectedModel,
            selectedComputerUseModelID: selectedComputerUseModel
        )

        switch resolver {
        case .openAIRealtime:
            let text = try await openAIRealtimeSpeechClient.analyzeImageResponse(
                images: [image],
                modelID: selectedPointingModel.id,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
            return text
        case .anthropicAPI:
            return try await analyzeClaudeResponse(
                images: [image],
                model: selectedPointingModel.id,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        case .codexCLI:
            let detector = CodexPointDetector(model: selectedPointingModel.id)
            let text = try await detector.detectPointTag(
                screenshotData: image.data,
                screenshotLabel: image.label,
                userQuestion: userPrompt,
                systemPrompt: systemPrompt,
                displayWidthInPixels: capture.screenshotWidthInPixels,
                displayHeightInPixels: capture.screenshotHeightInPixels
            )
            onTextChunk(text)
            return text
        case .openAIResponses:
            openAIAPI.model = selectedPointingModel.id
            let (text, _) = try await openAIAPI.analyzeImage(
                images: [image],
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
            onTextChunk(text)
            return text
        case .unsupported:
            throw NSError(
                domain: "OpenClickyComputerUsePointing",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "\(selectedPointingModel.id) is not a supported pointing model."]
            )
        }
    }

    static func computerUsePointingResolver(
        selectedVoiceModelID _: String,
        selectedComputerUseModelID: String
    ) -> OpenClickyComputerUsePointingResolver {
        let pointingModel = OpenClickyModelCatalog.computerUseModel(withID: selectedComputerUseModelID)
        if pointingModel.provider == .openAI,
           OpenClickyModelCatalog.isSpeechModelID(pointingModel.id) {
            return .openAIRealtime
        }

        switch pointingModel.provider {
        case .anthropic:
            return .anthropicAPI
        case .codex:
            return .codexCLI
        case .openAI:
            return .openAIResponses
        case .deepgram:
            return .unsupported
        }
    }

    static let nativeClickPointingSystemPrompt = """
    You are OpenClicky's visual click target resolver. The user wants OpenClicky to actually click in the visible app, not merely point or explain.

    Identify the single clickable UI element only when it visibly and directly matches the user's request. Do not choose unrelated, nearby, generic, decorative, or merely available controls. Return exactly one short phrase followed by one [POINT:x,y:label] tag. Use screenshot pixel coordinates with origin at the top-left. If there is no safe directly relevant matching target, return [POINT:none].
    """

    private func attemptProactiveElementPointingIfUseful(
        transcript: String,
        spokenText: String,
        screenCaptures: [CompanionScreenCapture]
    ) async {
        guard Self.shouldAttemptProactivePointing(for: transcript) else { return }
        guard let targetScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first else { return }

        let selectedPointingModel = OpenClickyModelCatalog.computerUseModel(withID: selectedComputerUseModel)
        let userQuestion = "\(transcript)\n\nOpenClicky's answer: \(spokenText)"
        let displayLocalLocation: CGPoint?

        switch selectedPointingModel.provider {
        case .anthropic:
            guard let anthropicAPIKey = AppBundleConfiguration.anthropicAPIKey() else { return }
            let detector = ElementLocationDetector(apiKey: anthropicAPIKey, model: selectedPointingModel.id)
            displayLocalLocation = await detector.detectElementLocation(
                screenshotData: targetScreenCapture.imageData,
                userQuestion: userQuestion,
                displayWidthInPoints: targetScreenCapture.displayWidthInPoints,
                displayHeightInPoints: targetScreenCapture.displayHeightInPoints
            )
        case .codex:
            let detector = CodexPointDetector(model: selectedPointingModel.id)
            displayLocalLocation = await detector.detectDisplayLocalPoint(
                screenshotData: targetScreenCapture.imageData,
                screenshotLabel: targetScreenCapture.label,
                userQuestion: userQuestion,
                displayWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
                displayHeightInPixels: targetScreenCapture.screenshotHeightInPixels,
                displayWidthInPoints: targetScreenCapture.displayWidthInPoints,
                displayHeightInPoints: targetScreenCapture.displayHeightInPoints
            )
        case .openAI, .deepgram:
            return
        }

        guard let displayLocalLocation else { return }

        let displayFrame = targetScreenCapture.displayFrame
        let globalLocation = CGPoint(
            x: displayLocalLocation.x + displayFrame.origin.x,
            y: displayLocalLocation.y + displayFrame.origin.y
        )

        voiceState = .idle
        detectedElementBubbleText = Self.shortPointingCaption(from: spokenText)
        detectedElementDisplayFrame = displayFrame
        detectedElementScreenLocation = globalLocation
        rememberPointedElement(at: globalLocation, displayFrame: displayFrame, label: "proactive")
        ClickyAnalytics.trackElementPointed(elementLabel: "proactive")
        print("🎯 Proactive element pointing: (\(Int(displayLocalLocation.x)), \(Int(displayLocalLocation.y)))")
    }

    private static func shouldAttemptProactivePointing(for transcript: String) -> Bool {
        let normalizedTranscript = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let normalizedCommandText = SpokenText.normalizedSpokenCommandText(transcript)

        let voiceStatusPhrases = [
            "can you hear",
            "hear me",
            "mic",
            "microphone",
            "not speaking",
            "speaking",
            "voice",
            "audio",
            "responding",
            "response",
            "slow",
            "taking so long",
            "lag"
        ]
        if voiceStatusPhrases.contains(where: { normalizedCommandText.contains($0) }) {
            return false
        }

        let screenRelatedPhrases = [
            "screen",
            "window",
            "button",
            "menu",
            "setting",
            "permission",
            "file",
            "folder",
            "tab",
            "click",
            "open",
            "where",
            "how do i",
            "what is this",
            "what's this",
            "this screen",
            "this window",
            "this button",
            "this menu",
            "this file",
            "this folder",
            "this tab",
            "this setting",
            "that screen",
            "that window",
            "that button",
            "that menu",
            "that file",
            "that folder",
            "that tab",
            "that setting",
            "right here",
            "over here",
            "up here",
            "down here",
            "what am i looking at",
            "show me",
            "point",
            "cursor"
        ]

        return screenRelatedPhrases.contains { normalizedTranscript.contains($0) }
    }

    static func pointingBubbleText(for elementLabel: String?) -> String {
        let trimmedLabel = elementLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedLabel.isEmpty else {
            return "right here"
        }
        return "right here: \(trimmedLabel)"
    }

    private static func shortPointingCaption(from spokenText: String) -> String {
        let flattenedText = spokenText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard flattenedText.count > 76 else {
            return flattenedText.isEmpty ? "right here" : flattenedText
        }

        let endIndex = flattenedText.index(flattenedText.startIndex, offsetBy: 76)
        let prefix = String(flattenedText[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "..."
        }
        return prefix + "..."
    }

    /// If the cursor is in transient mode (user toggled "Show OpenClicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while voiceTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Logs a response failure but stays SILENT. We never speak with
    /// the macOS system TTS — that introduces a second voice that the
    /// user doesn't recognize. Errors surface through logs and the
    /// response card; the agent simply doesn't speak this turn.
    func speakResponseFailureFallback(_ error: Error) {
        guard !Self.isExpectedCancellation(error) else { return }
        let message = userFacingResponseFailureMessage(for: error)
        print("⚠️ Voice response failure (silent — no system-voice fallback): \(message)")
        var fields: [String: Any] = [
            "error": error.localizedDescription,
            "message": message
        ]
        fields.merge(ttsFailureDiagnosticFields(for: error), uniquingKeysWith: { _, new in new })
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: "voice.response_failure_silent",
            fields: fields
        )
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: message,
            contextTitle: lastTranscript ?? ""
        )
    }

    static func isExpectedCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return true
        }

        let description = String(describing: error).lowercased()
        return description == "cancellationerror()" || description.contains("cancelled") || description.contains("canceled")
    }

    private func userFacingResponseFailureMessage(for error: Error) -> String {
        let nsError = error as NSError

        switch nsError.domain {
        case "ClaudeAPI":
            if nsError.code == -1000 {
                return "Anthropic is not configured. Set the Anthropic API key and relaunch."
            }
            return "Claude returned an error. Check the app log for the exact response."
        case "ElevenLabsTTS":
            return "Voice playback failed, but the Claude response completed. Check the app log for the TTS error."
        case "DeepgramTTS":
            if nsError.code == Self.deepgramNotConfiguredErrorCode {
                return "Deepgram is not configured. Add a Deepgram API key in Settings."
            }
            return "Deepgram voice playback failed. Check the app log for the TTS error."
        case "CompanionScreenCapture":
            return "Screen capture failed. Grant Screen Recording to this exact app, then quit and reopen."
        default:
            return "Something went wrong. Check the app log for the exact error."
        }
    }

    private func ttsFailureDiagnosticFields(for error: Error) -> [String: Any] {
        let nsError = error as NSError
        var fields: [String: Any] = [
            "ttsProvider": selectedTTSProvider.rawValue
        ]

        if selectedTTSProvider == .deepgram || nsError.domain == "DeepgramTTS" {
            let currentSnapshot = DeepgramTTSConfigurationSnapshot.current()
            fields["deepgramKeyConfigured"] = currentSnapshot.hasAPIKey
            fields["deepgramVoiceID"] = currentSnapshot.voiceID
            fields["deepgramSnapshotMatchesClient"] = (cachedDeepgramTTSSnapshot == currentSnapshot)

            if nsError.domain == "DeepgramTTS", nsError.code == Self.deepgramNotConfiguredErrorCode {
                fields["ttsFailureKind"] = currentSnapshot.hasAPIKey ? "stale_client" : "missing_key"
            } else if nsError.domain == "DeepgramTTS" {
                fields["ttsFailureKind"] = "playback_failure"
            } else {
                fields["ttsFailureKind"] = "unknown"
            }
            return fields
        }

        if nsError.domain == "ElevenLabsTTS" || nsError.domain == "CartesiaTTS" {
            fields["ttsFailureKind"] = "playback_failure"
        }
        return fields
    }
}

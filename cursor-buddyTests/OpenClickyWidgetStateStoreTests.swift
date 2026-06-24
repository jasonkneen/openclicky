import Foundation
import Testing
@testable import OpenClicky

@MainActor
struct OpenClickyWidgetStateStoreTests {
    
    // Helper to control UserDefaults settings during a test block
    private func withUserDefaults(
        enabled: Bool = true,
        taskNames: Bool = false,
        memorySnippets: Bool = false,
        focusedAppContext: Bool = false,
        operation: () throws -> Void
    ) rethrows {
        let oldEnabled = UserDefaults.standard.object(forKey: AppBundleConfiguration.userWidgetsEnabledDefaultsKey)
        let oldTaskNames = UserDefaults.standard.object(forKey: AppBundleConfiguration.userWidgetsIncludeAgentTaskNamesDefaultsKey)
        let oldMemory = UserDefaults.standard.object(forKey: AppBundleConfiguration.userWidgetsIncludeMemorySnippetsDefaultsKey)
        let oldContext = UserDefaults.standard.object(forKey: AppBundleConfiguration.userWidgetsIncludeFocusedAppContextDefaultsKey)
        
        UserDefaults.standard.set(enabled, forKey: AppBundleConfiguration.userWidgetsEnabledDefaultsKey)
        UserDefaults.standard.set(taskNames, forKey: AppBundleConfiguration.userWidgetsIncludeAgentTaskNamesDefaultsKey)
        UserDefaults.standard.set(memorySnippets, forKey: AppBundleConfiguration.userWidgetsIncludeMemorySnippetsDefaultsKey)
        UserDefaults.standard.set(focusedAppContext, forKey: AppBundleConfiguration.userWidgetsIncludeFocusedAppContextDefaultsKey)
        
        defer {
            UserDefaults.standard.set(oldEnabled, forKey: AppBundleConfiguration.userWidgetsEnabledDefaultsKey)
            UserDefaults.standard.set(oldTaskNames, forKey: AppBundleConfiguration.userWidgetsIncludeAgentTaskNamesDefaultsKey)
            UserDefaults.standard.set(oldMemory, forKey: AppBundleConfiguration.userWidgetsIncludeMemorySnippetsDefaultsKey)
            UserDefaults.standard.set(oldContext, forKey: AppBundleConfiguration.userWidgetsIncludeFocusedAppContextDefaultsKey)
        }
        
        try operation()
    }
    
    @Test func testMakeSnapshotRespectsPrivacySettingsWhenRedacted() throws {
        let companionManager = CompanionManager()
        
        // Mock active agents in companionManager
        let agentID = UUID()
        let dockItem = ClickyAgentDockItem(
            id: UUID(),
            sessionID: agentID,
            title: "Analyze database optimization plan",
            userInstruction: "Analyze database optimization plan",
            accentTheme: .blue,
            status: .running,
            progressStageLabel: "Executing",
            progressStepText: "Running tests",
            activityStatusLines: ["Running schema migrations"],
            caption: "Running schema migrations on the main database instance",
            suggestedNextActions: [],
            createdAt: Date()
        )
        companionManager.setTestAgentDockItems([dockItem])
        
        // Run with taskNames privacy turned off
        withUserDefaults(taskNames: false) {
            let store = OpenClickyWidgetStateStore()
            let snapshot = store.makeSnapshot(from: companionManager)
            
            #expect(snapshot.activeAgents.count == 1)
            guard let agentSummary = snapshot.activeAgents.first else { return }
            
            #expect(agentSummary.id == agentID)
            #expect(agentSummary.title == "Agent running") // Redacted title
            #expect(agentSummary.caption == nil) // Redacted caption
            #expect(agentSummary.status == "Running")
        }
    }
    
    @Test func testMakeSnapshotRespectsPrivacySettingsWhenExposed() throws {
        let companionManager = CompanionManager()
        
        let agentID = UUID()
        let dockItem = ClickyAgentDockItem(
            id: UUID(),
            sessionID: agentID,
            title: "Analyze database optimization plan",
            userInstruction: "Analyze database optimization plan",
            accentTheme: .blue,
            status: .running,
            progressStageLabel: "Executing",
            progressStepText: "Running tests",
            activityStatusLines: ["Running schema migrations"],
            caption: "Running schema migrations on the main database instance",
            suggestedNextActions: [],
            createdAt: Date()
        )
        companionManager.setTestAgentDockItems([dockItem])
        
        // Run with taskNames privacy turned on
        withUserDefaults(taskNames: true) {
            let store = OpenClickyWidgetStateStore()
            let snapshot = store.makeSnapshot(from: companionManager)
            
            #expect(snapshot.activeAgents.count == 1)
            guard let agentSummary = snapshot.activeAgents.first else { return }
            
            #expect(agentSummary.id == agentID)
            #expect(agentSummary.title == "Analyze database optimization plan") // Exposed title
            #expect(agentSummary.caption == "Running schema migrations on the main database instance") // Exposed caption
            #expect(agentSummary.status == "Running")
        }
    }
    
    @Test func testMakeSnapshotExtractsMemorySummaryRespectingPrivacy() throws {
        let companionManager = CompanionManager()
        let memoryFile = companionManager.codexHomeManager.persistentMemoryFile
        
        // Backup original memory file content if it exists
        let originalContent = try? String(contentsOf: memoryFile, encoding: .utf8)
        
        // Ensure parent directories exist
        try? FileManager.default.createDirectory(at: memoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        // Write test memory content
        let testMemory = "# OpenClicky Persistent Memory\n\nUser likes dark mode.\n\nUser prefers vanilla CSS over tailwind."
        try? testMemory.write(to: memoryFile, atomically: true, encoding: .utf8)
        
        defer {
            // Restore original memory file content
            if let originalContent = originalContent {
                try? originalContent.write(to: memoryFile, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: memoryFile)
            }
        }
        
        // Test when memory snippets privacy is turned off
        withUserDefaults(memorySnippets: false) {
            let store = OpenClickyWidgetStateStore()
            let snapshot = store.makeSnapshot(from: companionManager)
            #expect(snapshot.latestMemorySummary == nil)
        }
        
        // Test when memory snippets privacy is turned on
        withUserDefaults(memorySnippets: true) {
            let store = OpenClickyWidgetStateStore()
            let snapshot = store.makeSnapshot(from: companionManager)
            #expect(snapshot.latestMemorySummary == "User prefers vanilla CSS over tailwind.")
        }
    }
    
    @Test func testMakeSnapshotGeneratesAttentionItemsForPermissionsAndFailedSessions() throws {
        let companionManager = CompanionManager()
        
        // Simulate missing permissions and no failed agents
        companionManager.setTestHasMicrophonePermission(false)
        companionManager.setTestHasScreenContentPermission(false)
        companionManager.setTestCodexAgentSessions([])
        
        let store = OpenClickyWidgetStateStore()
        var snapshot = store.makeSnapshot(from: companionManager)
        
        // Expect attention items for missing permissions
        #expect(snapshot.needsAttention.contains { $0.kind == .missingPermission && $0.title == "Microphone permission needed" })
        #expect(snapshot.needsAttention.contains { $0.kind == .missingPermission && $0.title == "Screen recording permission needed" })
        
        // Simulate granted permissions
        companionManager.setTestHasMicrophonePermission(true)
        companionManager.setTestHasScreenContentPermission(true)
        
        snapshot = store.makeSnapshot(from: companionManager)
        #expect(!snapshot.needsAttention.contains { $0.kind == .missingPermission })
        
        // Simulate a failed agent session
        let session = CodexAgentSession(title: "Failed Build Task", accentTheme: .rose)
        session.setTestStatus(CodexAgentSessionStatus.failed("Build exited with code 1"))
        session.setTestLastErrorMessage("Build exited with code 1")
        companionManager.setTestCodexAgentSessions([session])
        
        withUserDefaults(taskNames: false) {
            let snapshot = store.makeSnapshot(from: companionManager)
            #expect(snapshot.needsAttention.contains { item in
                item.kind == .failedAgent &&
                item.title == "Agent stopped" &&
                item.detail == nil
            })
        }
        
        withUserDefaults(taskNames: true) {
            let snapshot = store.makeSnapshot(from: companionManager)
            #expect(snapshot.needsAttention.contains { item in
                item.kind == .failedAgent &&
                item.title == "Failed Build Task stopped" &&
                item.detail == "Build exited with code 1"
            })
        }
    }
    
    @Test func testWidgetStateStoreLogReviewAttention() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let logStore = OpenClickyMessageLogStore(fileManager: .default, logDirectory: tempDir)
        let widgetStore = OpenClickyWidgetStateStore(fileManager: .default, logStore: logStore)
        
        // Write mock snapshot file to ensure readSnapshot works
        let container = OpenClickyWidgetStateStore.containerDirectory(fileManager: .default)
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        
        let initialSnapshot = OpenClickyWidgetSnapshot(
            schemaVersion: OpenClickyWidgetSnapshot.schemaVersion,
            generatedAt: Date(),
            activeAgents: [],
            todayStats: OpenClickyWidgetTodayStats(),
            needsAttention: [],
            latestMemorySummary: nil,
            privacy: OpenClickyWidgetPrivacySettings(widgetsEnabled: true)
        )
        widgetStore.write(initialSnapshot)
        
        // Case 1: No review comments
        widgetStore.refreshLogReviewAttentionSnapshot()
        var snapshot = OpenClickyWidgetStateStore.readSnapshot(fileManager: .default)
        #expect(snapshot.todayStats.logReviewComments == 0)
        #expect(!snapshot.needsAttention.contains { $0.kind == .flaggedLog })
        
        // Case 2: Multi-line comments in file
        let commentsText = "comment 1\ncomment 2\ncomment 3\n"
        try? commentsText.write(to: logStore.reviewCommentsFile, atomically: true, encoding: .utf8)
        
        widgetStore.refreshLogReviewAttentionSnapshot()
        snapshot = OpenClickyWidgetStateStore.readSnapshot(fileManager: .default)
        #expect(snapshot.todayStats.logReviewComments == 3)
        #expect(snapshot.needsAttention.contains { $0.kind == .flaggedLog && $0.title == "3 flagged log comments" })
    }
    
    @Test func testWidgetStateStoreTodayStatsExtraction() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let logStore = OpenClickyMessageLogStore(fileManager: .default, logDirectory: tempDir)
        
        // Write mock logs
        let logContent = """
        {"event":"voice.transcript","text":"hello"}
        {"event":"voice.transcript","text":"how are you"}
        {"event":"openclicky.agent_task.created","task":"build"}
        {"method":"turn/completed"}
        {"event":"codex.stderr","message":"failed to build"}
        {"event":"codex.stderr","fields":{"line":"2026-05-31T19:36:53Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when AuthRequired(AuthRequiredError { www_authenticate_header: \\"Bearer error=\\\\\\"unauthorized\\\\\\", error_description=\\\\\\"No Authorization: Bearer header on request\\\\\\"\\" })"}}
        """
        try? logContent.write(to: logStore.currentLogFile, atomically: true, encoding: .utf8)
        
        let companionManager = CompanionManager()
        let store = OpenClickyWidgetStateStore(fileManager: .default, logStore: logStore)
        
        withUserDefaults(taskNames: true) {
            let snapshot = store.makeSnapshot(from: companionManager)
            #expect(snapshot.todayStats.voiceInteractions == 2)
            #expect(snapshot.todayStats.agentTasksCreated == 1)
            #expect(snapshot.todayStats.agentCompletions == 1)
            #expect(snapshot.todayStats.agentFailures == 1)
        }
    }
}

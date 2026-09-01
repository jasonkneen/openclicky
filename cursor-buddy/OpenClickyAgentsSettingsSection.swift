//
//  OpenClickyAgentsSettingsSection.swift
//  OpenClicky
//
//  Real "Agents" settings tab — backed by OpenClickyAgentStore. List on
//  the left, editor on the right (soul / instructions / memory / display
//  name / description). User-defined agents are writable; built-ins are
//  read-only with a "Create user override" button that copies their files
//  into the user root.
//

import SwiftUI
import OCAutomation

struct OpenClickyAgentsSettingsSection: View {
  @ObservedObject var companion: CompanionManager
  @ObservedObject private var store = OpenClickyAgentStore.shared
  @State private var selectedSlug: String?
  @State private var showingCreate = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      HStack(alignment: .top, spacing: 14) {
        agentList
          .frame(width: 220)
        detail
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .sheet(isPresented: $showingCreate) {
      CreateAgentSheet(store: store) { newSlug in
        selectedSlug = newSlug
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "person.2")
        .font(.system(size: 13, weight: .medium))
      Text("Specialist agents")
        .font(.system(size: 13, weight: .semibold))
      Text("(\(store.agents.count))")
        .font(.system(size: 11))
        .foregroundColor(.secondary)
      Spacer()
      Button(action: { showingCreate = true }) {
        Label("New agent", systemImage: "plus")
          .font(.system(size: 12, weight: .medium))
      }
      .buttonStyle(.bordered)
    }
  }

  private var agentList: some View {
    VStack(alignment: .leading, spacing: 4) {
      if store.agents.isEmpty {
        Text("No specialist agents yet.\nCreate one to define a custom soul, memory, instructions, and skill set.")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .padding(8)
      } else {
        ForEach(store.agents) { agent in
          row(agent: agent)
        }
      }
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.gray.opacity(0.08))
    )
  }

  private func row(agent: OpenClickyAgentDefinition) -> some View {
    Button(action: { selectedSlug = agent.slug }) {
      HStack(spacing: 6) {
        Image(systemName: agent.isProtectedSystemAgent ? "lock.shield.fill" : (agent.isUserDefined ? "person.crop.circle.fill" : "person.crop.circle"))
          .foregroundColor(agent.isUserDefined ? .accentColor : .secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(agent.metadata.displayName)
            .font(.system(size: 12, weight: .medium))
          Text(agent.slug)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        }
        Spacer()
        if agent.isProtectedSystemAgent || !agent.isUserDefined {
          Text(agent.isProtectedSystemAgent ? "system" : "built-in")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.gray.opacity(0.2)))
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(selectedSlug == agent.slug ? Color.accentColor.opacity(0.15) : Color.clear)
      )
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var detail: some View {
    if let slug = selectedSlug, let agent = store.agent(slug: slug) {
      AgentEditorView(agent: agent, store: store, companion: companion)
        .id(agent.slug)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Text("Select or create an agent to edit its soul, memory, instructions, and skills.")
          .font(.system(size: 12))
          .foregroundColor(.secondary)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.gray.opacity(0.05))
      )
    }
  }
}

// MARK: editor

private struct AgentEditorView: View {
  let agent: OpenClickyAgentDefinition
  @ObservedObject var store: OpenClickyAgentStore
  @ObservedObject var companion: CompanionManager

  @State private var displayName: String
  @State private var description: String
  @State private var soul: String
  @State private var instructions: String
  @State private var memory: String
  @State private var heartbeat: String
  @State private var saveError: String?

  init(agent: OpenClickyAgentDefinition, store: OpenClickyAgentStore, companion: CompanionManager) {
    self.agent = agent
    self.store = store
    self.companion = companion
    _displayName = State(initialValue: agent.metadata.displayName)
    _description = State(initialValue: agent.metadata.description)
    _soul = State(initialValue: agent.soul)
    _instructions = State(initialValue: agent.instructions)
    _memory = State(initialValue: agent.memory)
    _heartbeat = State(initialValue: agent.heartbeat)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      titleRow
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          field("Display name", text: $displayName)
          field("Description", text: $description)
          textArea("soul.md", text: $soul, hint: "Identity, vibe, voice, boundaries.")
          textArea("instructions.md", text: $instructions, hint: "How this agent should approach tasks.")
          textArea("memory.md", text: $memory, hint: "Agent-scoped persistent memory.")
          textArea("HEARTBEAT.md", text: $heartbeat, hint: "Scheduled check-ins, pending items, and done log. Read at session start, updated by the agent.")

          if let saveError {
            Text(saveError)
              .font(.system(size: 11))
              .foregroundColor(.red)
          }
        }
        .padding(.bottom, 12)
      }

      HStack {
        Button("Launch as session") { launch() }
          .buttonStyle(.bordered)
        if !agent.isProtectedSystemAgent {
          Button("Schedule heartbeat") { scheduleHeartbeat() }
            .buttonStyle(.bordered)
            .help("Create an automation that runs this agent's heartbeat check-in every 30 minutes.")
        }
        Spacer()
        if agent.isProtectedSystemAgent {
          Label("Required by OpenClicky", systemImage: "lock.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
        } else if agent.isUserDefined {
          Button(role: .destructive) { delete() } label: { Text("Delete user copy") }
            .buttonStyle(.bordered)
        }
        if !agent.isProtectedSystemAgent {
          Button("Save") { save() }
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.gray.opacity(0.05))
    )
  }

  private var titleRow: some View {
    HStack(spacing: 8) {
      Image(systemName: agent.isProtectedSystemAgent ? "lock.shield.fill" : (agent.isUserDefined ? "person.crop.circle.fill" : "person.crop.circle"))
      VStack(alignment: .leading, spacing: 0) {
        Text(agent.metadata.displayName)
          .font(.system(size: 14, weight: .semibold))
        Text("slug: \(agent.slug)" + agentTitleSuffix)
          .font(.system(size: 10))
          .foregroundColor(.secondary)
      }
      Spacer()
    }
  }

  private var agentTitleSuffix: String {
    if agent.isProtectedSystemAgent { return "  ·  required system agent" }
    return agent.isUserDefined ? "" : "  ·  built-in (saving creates a user override)"
  }

  private func field(_ label: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.system(size: 11, weight: .medium))
      TextField("", text: text)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
    }
  }

  private func textArea(_ label: String, text: Binding<String>, hint: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label).font(.system(size: 11, weight: .medium))
        Text("· \(hint)").font(.system(size: 10)).foregroundColor(.secondary)
      }
      TextEditor(text: text)
        .font(.system(size: 11, design: .monospaced))
        .frame(minHeight: 80, maxHeight: 200)
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
  }

  private func save() {
    do {
      try store.update(agent, soul: soul, instructions: instructions, memory: memory, heartbeat: heartbeat, displayName: displayName, description: description)
      saveError = nil
    } catch {
      saveError = error.localizedDescription
    }
  }

  private func delete() {
    do {
      try store.deleteUserCopy(slug: agent.slug)
    } catch {
      saveError = error.localizedDescription
    }
  }

  private func launch() {
    Task { @MainActor in
      await Task.yield()
      if let fresh = store.agent(slug: agent.slug) {
        _ = companion.createAndSelectNewCodexAgentSession(asAgent: fresh)
      }
    }
  }

  private func scheduleHeartbeat() {
    let prompt = """
    Heartbeat check-in for the \(agent.metadata.displayName) agent.

    1. Read HEARTBEAT.md.
    2. Work on the next unblocked Pending item, or do a brief status pass if none.
    3. Update `Last check-in` to the current timestamp.
    4. Move completed items from Pending to Done with a one-line note.
    5. Append any newly identified check-ins to Pending.
    6. Save HEARTBEAT.md.
    """
    let automation = OpenClickyAutomation(
      name: "\(agent.metadata.displayName) heartbeat",
      schedule: .interval(seconds: 30 * 60),
      prompt: prompt,
      agentSlug: agent.slug,
      enabled: true
    )
    OpenClickyAutomationStore.shared.add(automation)
  }
}

// MARK: create sheet

private struct CreateAgentSheet: View {
  @ObservedObject var store: OpenClickyAgentStore
  var onCreated: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var slugInput: String = ""
  @State private var displayName: String = ""
  @State private var description: String = ""
  @State private var soul: String = ""
  @State private var instructions: String = ""
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New specialist agent")
        .font(.system(size: 14, weight: .semibold))

      VStack(alignment: .leading, spacing: 8) {
        labeled("Slug", placeholder: "e.g. triage", text: $slugInput)
        labeled("Display name", placeholder: "Triage", text: $displayName)
        labeled("Description", placeholder: "Optional one-liner", text: $description)
        VStack(alignment: .leading, spacing: 4) {
          Text("soul.md (optional)").font(.system(size: 11, weight: .medium))
          TextEditor(text: $soul).frame(minHeight: 80).font(.system(size: 11, design: .monospaced))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("instructions.md (optional)").font(.system(size: 11, weight: .medium))
          TextEditor(text: $instructions).frame(minHeight: 80).font(.system(size: 11, design: .monospaced))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        }
      }

      if let error {
        Text(error).font(.system(size: 11)).foregroundColor(.red)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Create") { create() }
          .buttonStyle(.borderedProminent)
          .disabled(slugInput.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(18)
    .frame(width: 460)
  }

  private func labeled(_ label: String, placeholder: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.system(size: 11, weight: .medium))
      TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: 12))
    }
  }

  private func create() {
    do {
      let agent = try store.create(
        slug: slugInput,
        displayName: displayName,
        soul: soul,
        instructions: instructions,
        memory: "",
        heartbeat: "",
        description: description
      )
      onCreated(agent.slug)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

//
//  OpenClickyAutomationsSettingsSection.swift
//  OpenClicky
//
//  "Automations" settings tab. Lists scheduled prompts, supports interval
//  ("every N minutes") or 5-field cron, optionally bound to a specialist
//  OpenClicky agent. Persists via OpenClickyAutomationStore.
//

import SwiftUI
import OCAutomation

struct OpenClickyAutomationsSettingsSection: View {
  @ObservedObject var companion: CompanionManager
  @ObservedObject private var store = OpenClickyAutomationStore.shared
  @ObservedObject private var agentStore = OpenClickyAgentStore.shared
  @State private var showingNew = false
  @State private var editing: OpenClickyAutomation?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      list
    }
    .sheet(isPresented: $showingNew) {
      AutomationEditorSheet(initial: nil, agents: agentStore.agents) { result in
        store.add(result)
      }
    }
    .sheet(item: $editing) { existing in
      AutomationEditorSheet(initial: existing, agents: agentStore.agents) { result in
        store.update(result)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "calendar.badge.clock")
        .font(.system(size: 13, weight: .medium))
      Text("Scheduled prompts")
        .font(.system(size: 13, weight: .semibold))
      Text("(\(store.automations.count))")
        .font(.system(size: 11))
        .foregroundColor(.secondary)
      Spacer()
      Button(action: { showingNew = true }) {
        Label("New automation", systemImage: "plus")
          .font(.system(size: 12, weight: .medium))
      }
      .buttonStyle(.bordered)
    }
  }

  private var list: some View {
    ScrollView {
      VStack(spacing: 6) {
        if store.automations.isEmpty {
          Text("No automations yet. Create one to run a prompt on a schedule.")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        } else {
          ForEach(store.automations) { auto in
            row(auto)
          }
        }
      }
    }
  }

  private func row(_ a: OpenClickyAutomation) -> some View {
    let isProtected = store.isProtectedSystemAutomation(a)
      return HStack(spacing: 10) {
      Toggle("", isOn: Binding(
        get: { a.enabled },
        set: { store.setEnabled(id: a.id, enabled: $0) }
      ))
      .labelsHidden()

      VStack(alignment: .leading, spacing: 3) {
        Text(a.name)
          .font(.system(size: 13, weight: .semibold))
        HStack(spacing: 6) {
          Text(a.schedule.displayString)
          if let slug = a.agentSlug {
            Text("· agent: \(slug)")
          }
          if isProtected {
            Text("· locked")
          }
          if let next = a.nextRun, a.enabled {
            Text("· next: \(next.formatted(.dateTime.weekday().hour().minute()))")
          }
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        Text(a.prompt)
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .lineLimit(2)
      }
      Spacer()
      if isProtected {
        Label("System", systemImage: "lock.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.secondary)
      } else {
        Button("Edit") { editing = a }
          .buttonStyle(.borderless)
        Button(role: .destructive) { store.remove(id: a.id) } label: { Image(systemName: "trash") }
          .buttonStyle(.borderless)
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.gray.opacity(0.06))
    )
  }
}

// MARK: editor sheet

private enum ScheduleKind: String, CaseIterable, Identifiable {
  case interval, cron
  var id: String { rawValue }
  var label: String { self == .interval ? "Interval" : "Cron" }
}

private struct AutomationEditorSheet: View {
  let initial: OpenClickyAutomation?
  let agents: [OpenClickyAgentDefinition]
  var onSave: (OpenClickyAutomation) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var name: String = ""
  @State private var prompt: String = ""
  @State private var kind: ScheduleKind = .interval
  @State private var intervalMinutes: Int = 30
  @State private var cronExpr: String = "0 9 * * MON"
  @State private var agentSlug: String = ""
  @State private var enabled: Bool = true
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(initial == nil ? "New automation" : "Edit automation")
        .font(.system(size: 14, weight: .semibold))

      VStack(alignment: .leading, spacing: 8) {
        labeled("Name", placeholder: "e.g. Morning standup", text: $name)

        VStack(alignment: .leading, spacing: 4) {
          Text("Prompt").font(.system(size: 11, weight: .medium))
          TextEditor(text: $prompt).frame(minHeight: 80).font(.system(size: 11, design: .monospaced))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("Schedule").font(.system(size: 11, weight: .medium))
          Picker("", selection: $kind) {
            ForEach(ScheduleKind.allCases) { k in Text(k.label).tag(k) }
          }
          .pickerStyle(.segmented)

          if kind == .interval {
            HStack {
              Text("Every")
              TextField("", value: $intervalMinutes, format: .number)
                .frame(width: 64)
                .textFieldStyle(.roundedBorder)
              Text("minutes")
            }
            .font(.system(size: 12))
          } else {
            VStack(alignment: .leading, spacing: 3) {
              TextField("0 9 * * MON  (m h dom mon dow)", text: $cronExpr)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
              Text("Standard 5-field cron. Numbers, lists (1,3), ranges (1-5), steps (*/5), or *.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
          }
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("Agent (optional)").font(.system(size: 11, weight: .medium))
          Picker("", selection: $agentSlug) {
            Text("Default chat session").tag("")
            ForEach(agents) { a in Text("\(a.metadata.displayName) (\(a.slug))").tag(a.slug) }
          }
          .pickerStyle(.menu)
        }

        Toggle("Enabled", isOn: $enabled).font(.system(size: 12))
      }

      if let error {
        Text(error).font(.system(size: 11)).foregroundColor(.red)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button(initial == nil ? "Create" : "Save") { commit() }
          .buttonStyle(.borderedProminent)
          .disabled(!isValid)
      }
    }
    .padding(18)
    .frame(width: 520)
    .onAppear(perform: hydrate)
  }

  private var isValid: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty &&
    !prompt.trimmingCharacters(in: .whitespaces).isEmpty &&
    (kind == .interval ? intervalMinutes >= 1 : CronExpression(cronExpr) != nil)
  }

  private func hydrate() {
    guard let initial else { return }
    name = initial.name
    prompt = initial.prompt
    enabled = initial.enabled
    agentSlug = initial.agentSlug ?? ""
    switch initial.schedule {
    case .interval(let s):
      kind = .interval
      intervalMinutes = max(1, Int(s) / 60)
    case .cron(let s):
      kind = .cron
      cronExpr = s
    }
  }

  private func labeled(_ label: String, placeholder: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.system(size: 11, weight: .medium))
      TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: 12))
    }
  }

  private func commit() {
    let schedule: OpenClickyAutomationSchedule
    switch kind {
    case .interval:
      schedule = .interval(seconds: TimeInterval(max(1, intervalMinutes) * 60))
    case .cron:
      guard CronExpression(cronExpr) != nil else {
        error = "Invalid cron expression."
        return
      }
      schedule = .cron(cronExpr)
    }
    let trimmedSlug = agentSlug.trimmingCharacters(in: .whitespaces)
    var auto = initial ?? OpenClickyAutomation(name: name, schedule: schedule, prompt: prompt)
    auto.name = name
    auto.prompt = prompt
    auto.schedule = schedule
    auto.enabled = enabled
    auto.agentSlug = trimmedSlug.isEmpty ? nil : trimmedSlug
    onSave(auto)
    dismiss()
  }
}

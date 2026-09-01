//
//  MemoryDrawerView.swift
//  OpenClicky
//
//  Right-side slide-in drawer that surfaces the global persistent memory
//  store plus per-conversation references. Reads from CodexHomeManager
//  (existing memory.md + memories directory) and lists session matches
//  inline so memory stays all-inclusive but discoverable per-thread.
//

import SwiftUI
import OCCore
import OCUI

struct MemoryDrawerView: View {
  @ObservedObject var companion: CompanionManager
  @Binding var isOpen: Bool
  @State private var draftAddition: String = ""
  @State private var refreshKey: Int = 0

  static let width: CGFloat = 320

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().background(Color.white.opacity(0.06))
      content
      Divider().background(Color.white.opacity(0.06))
      composer
    }
    .frame(width: Self.width)
    .glassEffect(
      .regular.tint(DS.Colors.accent.opacity(0.04)),
      in: RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
    .padding(10)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "brain")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(DS.Colors.accentText)
      Text("Memory")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(DS.Colors.textPrimary)
      Spacer()
      Button(action: { isOpen = false }) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(DS.Colors.textSecondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        sectionLabel("Persistent memory")
        Text(persistentText)
          .font(.system(size: 11))
          .foregroundColor(DS.Colors.textPrimary.opacity(0.85))
          .textSelection(.enabled)
          .padding(.horizontal, 12)

        sectionLabel("Memory files")
        VStack(alignment: .leading, spacing: 4) {
          ForEach(memoryFiles, id: \.self) { url in
            HStack(spacing: 6) {
              Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textSecondary)
              Text(url.lastPathComponent)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
              Spacer()
            }
            .padding(.horizontal, 12)
          }
        }

        sectionLabel("Referenced in conversations")
        VStack(alignment: .leading, spacing: 4) {
          if conversationRefs.isEmpty {
            Text("No conversation references yet.")
              .font(.system(size: 11))
              .foregroundColor(DS.Colors.textSecondary)
              .padding(.horizontal, 12)
          } else {
            ForEach(conversationRefs, id: \.id) { ref in
              Button(action: { companion.selectCodexAgentSession(ref.id) }) {
                HStack(spacing: 6) {
                  Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                  Text(ref.title)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                  Spacer()
                  Text("\(ref.matchCount)")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
      .padding(.vertical, 12)
      .id(refreshKey)
    }
  }

  private var composer: some View {
    HStack(spacing: 8) {
      TextField("Add to memory…", text: $draftAddition, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundColor(DS.Colors.textPrimary)
        .lineLimit(1...3)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.04))
        )
      Button(action: addEntry) {
        Image(systemName: "plus.circle.fill")
          .font(.system(size: 18))
          .foregroundColor(DS.Colors.accentText)
      }
      .buttonStyle(.plain)
      .disabled(draftAddition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
  }

  // MARK: helpers

  private func sectionLabel(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: 10, weight: .semibold))
      .foregroundColor(DS.Colors.textSecondary.opacity(0.7))
      .padding(.horizontal, 12)
  }

  private var persistentText: String {
    let txt = companion.codexHomeManager.persistentMemoryContext()
    let trimmed = txt.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "(no persistent memory yet)" : trimmed
  }

  private var memoryFiles: [URL] {
    companion.codexHomeManager.persistentMemoryFiles(includeArchived: false)
  }

  private struct ConversationRef: Identifiable {
    let id: UUID
    let title: String
    let matchCount: Int
  }

  /// Lightweight derivation: count entries per session that contain the
  /// substring "memory" or that mention any persistent-memory file name.
  /// Exact reference graph is a follow-up; this surfaces sessions that
  /// touch memory at all so the drawer is useful immediately.
  private var conversationRefs: [ConversationRef] {
    let needles = ["memory", "remember", "memo"]
    return companion.codexAgentSessions.compactMap { session in
      let count = session.entries.reduce(0) { acc, entry in
        let lower = entry.text.lowercased()
        return acc + (needles.contains(where: { lower.contains($0) }) ? 1 : 0)
      }
      guard count > 0 else { return nil }
      return ConversationRef(id: session.id, title: session.title, matchCount: count)
    }
  }

  private func addEntry() {
    let trimmed = draftAddition.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      try companion.codexHomeManager.appendPersistentMemoryEvent(
        userRequest: "(manual add via memory drawer)",
        agentResponse: trimmed
      )
      draftAddition = ""
      refreshKey &+= 1
    } catch {
      print("memory drawer add failed: \(error)")
    }
  }
}

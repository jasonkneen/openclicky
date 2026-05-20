import SwiftUI

struct OpenClickyPromptAutocompleteOption: Identifiable, Equatable {
  enum Trigger: String {
    case slash = "/"
    case mention = "@"
  }

  let id: String
  let trigger: Trigger
  let title: String
  let subtitle: String
  let completion: String
  let systemImage: String
}

enum OpenClickyPromptAutocomplete {
  private struct Context {
    let trigger: OpenClickyPromptAutocompleteOption.Trigger
    let query: String
  }

  static func options(
    for text: String,
    agents: [OpenClickyAgentDefinition],
    skillSuggestions: [OpenClickySkillDiscoverySuggestion]
  ) -> [OpenClickyPromptAutocompleteOption] {
    guard let context = context(for: text) else { return [] }

    let baseOptions: [OpenClickyPromptAutocompleteOption]
    switch context.trigger {
    case .slash:
      baseOptions = slashOptions
    case .mention:
      baseOptions = mentionOptions(agents: agents, skillSuggestions: skillSuggestions)
    }

    let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let filtered = query.isEmpty ? baseOptions : baseOptions.filter { option in
      option.title.lowercased().contains(query)
        || option.subtitle.lowercased().contains(query)
        || option.completion.lowercased().contains(query)
    }
    return Array(filtered.prefix(7))
  }

  @discardableResult
  static func acceptFirstOption(
    in text: inout String,
    agents: [OpenClickyAgentDefinition],
    skillSuggestions: [OpenClickySkillDiscoverySuggestion]
  ) -> Bool {
    guard let option = options(for: text, agents: agents, skillSuggestions: skillSuggestions).first else {
      return false
    }
    apply(option, to: &text)
    return true
  }

  static func apply(_ option: OpenClickyPromptAutocompleteOption, to text: inout String) {
    guard let range = activeTokenRange(in: text) else { return }
    let suffix = text[range.upperBound...]
    let needsSpace = suffix.first.map { !$0.isWhitespace } ?? true
    text.replaceSubrange(range, with: option.completion + (needsSpace ? " " : ""))
  }

  private static func context(for text: String) -> Context? {
    guard let range = activeTokenRange(in: text) else { return nil }
    let token = String(text[range])
    guard let first = token.first else { return nil }
    switch first {
    case "/":
      return Context(trigger: .slash, query: String(token.dropFirst()))
    case "@":
      return Context(trigger: .mention, query: String(token.dropFirst()))
    default:
      return nil
    }
  }

  private static func activeTokenRange(in text: String) -> Range<String.Index>? {
    guard !text.isEmpty else { return nil }
    var start = text.startIndex
    var index = text.startIndex
    while index < text.endIndex {
      if text[index].isWhitespace {
        start = text.index(after: index)
      }
      index = text.index(after: index)
    }
    guard start < text.endIndex else { return nil }
    return start..<text.endIndex
  }

  private static var slashOptions: [OpenClickyPromptAutocompleteOption] {
    [
      OpenClickyPromptAutocompleteOption(id: "slash-agent", trigger: .slash, title: "/agent", subtitle: "Start a background OpenClicky agent task", completion: "/agent", systemImage: "bolt.fill"),
      OpenClickyPromptAutocompleteOption(id: "slash-chat", trigger: .slash, title: "/chat", subtitle: "Keep this in the OpenClicky chat lane", completion: "/chat", systemImage: "bubble.left.and.bubble.right.fill"),
      OpenClickyPromptAutocompleteOption(id: "slash-ask", trigger: .slash, title: "/ask", subtitle: "Ask OpenClicky with current context", completion: "/ask", systemImage: "sparkles"),
      OpenClickyPromptAutocompleteOption(id: "slash-screen", trigger: .slash, title: "/screen", subtitle: "Use current screen context", completion: "/screen", systemImage: "rectangle.dashed"),
      OpenClickyPromptAutocompleteOption(id: "slash-search", trigger: .slash, title: "/search", subtitle: "Search the web through OpenClicky", completion: "/search", systemImage: "magnifyingglass"),
      OpenClickyPromptAutocompleteOption(id: "slash-3d", trigger: .slash, title: "/3d", subtitle: "Generate a 3D object preview", completion: "/3d", systemImage: "cube.fill"),
      OpenClickyPromptAutocompleteOption(id: "slash-gmail", trigger: .slash, title: "/gmail", subtitle: "Use OpenClicky's gog Gmail workflow", completion: "/gmail", systemImage: "envelope.fill"),
      OpenClickyPromptAutocompleteOption(id: "slash-skill", trigger: .slash, title: "/skill", subtitle: "Ask OpenClicky to use or install a skill", completion: "/skill", systemImage: "wrench.and.screwdriver.fill")
    ]
  }

  private static func mentionOptions(
    agents: [OpenClickyAgentDefinition],
    skillSuggestions: [OpenClickySkillDiscoverySuggestion]
  ) -> [OpenClickyPromptAutocompleteOption] {
    let agentOptions = agents.map { agent in
      OpenClickyPromptAutocompleteOption(
        id: "agent-\(agent.slug)",
        trigger: .mention,
        title: "@\(agent.metadata.displayName)",
        subtitle: agent.metadata.description.isEmpty ? "OpenClicky specialist" : agent.metadata.description,
        completion: "@\(agent.slug)",
        systemImage: "person.crop.circle.badge.checkmark"
      )
    }

    var seenSkillIDs = Set<String>()
    let skillOptions = skillSuggestions.compactMap { suggestion -> OpenClickyPromptAutocompleteOption? in
      let id = suggestion.id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty, !seenSkillIDs.contains(id.lowercased()) else { return nil }
      seenSkillIDs.insert(id.lowercased())
      return OpenClickyPromptAutocompleteOption(
        id: "skill-\(id)",
        trigger: .mention,
        title: "@\(suggestion.chipTitle ?? suggestion.title)",
        subtitle: "Skill · \(suggestion.detail)",
        completion: "@skill:\(id)",
        systemImage: suggestion.systemImage ?? "puzzlepiece.extension.fill"
      )
    }

    return agentOptions + skillOptions
  }
}

struct OpenClickyPromptAutocompletePanel: View {
  let options: [OpenClickyPromptAutocompleteOption]
  let select: (OpenClickyPromptAutocompleteOption) -> Void

  var body: some View {
    if !options.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(options) { option in
          Button {
            select(option)
          } label: {
            HStack(spacing: 8) {
              Image(systemName: option.systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 18)
              VStack(alignment: .leading, spacing: 1) {
                Text(option.title)
                  .font(.system(size: 11, weight: .heavy))
                  .foregroundColor(DS.Colors.textPrimary)
                  .lineLimit(1)
                Text(option.subtitle)
                  .font(.system(size: 9, weight: .semibold))
                  .foregroundColor(DS.Colors.textSecondary)
                  .lineLimit(1)
              }
              Spacer(minLength: 6)
              Text("Tab")
                .font(.system(size: 8, weight: .black, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .pointerCursor()
        }
      }
      .padding(5)
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface1.opacity(0.98)))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 0.8))
      .shadow(color: Color.black.opacity(0.22), radius: 16, x: 0, y: 8)
    }
  }
}

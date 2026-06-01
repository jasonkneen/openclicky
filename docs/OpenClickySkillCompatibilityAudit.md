# OpenClicky Skill Compatibility Audit

Date: 2026-06-01

This audit maps bundled OpenClicky skills to the capabilities currently implemented or explicitly expected by Agent Mode. It is intentionally conservative: a skill is "gated" when it depends on local tools, credentials, macOS permissions, or provider routes that may not exist in every runtime.

## Priority Checklist

1. **Shared policy** — Add and enforce `AppResources/OpenClicky/OpenClickyBundledSkills/_shared/OpenClickySkillCompatibilityPolicy.md` across bundled skills.
2. **Visual guidance truthfulness** — Keep screen skills aligned with the implemented bridge: point, multi-cursor markers, captions, screenshot, click, clear, speak, notify, batches, and MCP descriptors. Document scribble/highlight as available only through the implemented bridge schemas and overlay renderer.
3. **External write approvals** — Require immediate approval for email/message sends, calendar mutations, cloud document edits, deploys, GitHub merges/releases, playlist/library removals, task completions, deletes, moves, and app-control clicks.
4. **Credential boundaries** — Stop and report missing auth for `gog`, Spotify, Vercel, GitHub, Airtable, Linear, Notion, and similar tools. Do not start OAuth/keychain/passphrase setup unless requested.
5. **Provider capability checks** — Do not advertise image/video generation, slide rendering, Spotify tools, Google Workspace tools, or app-specific CLIs unless exposed by the runtime or verified locally.
6. **macOS permission safety** — Do not intentionally trigger TCC prompts for Accessibility, Screen Recording, Contacts, Calendar, Messages, Reminders, Notes, Mail, Photos, Camera, Microphone, Speech Recognition, or Full Disk Access unless the user asked for setup/testing.
7. **Validation** — Use text/frontmatter checks for skill updates and `swiftc -parse` for targeted Swift files. Do not run terminal `xcodebuild` in the OpenClicky repo.

## Compatibility Matrix

| Skill | Capability Class | Current Match | Main Boundary | Recommended Update |
| --- | --- | --- | --- | --- |
| airtable | External API CRUD | Gated | Requires `AIRTABLE_API_KEY` and network writes | Verify key; approval before record mutation |
| animate | Frontend/code polish | Supported | Local code writes only | Respect project scope and reduced motion |
| apple-notes | macOS app data | Gated | Requires `memo` and Notes permissions | Verify CLI; avoid permission prompts unless setup requested |
| apple-reminders | macOS app data | Gated | Requires `remindctl` and Reminders permissions | Approval before completing/deleting reminders |
| blender | App automation | Gated | Requires Blender/WebSocket/tooling | Verify app/tool; avoid destructive scene edits without approval |
| claude-code | Delegated coding | Gated | Requires Claude Code CLI/auth | Verify CLI; no destructive git actions without approval |
| claude-design | Artifact creation | Partially supported | May assume provider/design tooling | Prefer local HTML artifacts; verify tools |
| codex | Delegated coding | Supported | Current runtime is Codex but nested delegation may vary | Verify CLI before spawning subprocess agents |
| create-onboarding-hello-world | Starter web artifact | Supported | Creates local project files | Keep inside selected project root |
| cua-driver | Computer use | Partially supported | Native/background CUA varies by runtime | Prefer OpenClicky selected computer-use path; verify permissions |
| doc | DOCX workflows | Supported | Python package availability varies | Install only if appropriate; validate output visually where possible |
| excalidraw | Diagram artifact | Supported | Local JSON artifact | Keep outputs user-facing and scoped |
| findmy | macOS personal data | Risky/Gated | Location/privacy sensitive; app automation | Require explicit user request and permissions |
| frontend-design | UI build | Supported | Local writes/build tooling | Use project scope; verify with local preview when feasible |
| github-auth | Credential setup | Gated | Auth/token/SSH setup | Only run setup when explicitly requested |
| github-code-review | GitHub read/write | Gated | `gh`/token and PR comments | Approval before posting comments |
| github-issues | GitHub write | Gated | `gh`/token and issue mutation | Approval before creating/editing issues unless exact request |
| github-pr-workflow | GitHub write | Gated | branch/commit/push/merge | Approval before push/PR/merge/release |
| github-repo-management | GitHub/filesystem | Gated | clone/create/fork/release | Confirm target and external write intent |
| gog | Google Workspace | Gated | local `gog` auth/keyring | Prefer read-only; approval before mutations |
| google-workspace-gogcli | Google Workspace | Gated | local `gog` auth/keyring | Use installed help; approval before sends/edits |
| hallmark | UI/design critique | Supported | May imply broad redesign | Keep scoped; do not over-edit |
| hatch-pet | Image/pet artifact | Partially supported | May require image generation/provider credits | Verify provider/tool before promising generation |
| imessage | Messages | Risky/Gated | `imsg`, Messages/Contacts privacy, sends | Explicit approval before every send |
| learn-from-openclicky-logs | OpenClicky introspection | Supported | Reads/writes logs, memory, learned skills | Archive before replacing; avoid secrets disclosure |
| linear | External API | Gated | `LINEAR_API_KEY`, issue mutation | Approval before create/update/delete |
| maps | Public web APIs | Supported | Network/current data | Cite/verify current data for decisions |
| notion | External API | Gated | `NOTION_API_KEY`, workspace writes | Approval before page/database mutation |
| obsidian | Local notes | Gated | Vault path and local writes | Confirm vault/target before writes |
| ocr-and-documents | Document extraction | Supported | Local files/packages | Respect file locations and privacy |
| openclicky-artifacts | Artifact handling | Supported | Move/rename/delete risk | Approval for destructive moves/deletes |
| openclicky-build-preview | Web build/preview | Supported | Local dev server/build tools | Keep outputs in project directory |
| openclicky-creative-studio | Creative routing | Partially supported | Provider-backed media may be absent | Offer supported artifact formats only |
| openclicky-dev-setup-doctor | Environment repair | Supported | Can touch config/credentials | Ask before credential/auth changes |
| openclicky-email-assistant | Email | Gated | Sends via `gog`/Mail/Gmail are writes | Draft freely; approve before send/mutate |
| openclicky-guided-tutorials | Visual guidance | Supported | Temporary scribble/highlight only | Use point/caption/speak/clear/scribble/highlight |
| openclicky-repo-operator | Repo/GitHub | Supported/Gated | Local git ok; remote writes gated | Approval before commit/push/PR/merge |
| openclicky-research-report | Research artifacts | Supported | Current web/source accuracy | Use web for current facts; produce scoped artifacts |
| openclicky-screen-control | Visual bridge | Supported | Token-gated bridge; coordinate safety | Verify `/mcp/tools`; use temporary scribble/highlight only |
| openclicky-screen-tour | Visual bridge | Supported | Temporary overlays only, no spotlight masks | Clear stale overlays; keep captions short |
| openclicky-specialist-agents | Agent config | Supported | Edits agent metadata/skills | Archive old configs first |
| optimize-openclicky-skills | Skill maintenance | Supported | Edits bundled/learned skills | Archive before replacing; run text validation |
| pdf | PDF workflows | Supported | Dependencies may vary | Render/inspect visually when layout matters |
| polish | UI quality pass | Supported | Local code writes | Keep surgical; respect existing design tokens |
| polymarket | Market data | Gated/Read-only | Financial/prediction-market data | No trading/orders; verify current data |
| powerpoint | PPTX workflows | Partially supported | Slide rendering/dependencies may vary | Do not promise rendered decks unless tools work |
| read-wiki | Memory read | Supported | Personal memory privacy | Read only relevant entries |
| save | Memory write | Supported | Persistent wiki updates | Save only stable/useful facts |
| save-wiki | Memory write | Supported | Persistent wiki updates | Save only with user intent |
| spotify | Spotify tools | Gated | Tool availability and Premium restrictions | Use only exposed Spotify tools; confirm destructive changes |
| spreadsheet | Spreadsheet workflows | Supported | Dependencies/recalculation vary | Validate formulas/rendering where possible |
| vercel-deploy | External deploy | Gated | Publishes URLs and may affect prod | Verify target/account; approve production deploys |
| youtube-content | Web/video transcript | Gated | Transcript helper/network availability | Verify helper/API; cite source when needed |

## Suggested Code Follow-ups

- Add `SkillCapability` metadata parsing for bundled skill frontmatter: `requiresAuth`, `externalWrite`, `macOSPermissions`, `providerTools`, and `visualBridgeTools`.
- Surface capability warnings in Agent Mode before a skill is suggested or injected.
- Keep `OpenClickyExternalControlBridge.mcpToolDescriptors`, `CursorOverlayState`, and `OverlayWindow` synchronized for every new visual overlay type.
- Add unit tests for bridge health/tool descriptors, skill frontmatter validation, and prompt injection of the shared policy.
- Add a lightweight CI/script check that every bundled skill either references the shared compatibility policy or is explicitly marked read-only.

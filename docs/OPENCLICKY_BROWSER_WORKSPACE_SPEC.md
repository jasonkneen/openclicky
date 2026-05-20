# OpenClicky Browser Workspace Spec

Reference mockup: `/Users/jkneen/Library/Application Support/OpenClicky/AgentMode/CodexHome/generated_images/019e46fb-1755-7dd2-aab7-1e97caad1128/ig_01581f08b8b8c678016a0e135957ec8191a35586e2a2094b2a.png`

## Product intent

OpenClicky should support a browser workspace that can show real web sites and local web pages while keeping OpenClicky's own chat interface embedded on the right side of the browser. The user should feel like they are working inside a focused research/build browser, not jumping between a browser, a detached HUD, and separate specialist agents.

The key idea from the mockup is a split workspace:

- Left side: normal browser page canvas for remote URLs, local files, docs, previews, and app pages.
- Right side: OpenClicky's own copied chat component, scoped to the current page and current specialist mode.
- Top/side chrome: lightweight browser controls and workspace navigation, with enough room for tabs, URL, local-page labels, and status.

## Goals

1. Let users browse real websites and local pages inside an OpenClicky-owned workspace.
2. Keep OpenClicky's chat interface visible and context-aware without covering the page.
3. Let specialists operate as mode chips/tabs within the side panel instead of becoming separate hidden sessions.
4. Preserve the familiar OpenClicky composer, transcript rows, tool status, attachments, and actions.
5. Make the page and chat feel connected: page context, selected text, screenshots, DOM/article text, local file metadata, and active task state should flow into the right panel.

## Non-goals for the first pass

- Building a full Chrome replacement.
- Supporting every browser extension behavior.
- Multi-profile cookie/account management beyond the embedded WebKit session chosen for OpenClicky.
- Replacing the existing Agent HUD or main panel.
- Running destructive page automation without explicit user action.

## Primary layout

### Window shell

- macOS dark window with rounded corners and subtle border.
- Top bar includes:
  - Browser back/forward/reload.
  - Address/search field.
  - Tab strip for web pages and local pages.
  - Optional compact workspace controls: capture, pin, split, settings.
- Left optional rail includes compact workspace shortcuts: home, pages, bookmarks/history, local files, tasks/settings.

### Page canvas

The page canvas is the main WebView area. It must support:

- Remote URLs.
- `file://` local HTML pages.
- OpenClicky-generated local previews.
- Local docs rendered as HTML when available.
- App preview routes from local dev servers.

The page should remain fully interactive. The chat panel must not steal focus unless the user clicks or invokes the composer.

### Right OpenClicky chat panel

The side panel is not a generic browser sidebar. It is OpenClicky's own chat interface component rendered inside the browser workspace.

Recommended first-pass dimensions:

- Width: 380-460 pt, default 420 pt.
- Min width: 340 pt.
- Max width: 540 pt or 38% of window width.
- Collapsed width: 52-64 pt icon rail.
- Resizable with a subtle drag handle on the left edge.

Panel sections, top to bottom:

1. Header
   - OpenClicky title.
   - Current page/site indicator.
   - Pin, overflow, close/collapse controls.

2. Specialist chips
   - Example chips: Researcher, Analyst, Writer, Dev.
   - Active chip has purple accent, soft glow, and tooltip/description.
   - Plus button opens specialist picker or custom skill selector.

3. Chat transcript
   - Threaded user/assistant messages.
   - Rich answer cards with references.
   - Per-message actions: copy, save note, cite, continue, make task.
   - Auto-scroll only when user is already near the bottom.

4. Page actions
   - Compact chips for common page-aware actions:
     - Summarize
     - Key takeaways
     - Explain terms
     - Translate
     - Extract links
     - Create task
     - Capture screenshot

5. Tool/status strip
   - Web context: Active / unavailable / permission needed.
   - Memory: On / off / scoped.
   - Notes count.
   - Tasks count.
   - Local page status when applicable.

6. Page context card
   - URL or local path label.
   - Page title.
   - Loaded timestamp.
   - Word count or DOM/text extraction count.
   - Green freshness dot if current.
   - Refocus button to return focus to the page.

7. Composer
   - Same OpenClicky prompt composer behavior as the main panel/HUD.
   - Multiline wrapping and vertical growth.
   - Shift+Enter inserts newline.
   - Enter sends.
   - Attachment, @ mention, slash command, code/context, screenshot, and tool buttons.

## Interaction model

### Opening the workspace

Entrypoints:

- From a URL in chat: “Open in OpenClicky browser”.
- From local HTML/docs: “Preview with OpenClicky”.
- From Connect/specialist surfaces: “Open browser workspace”.
- From Agent result artifacts: open generated page in workspace.
- From current screen/browser context: “Bring this page into OpenClicky”.

### Page-to-chat context

OpenClicky should attach context in layers:

1. Basic metadata: URL, title, favicon, load state.
2. Readable text extraction: article/main content when available.
3. Selection context: selected text, clicked element, visible viewport.
4. Visual context: screenshot of page or visible viewport when needed.
5. Local context: file path, dev server route, project/repo metadata when local.

The panel should show what context is active instead of silently guessing.

### Specialist behavior

Specialist chips switch the instruction lens for the current chat, not the visible workspace.

- Researcher: summarize, compare, cite, extract claims.
- Analyst: structure, evaluate, identify risks or decisions.
- Writer: rewrite, draft, turn page into notes or posts.
- Dev: inspect local pages, explain UI/code behavior, suggest implementation steps.

Switching specialists should preserve the transcript but clearly mark the new mode for future responses. If a specialist needs a long-running task, it should create an Agent Mode task and surface it in the same side panel.

### Local page support

Local web pages are first-class:

- Load `file://` pages with clear local-file labeling.
- Load localhost pages from dev servers.
- Offer reload, open in external browser, reveal in Finder, and copy path/URL.
- For local projects, optionally attach repo root and branch if discoverable.
- Avoid broad filesystem access unless the user asks or selects a folder.

### Privacy and permission prompts

- Web context extraction should be visible through the status strip.
- For sensitive pages, show “context limited” and use explicit capture/extract actions.
- Never store page content in durable memory unless the user asks or the outcome is a stable preference/project fact.
- Local page paths may be shown in the UI, but avoid sending full filesystem trees unless needed.

## Visual design notes from the mockup

- Keep the page canvas visually calm and wide.
- Use dark, frosted, Liquid Glass-style side panel surfaces.
- Purple remains the main OpenClicky accent for active specialists and send controls.
- Use small status dots rather than large banners.
- Cards should have subtle borders, not heavy panels.
- The chat panel should look native to OpenClicky, not like an iframe from another product.
- The side panel can float slightly within the browser shell, but should remain aligned and docked.

## Technical architecture sketch

### Suggested components

- `OpenClickyBrowserWorkspaceWindowManager`
  - Owns the window lifecycle and sizing.
  - Coordinates tabs and split layout.

- `OpenClickyBrowserWorkspaceView`
  - SwiftUI shell for toolbar, tab strip, rail, WebView, and side panel.

- `OpenClickyWorkspaceWebView`
  - WebKit wrapper for remote/local content.
  - Emits page metadata, navigation state, selection state, and snapshots.

- `OpenClickyBrowserChatSidePanel`
  - Reuses the existing OpenClicky chat component where possible.
  - Injects page-scoped context provider and specialist chip bar.

- `OpenClickyWebContextProvider`
  - Converts current page state into compact model context.
  - Handles readable text extraction, selected text, screenshot metadata, and local-page metadata.

- `OpenClickyBrowserSpecialistMode`
  - Defines specialist chip metadata and prompt overlays.

### Reuse existing OpenClicky surfaces

Prefer reusing these existing patterns rather than building new interaction rules:

- Existing chat transcript row styling.
- Existing prompt composer, including multiline behavior and slash/@ autocomplete caps.
- Existing Agent Mode task creation path for long-running work.
- Existing attachment/context chips.
- Existing Liquid Glass or panel backdrop helpers if present.

## MVP phases

### Phase 1: Static workspace shell

Deliver a window with:

- WebView loading remote URLs and local files.
- Right docked chat side panel using placeholder messages.
- Specialist chips as visual-only mode controls.
- Address bar, reload, and basic navigation.

Success criteria:

- A real website and a local HTML file can both be opened.
- The right panel stays docked and resizable.
- Page interactions do not get blocked by chat UI.

### Phase 2: Real OpenClicky chat integration

Deliver:

- Reused OpenClicky composer and transcript.
- Page metadata context card.
- Basic page-aware prompts: summarize, key takeaways, explain terms.
- Current URL/title attached to chat requests.

Success criteria:

- Asking about the current page includes the right URL/title.
- The composer behaves like the main OpenClicky composer.
- Specialist switching changes response style without losing the thread.

### Phase 3: Context extraction and local pages

Deliver:

- Readable page text extraction.
- Selected text handoff.
- Visible viewport screenshot handoff.
- Local file path/dev server detection.
- Context status strip with clear active/unavailable states.

Success criteria:

- OpenClicky can summarize a real article from page text.
- OpenClicky can explain selected text.
- OpenClicky can inspect a local preview with URL/path context.

### Phase 4: Agent task and specialist workflow

Deliver:

- Create Agent Mode tasks from the side panel.
- Show running task state inline.
- Specialist chips can launch scoped task templates.
- Results return to the same browser workspace thread.

Success criteria:

- User can ask “Research this page” and see a running task in-panel.
- User can continue from the result without leaving the workspace.
- Closing/collapsing the panel does not lose task state.

## Open questions

1. Should the workspace use a shared OpenClicky WebKit process pool or a separate ephemeral session by default?
2. Should specialist chips be global presets, user-configurable learned skills, or both?
3. Should the side panel thread be one thread per tab, one thread per window, or manually pinned by the user?
4. Should local file browsing be single-file only at first, or include a folder/project picker?
5. How much browser chrome should be shown when launched from an Agent artifact versus manually opened as a browser workspace?

## First implementation recommendation

Start with a narrow, non-invasive prototype: one new browser workspace window, one WebView, one copied OpenClicky chat panel layout, and mock specialist chips. Once the shell feels right, wire the composer to the existing chat pipeline with a small page-context object containing URL, title, selected text, and optional extracted body text.

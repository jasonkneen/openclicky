---
name: create-onboarding-hello-world
description: Build the small "hello {name}" website that OpenClicky can create as a quick starter task. Use this skill when the user asks for a fun hello-world site for themselves. Handles where to read the user's name from, where to save the file, and what the finished page should feel like.
---

You are building a tiny single-file HTML site that greets the current OpenClicky user by name. It needs to feel alive and personal on the first open.

## 1. Find the user's name
Try these sources in order and stop at the first one that gives you a real first name. Do **not** ask the user — the whole point is that OpenClicky already knows who they are.
Move to the next step as soon as you find out the user's name.

1. **The macOS account's full name**:
   ```bash
   id -F            # full name, e.g. "Jason Kneen"
   # or: dscl . -read /Users/$(whoami) RealName
   ```
   Use the first token.

2. If that fails, use the macOS username from `whoami` and title-case it if it looks like a name.

3. If every source fails, fall back to `there` so the page says `hello there`.

## 2. Where to save the file

Save directly into your default agent projects directory — **not** the Desktop, not `~/Documents`, not the repo you were last looking at.

Concretely: write the file to `hello-<firstname>.html` relative to your current working directory (your cwd is already `~/Library/Application Support/OpenClicky/projects`, so the full path becomes `~/Library/Application Support/OpenClicky/projects/hello-<firstname>.html`).

Use a lowercased first name in the filename (`hello-kamil.html`, `hello-jason.html`).

After writing, `open` the file so the browser launches immediately.

## 3. What the page should feel like

A single self-contained `.html` file. No build step, no external frameworks, no dependencies. Inline CSS and inline JS, if needed, inside the same file.

Two hard requirements:

- **Responsive** — looks good on a laptop screen and doesn't fall apart on a narrow window. Use fluid sizing (`clamp`, `min`, `%`, `vw`) instead of fixed pixel widths.
- **Full-screen** — the page fills the viewport (no tiny card floating in a sea of white). The greeting is the whole experience.

Everything else — layout, palette, typography, motion, illustration, copy, overall aesthetic — is yours to invent. Pick a clear point of view and commit to it. Avoid the generic centered-card AI look.

## 4. Make it feel personal to *this* user

This is the part that stops every generation from looking the same. Before you start coding, spend a moment thinking about *who* you're making this for, then let every piece of on-page copy reflect that person.

**Read clues from whatever you have available:**

- What does their name, email domain, or macOS username hint at? (A work email → they may be a builder/founder. A personal email → more casual. A distinctive first name → lean into it.)

**Every word on the page is for the user, not about the page.** This is the most common failure mode: agents slap generic meta stickers on the hero like "Responsive website", "Full screen", "Made with HTML & CSS", "Plain HTML and a dash of motion", "Made on this Mac". Do not do that. The page should never narrate what it is. Instead, the on-page copy should be things *directed at* the user — a warm personal greeting, a tiny joke that fits them, a line that nods to what they're working on, a compliment, a playful prediction, a "welcome to your new little corner" kind of vibe. If you're tempted to write a label describing the site itself, cut it.

Good examples of personal on-page copy:

- `hello NKamil - this is a postcard for my new best friend`
- `your menu bar just got a little friendlier`
- a sticker that says `coffee break?` next to the headline

Bad examples (avoid):

- `simple HTML hello world`
- `responsive · animated · single file`
- `made with love and CSS`

## 5. After you write the file

1. `open <path>` so the browser launches immediately.
2. Keep the final answer short — one sentence confirming what you made and where, since OpenClicky will read it aloud.

## Simplicity.
Don't ocercomplicate the design and information. It's a simple fast project, so don't spend on it more than 60 seconds.

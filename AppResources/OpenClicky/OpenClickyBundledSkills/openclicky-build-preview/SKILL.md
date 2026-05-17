---
name: openclicky-build-preview
description: Build, modify, launch, preview, and iterate websites, web apps, dashboards, landing pages, HTML files, React/Next apps, and frontend UI. Use when the user wants a visible working thing, not only code.
---

# OpenClicky Build Preview

Build the thing, launch it when appropriate, show or report where it is, and iterate. This workflow absorbs frontend design, polish, and animation guidance without exposing those raw skills separately.

## Use When
- The user asks to build a website, app, dashboard, landing page, HTML file, frontend component, or local preview.
- The user asks to open, preview, or revise a generated site/app.
- The request includes UI polish, animation, responsiveness, or visual design fixes.

## Do Not Use When
- The task is primarily GitHub/PR/CI/repo workflow; use `openclicky-repo-operator`.
- The task is primarily localhost/toolchain failure; use `openclicky-dev-setup-doctor`.
- The task is only finding/opening an existing generated file; use `openclicky-artifacts`.

## Primary Path
1. Detect the stack and package manager.
2. Make scoped code changes using existing project patterns.
3. Use high-quality frontend rules: strong hierarchy, responsive layout, accessible controls, tasteful motion, no generic filler.
4. Start or reuse a local dev server when needed.
5. Verify with normal local checks first: file existence, server response, build output, and targeted browser/page checks when available.
6. Use `openclicky-artifacts` for static HTML files and saved outputs.

## Fallbacks
- For one-off pages, create a single HTML/CSS/JS file and open/reveal it.
- If the request turns into operating an existing app or logged-in browser UI, stop this build workflow and route to the visible GUI workflow instead of treating it as preview verification.
- If dependencies fail, route to `openclicky-dev-setup-doctor`.

## Safety
- Do not refactor unrelated code.
- Do not overwrite user files unless asked.
- Avoid foregrounding or hijacking the user's browser; show the URL/path instead when enough.
- Do not use browser-specific shell launches such as `open -a Google Chrome` as a preview loop. If the user asked to see a finished local file, use the artifact/open path late and deliberately.

## Artifacts
- End with the local URL or absolute file path.
- For generated static pages, save under a stable project or `output/builds/<slug>/` path.
- Use `openclicky-artifacts` for open/reveal requests.

## Verification
- Run the project's relevant checks when reasonable.
- For frontend work, verify the page loads and key UI states render using local
  server responses, page/browser test tools, screenshots, or generated files
  before handing the result back.
- If visual inspection is not possible, say what was verified and what remains.

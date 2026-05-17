---
name: frontend-design
description: Build or improve frontend UI for websites, apps, dashboards, landing pages, and local previews. Use when the user asks for a working interface, visual redesign, UI polish, layout fixes, responsive behavior, or purposeful animation/micro-interactions. Do not use for static documents, Google Workspace tasks, or GUI clicking through an existing app.
---

# Frontend Design

Create working frontend code that looks intentional, not generic. This skill
absorbs the useful parts of the old standalone design, polish, and animation
skills into one curated UI path.

## Use When
- The user asks to build a website, web app, dashboard, landing page, component, or HTML prototype.
- The user asks to redesign, polish, make prettier, improve layout, add visual hierarchy, or make UI responsive.
- The user asks for frontend motion: button animations, hover states, page transitions, loading states, or micro-interactions.

## Do Not Use When
- The deliverable is a PDF, DOCX, spreadsheet, email, Google Workspace item, or local file operation.
- The user wants to click through an existing app or browser UI; route that visible GUI work outside this frontend build workflow.
- The request is only a codebase/PR/CI task with no UI outcome.

## Primary Path
1. Identify the target project or output file.
2. Detect the stack and reuse existing framework, component, style, and token conventions.
3. Build the smallest complete working UI that satisfies the request.
4. Add polish only after the UI works: spacing, typography, states, contrast, responsiveness, and copy fit.
5. Add motion only when it improves feedback, flow, or delight. Respect `prefers-reduced-motion`.
6. Launch or point to the preview when possible; otherwise provide the exact file path.

## Design Rules
- Match the domain. SaaS, CRM, dashboards, and ops tools should be quiet, dense, and scannable. Games, portfolios, creative tools, and marketing pages can be more expressive.
- Avoid generic AI aesthetics: purple gradients, floating blobs, oversized cards, fake feature copy, and decorative noise that does not serve the product.
- Do not put UI cards inside other cards.
- Use real controls: icons for icon actions, toggles for booleans, sliders/inputs for numbers, tabs for view switching, menus for option sets.
- Text must fit inside its container on mobile and desktop. Do not scale font size with viewport width.
- Keep page sections full-width or unframed; reserve cards for repeated items, modals, and actual tools.

## Motion Rules
- Prefer one strong motion idea over many scattered animations.
- Animate `transform` and `opacity`; avoid layout jank.
- Use short durations: 100-150ms for immediate feedback, 200-300ms for state changes, 300-500ms for larger layout transitions.
- Always preserve a non-animated path for reduced-motion users.

## Verification
- Run the project check or build command when reasonable.
- For local previews, verify the URL responds or the HTML file exists.
- Inspect at least one narrow and one desktop viewport when the task is visual,
  using local preview tooling, page/browser test tools, rendered screenshots, or
  artifact files.
- Do not turn frontend visual inspection into visible app/browser operation.
- If visual verification is blocked, say exactly what was checked and what remains.

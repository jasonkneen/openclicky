---
name: openclicky-creative-studio
description: "Route broad creative work to available OpenClicky capabilities: frontend polish, design critique, brand/social planning, document/PDF outputs, spreadsheet/table outputs, and existing visual artifact handling. Provider-backed image, video, motion, and new slide/deck generation are not shipped unless the runtime explicitly exposes those capabilities."
---

## OpenClicky compatibility guardrails

- Follow `../_shared/OpenClickySkillCompatibilityPolicy.md` before acting.
- Verify required local commands, tools, keys, or bridge endpoints before promising execution.
- Treat sends, publishes, deploys, deletes, moves, merges, playlist/library changes, cloud writes, and app-control clicks as external writes unless this skill narrows them further.
- Stop and report the exact missing setup step for unavailable tools, auth, or macOS permissions; do not loop or silently switch to browser automation.

# OpenClicky Creative Studio

Route creative work to the right available medium. Do not make everything an image prompt; choose the production path that gives the user a reliable artifact, and report blockers for unshipped provider-backed routes.

## Use When
- The user asks for image/photo work, brand/logo/moodboard work, motion/video, existing slides/decks, design critique, UI polish, social graphics, or carousels.
- The output should be visual and saved/opened.
- The task crosses multiple creative tools or formats.

## Do Not Use When
- The task is only a website/app/dashboard implementation; use `openclicky-build-preview`.
- The task is only opening or finding a finished creative artifact; use `openclicky-artifacts`.
- The user asks for normal frontend animations inside a site/app; use `openclicky-build-preview` or `frontend-design` directly.

## Primary Path
1. Choose the available medium:
   - `openclicky-build-preview` and `frontend-design` for frontend/UI implementation, critique, and polish.
   - `pdf`, `doc`, and `spreadsheet` for document/report/table outputs.
   - Report missing runtime capability for provider-backed image generation, provider-backed video generation, dedicated motion/video generation, or new slide/deck generation unless those skills/tools are actually exposed.
   - For new deck requests in this release, offer an outline, speaker notes, Markdown/PDF report, DOCX brief, or frontend-style visual artifact instead of trying image-rendered slides.
2. Keep real text, charts, captions, and precise UI in code or document layers when possible.
3. Verify representative frames/pages/images before final delivery.
4. Broad creative requests may start here, but direct requests for unshipped image, slide, video, or motion generation must report the missing runtime and offer an available document, PDF, spreadsheet, or frontend alternative.

## Fallbacks
- Use Cua/Computer Use through `cua-driver` only for operating a visible creative app, not for normal asset generation.
- If editable PPTX is required and no real presentation runtime is exposed, report that deck generation is not shipped in this build.
- If a provider route, auth token, binary, or API proxy is unavailable, explain the exact missing capability and the setup/auth action needed rather than silently downgrading. If the capability is intentionally not shipped, do not call it an auth problem.

## Safety
- Do not use external brand assets or personal images beyond what the user provided or approved.
- Preserve user files; create versioned outputs unless replacement was requested.
- Ask before posting, sending, or modifying third-party creative tools/accounts.

## Artifacts
- Save under `output/creative/<slug>/` or the owning workflow's stable output folder depending on medium.
- Use `openclicky-artifacts` to open/reveal final files. For deck/image/video outputs, only do this when the artifact already exists or a real runtime created it.

## Verification
- Inspect generated images or key frames.
- For provider-backed images, videos, or decks, report the missing runtime capability unless a real tool is exposed. Do not suggest retrying a route that is not shipped.

## Provider capability boundary

Do not promise provider-backed image generation, video generation, new slide/deck rendering, or complex design extraction unless the runtime exposes that capability. Offer available alternatives: frontend prototypes, markdown reports, PDFs, DOCX, CSV/XLSX, Excalidraw JSON, screenshots, or design critique.

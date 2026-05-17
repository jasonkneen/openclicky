---
name: openclicky-research-report
description: Research a topic, market, competitor set, product, person, or question and turn findings into a useful Markdown, PDF, DOCX, CSV, or brief artifact. Use for competitor research, market intel, source-backed summaries, web research, research briefs, and shareable reports.
---

# OpenClicky Research Report

Turn research into a finished artifact. Prefer search, fetch, curl/API access, source files, and local extraction before any GUI/browser work. Use Cua/Computer Use only when the source truly requires logged-in or visible browser interaction and the runtime exposes that capability.

## Use When
- The user asks for research, a report, brief, competitor analysis, market map, list, source summary, or PDF.
- The output should be saved, exported, opened, or shared.
- The work needs sources, citations, tables, or a polished written artifact.

## Do Not Use When
- The user mainly wants to click through a visible website or app; use `cua-driver` only when Computer Use is exposed for that GUI control.
- The user only wants to open/find a previously created report; use `openclicky-artifacts`.
- The user asks about private Google Workspace files or email; start with `google-workspace-gogcli`.

## Primary Path
1. Restate the research target in operational terms: question, scope, geography/timeframe, and output format.
2. Gather sources with search/fetch/curl/API paths first.
3. Extract facts into a concise outline before writing the artifact.
4. Use internal capabilities as needed:
   - `pdf` and `doc` for report artifacts.
   - `spreadsheet` for source tables, CSVs, and comparison matrices.
   - `openclicky-artifacts` for final open/reveal/export.
   - `frontend-design` only when the requested output is a website/dashboard/report UI.

## Fallbacks
- Use Cua/Computer Use when sites require interactive pages, login, JavaScript-only content, or visible page inspection and the runtime exposes that capability.
- If provider-backed image, video, or slide generation is requested, report that those provider routes are not shipped in this release unless a real runtime capability is exposed. Do not frame unshipped slide/image routes as retryable auth failures.
- If live web access is blocked, create a grounded report from provided files/screenshots and call out missing live sources.
- If the user did not name an output format, default to Markdown plus PDF when the report is shareable.

## Safety
- Cite sources or name source files for factual claims.
- Separate verified facts from inference.
- Do not use GUI browser control for normal research when search/fetch/curl/source files are enough.

## Artifacts
- Save under `output/reports/<slug>/` unless the user gave a destination.
- Include source notes, the final report, and any exported PDF/DOCX/CSV.
- End by opening or revealing the final artifact through `openclicky-artifacts`.

## Verification
- Confirm the artifact exists.
- For PDFs, render or inspect at least the first page when possible.
- Confirm tables, citations/source notes, and the user-requested scope are present.

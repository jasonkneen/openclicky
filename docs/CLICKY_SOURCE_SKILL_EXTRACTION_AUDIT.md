# Clicky Source Skill Extraction Audit

Date: 2026-06-17

## Scope

The primary Clicky source reviewed was:

- `/Applications/Clicky.app`

Relevant resources inside it:

- `/Applications/Clicky.app/Contents/Resources`

Additional editable source material was found in:
- `/Users/jkneen/Documents/GitHub/clicky-with-skills`

OpenClicky target root:

- `/Users/jkneen/Documents/GitHub/openclicky/AppResources/OpenClicky`

## Source Bundle Inventory

The installed app bundle contains:

- 28 top-level markdown resources under `/Applications/Clicky.app/Contents/Resources`
- 15 bundled skill folders under `/Applications/Clicky.app/Contents/Resources/ClickyBundledSkills`
- 15 `SKILL.md` files
- 5 additional markdown support files inside skill folders
- 10 non-markdown support files inside skill folders

Top-level markdown resources:

- `AGENTS.md`
- `ATTRIBUTION.md`
- `ClickyModelInstructions.md`
- `airtable.md`
- `apple-notes.md`
- `apple-reminders.md`
- `blender.md`
- `claude-code.md`
- `claude-design.md`
- `codex.md`
- `excalidraw.md`
- `findmy.md`
- `github-auth.md`
- `github-code-review.md`
- `github-issues.md`
- `github-pr-workflow.md`
- `github-repo-management.md`
- `google-workspace.md`
- `imessage.md`
- `linear.md`
- `maps.md`
- `notion.md`
- `obsidian.md`
- `ocr-and-documents.md`
- `polymarket.md`
- `powerpoint.md`
- `spotify.md`
- `youtube-content.md`

Bundled skill folders:

- `clicky-artifacts`
- `clicky-build-preview`
- `clicky-creative-studio`
- `clicky-dev-setup-doctor`
- `clicky-email-assistant`
- `clicky-google-workspace`
- `clicky-repo-operator`
- `clicky-research-report`
- `cua-driver`
- `doc`
- `frontend-design`
- `obsidian`
- `pdf`
- `spreadsheet`
- `vercel-deploy`

Skill support files:

- `cua-driver/README.md`
- `cua-driver/RECORDING.md`
- `cua-driver/TESTS.md`
- `cua-driver/WEB_APPS.md`
- `doc/scripts/render_docx.py`
- `spreadsheet/references/examples/openpyxl/create_basic_spreadsheet.py`
- `spreadsheet/references/examples/openpyxl/create_spreadsheet_with_styling.py`
- `spreadsheet/references/examples/openpyxl/read_existing_spreadsheet.py`
- `spreadsheet/references/examples/openpyxl/styling_spreadsheet.py`
- `vercel-deploy/ATTRIBUTION.md`
- `vercel-deploy/LICENSE.txt`
- `vercel-deploy/agents/openai.yaml`
- `vercel-deploy/assets/vercel-small.svg`
- `vercel-deploy/assets/vercel.png`
- `vercel-deploy/scripts/deploy.sh`

## Target Repo Inventory

OpenClicky currently contains:

- 29 top-level markdown resources under `AppResources/OpenClicky`
- 62 bundled skills with `SKILL.md`
- 200 files under `AppResources/OpenClicky/OpenClickyBundledSkills`
- Shared policy folder: `OpenClickyBundledSkills/_shared`

Every source bundled-skill folder name from the installed app is represented in OpenClicky's current bundled-skill tree. There are no source-only `SKILL.md` folders in the installed bundle that are missing from OpenClicky.

## Comparison Results

Top-level markdown:

- `ATTRIBUTION.md` and the tool markdown files are byte-identical between the installed bundle and OpenClicky.
- `AGENTS.md` differs because OpenClicky adds current product/resource policy.
- `ClickyModelInstructions.md` maps to `OpenClickyModelInstructions.md` and differs because OpenClicky adds current product/resource policy.

Bundled skills:

- Every source `ClickyBundledSkills/<skill>` folder has a corresponding OpenClicky skill folder.
- Common skill files differ where OpenClicky has product naming, bundled-resource policy, and CUA route-contract updates.
- Do not overwrite OpenClicky bundled skills wholesale from the installed app bundle.
- Useful Clicky-only safety text was migrated selectively:
  - Gmail draft/send schema and read-back verification rules were adapted into `clicky-email-assistant` and `openclicky-email-assistant`.
  - Google Docs/Sheets write verification rules were adapted into `clicky-google-workspace`, `google-workspace-gogcli`, and `gog`.
  - OpenClicky's local `gog` route remains preferred over legacy Clicky Composio routing.

Most product-specific source files needing review before any future import:

- `ClickyBundledSkills/cua-driver/SKILL.md`
- `ClickyBundledSkills/cua-driver/README.md`
- `ClickyBundledSkills/cua-driver/WEB_APPS.md`
- `ClickyModelInstructions.md`
- `AGENTS.md`
- `Info.plist`
- `clicky-*` skill folders

## Clicky-With-Skills App Contexts

The editable `clicky-with-skills` source contains JSON app-skill definitions under:

- `/Users/jkneen/Documents/GitHub/clicky-with-skills/leanring-buddy/skills`

Files:

- `com.adobe.AdobePremierePro.json`
- `com.apple.FinalCut.json`
- `com.apple.Terminal.json`
- `com.apple.dt.Xcode.json`
- `com.figma.Desktop.json`
- `com.microsoft.Excel.json`
- `com.microsoft.VSCode.json`
- `com.shopify.shopify.json`
- `notion.id.json`
- `org.blender.blender.json`

OpenClicky already represents these as Swift context in `cursor-buddy/OpenClickyAppSkillContext.swift`, not as JSON resources. The useful missing source material was:

- full per-app `system_prompt` interface context
- one missing Adobe Premiere workflow step
- two missing Shopify workflow steps

Those were absorbed into `OpenClickyAppSkillContext.swift` instead of adding a parallel JSON-loading path.

The imported context was normalized for OpenClicky's macOS runtime where the source JSON used Windows-style shortcuts or obvious source typos.

## Migration Rules

- Preserve user-facing product name `OpenClicky`.
- Preserve bundle identifier `com.jkneen.openclicky`.
- Preserve legacy `cursor-buddy` folder and scheme names.
- Keep `OpenClickyBundledSkills/_shared/OpenClickySkillCompatibilityPolicy.md` as the policy layer for bundled skill behavior.
- Keep CUA/computer-use routes distinct: native Swift CUA, foreground `NSWorkspace` opens, Background Computer Use, and external-control bridge are separate paths.
- Use `swiftc -parse <relevant Swift source files>` for lightweight verification; do not run terminal `xcodebuild`.

## Re-run Commands

```sh
find /Applications/Clicky.app/Contents/Resources -type f \( -iname 'AGENTS.md' -o -iname 'README.md' -o -iname 'SKILL.md' -o -iname '*.md' \) | sort
diff -qr /Applications/Clicky.app/Contents/Resources/ClickyBundledSkills /Users/jkneen/Documents/GitHub/openclicky/AppResources/OpenClicky/OpenClickyBundledSkills
find /Users/jkneen/Documents/GitHub/clicky-with-skills/leanring-buddy/skills -type f -name '*.json' | sort
```

---
name: openclicky-artifacts
description: Open, reveal, find, export, rename, move, organize, or explain existing OpenClicky-generated files and local artifacts. Use when the user asks where a PDF, CSV, DOCX, PPTX, XLSX, HTML page, report, deck, video, image, or generated file went, asks to open it again, show it in Finder, export it, or organize it. Do not use for creating the content from scratch unless another workflow already produced the artifact.
---

# OpenClicky Artifacts

Manage concrete files created or touched by OpenClicky. This workflow wraps the available file/document capabilities so every artifact job ends with an exact path, an opened/revealed file, or a clear blocker.

## Use When
- The user asks to open, reveal, find, rename, move, delete, export, or organize a local file or folder.
- The user asks "where did it save?", "open it again", "show it in Finder", or "open the PDF/CSV/deck/report".
- Another workflow created an artifact and needs a final open/reveal/export step.

## Do Not Use When
- The user is asking to research, write, design, or generate the artifact from scratch; start with the owning workflow first.
- The user asks to save knowledge for later memory; use `save-wiki`.
- The task requires operating a visible app UI; use `cua-driver` for that Computer Use step.

## Primary Path
1. Identify the target artifact from the current task, latest generated output, nearby `output/` folder, desktop/downloads, or explicit filename.
2. Prefer exact filesystem paths over guesses. Use `find`, `rg --files`, local app output conventions, and file metadata.
3. Use internal skills as implementation details:
   - `pdf` for PDF rendering, review, and export.
   - `doc` for DOCX work.
   - `spreadsheet` for CSV/XLSX work.
   - `save-wiki` only for wiki/knowledge capture.
4. Open or reveal the artifact only after verifying it exists. For browser-viewable files, do not use browser-specific shell launches like `open -a Google Chrome`; use the default handler or the Computer Use path when real browser control is required.

## Fallbacks
- If no exact path is known, search likely output roots first: current workspace, `output/`, `tmp/`, Desktop, Downloads, and OpenClicky Application Support.
- If several candidates match, choose the newest relevant file and mention the candidate count.
- If the artifact was never created, say so and offer the next concrete creation step.

## Safety
- Preview destructive operations: deletes, overwrites, bulk moves, and folder cleanup require explicit confirmation.
- Do not hide uncertainty. If the path is inferred, label it as inferred.
- Do not overwrite existing files unless the user explicitly requested replacement.

## Artifacts
- Always end with the absolute path.
- For generated artifacts, prefer stable output folders like `output/<type>/<slug>/`.
- When opening/revealing fails, report the failure and still provide the path.

## Verification
- Check that the file exists and has nonzero size.
- For PDFs and existing images/decks/videos, render or inspect a representative preview when the user cares about visual correctness. Do not invoke unshipped image, video, or deck generation providers just to create a preview.
- For spreadsheets/documents, verify the intended sheet/page/file count or exported format when possible.

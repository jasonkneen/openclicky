---
name: save
description: Ingest links, screenshots, and notes into a personal knowledge wiki. The wiki is a persistent, compounding artifact. Use when the user says "save", "remember", "note this", or wants to capture information for later.
argument-hint: "[url | screenshot path | text]"
---

# LLM Wiki — Ingest

Inspired by Karpathy's LLM Wiki pattern. The wiki is a persistent, compounding artifact — a structured, interlinked markdown collection sitting between you and raw sources. When adding a new source, you read it, extract key information, and integrate it into the existing wiki: updating entity pages, revising summaries, adding cross-references, noting contradictions.

The tedious part of maintaining a knowledge base is not the reading or the thinking — it's the bookkeeping. That's your job.

## Wiki location

The wiki lives at: `~/Library/Application Support/OpenClicky/wiki/`

All paths below are relative to that root. Always use the full expanded path when reading/writing files.

## Three layers

```
~/Library/Application Support/OpenClicky/wiki/
  raw/          # Immutable source snapshots (what came in)
  wiki/         # The compiled knowledge base (what it means)
```

**Raw sources** are immutable. Once saved, never modified. They're the receipts.

**The wiki** is alive. Articles get created, updated, merged, split, restructured. It compounds with every ingest.

## Bootstrapping (empty wiki)

If `wiki/` or `raw/` don't exist, create the full structure before doing anything:

```
wiki/
  _index.md
  _backlinks.json
  media/
raw/
  sources.jsonl
```

`wiki/_index.md`:
```markdown
# Wiki Index

Articles listed with aliases for matching.
```

`wiki/_backlinks.json`:
```json
{}
```

`raw/sources.jsonl`: empty file. Each line will be a JSON object logging what was ingested.

## Ingest: the core operation

Every `/save` is an ingest. Something new enters the system and the wiki must absorb it.

### Step 1: Understand the input

**The user's note is the source of truth for intent.** What they typed or said out loud tells you *what* to save and *why it matters*. The screenshot is supporting context — proof of what they were looking at — not a menu of things to catalog.

**Read the user's note first, then look at the screenshot through the lens of that note.** If the note says "save this article about founder mode," you extract the article's argument and ignore the sidebar ads, the open tabs, the menu bar clock, the 14 other things visible on screen. If the user didn't call something out, it doesn't belong in the wiki.

**Do not over-index on the screenshot.**

- Never add facts, entities, or sections to the wiki just because they were visible in the screenshot. Incidental UI (browser chrome, other tabs, open apps, the dock, notifications, unrelated windows) is noise, not content.
- If the user's note is vague ("save this"), infer the *single thing they were likely pointing at* from context clues — the active window, the foregrounded text, what's centered on screen — and stick to that. Do not write a summary of the whole desktop.
- Do not invent commentary, observations, or "interesting details" about things the user didn't mention.

**Use your own vision to read every image.** Do not run OCR tools, Swift scripts, or external programs — you can see images directly. But only extract what's relevant to the user's note: names, dates, URLs, quotes, and context *about the thing they asked to save*.

- If the image is visually important *to what the user is saving* (a diagram they reference, a design they want to capture, a photo they called out), copy it to `wiki/media/` and embed it. If it's just a vehicle for text (screenshot of a tweet, a note), extract the information and don't save the image.
- URLs: Fetch with WebFetch only when the user's note points you at a linked source. Extract meaningful content, discard boilerplate.
- Multiple inputs at once are one unit. Process them together.
- When the user's note and the screenshot disagree about scope, trust the note.

Log every ingest to `raw/sources.jsonl` as one JSON line:
```json
{"id": "2026-04-13-001", "date": "2026-04-13", "type": "screenshot", "summary": "Tweet from @karpathy about LLM wiki pattern", "articles_touched": ["LLM Wiki", "Andrej Karpathy"]}
```

### Step 2: Read the index

Read `wiki/_index.md`. This is your map of everything the wiki already knows. Each entry has aliases (`also:` field) for fuzzy matching — use them.

### Step 3: Plan from the index

Using only the index from Step 2, decide:

1. **What entities are in this source?** Match against index entries and aliases.
2. **Which existing articles will you update?** Only these get read in Step 4.
3. **What new articles will you create?**

Do not read any wiki or raw files in this step. The index has enough context to plan.

### Step 4: Update and create articles

**Read only the articles you will modify.** Re-read each one in full before updating it. Do not read articles for exploratory context — the index is sufficient for planning. Do not read any files in `raw/` — they are immutable receipts and their format is defined in this document.

**Integration, not appending.** The wiki article should read as a coherent whole. New information gets woven into existing sections or motivates new sections. Never just tack a paragraph onto the bottom.

**Every article you touch must get meaningfully better.** Not a sentence added — a section, a paragraph with context, a new connection revealed. If you can't add meaningful substance, don't touch it.

**Contradictions get flagged.** If a new source contradicts what the wiki says, add a note:
```markdown
> [!contradiction] The source from 2026-04-13 claims X, but [[Other Article]] states Y (sourced 2026-03-01). Needs resolution.
```

**Create new articles when warranted.** If an entity appears with enough substance for 3+ meaningful sentences, it deserves a page. If not, mention it in the most relevant existing article and revisit later.

### Step 5: Update the bookkeeping

After every ingest:

1. **`_index.md`** — add entries for any new articles. Update aliases if the source reveals new ways to refer to existing entities.
2. **`_backlinks.json`** — rebuild by scanning all `[[wikilinks]]` across all wiki articles. Every article title maps to the list of articles that link to it.

## Article format

```markdown
---
title: Article Title
type: person | project | concept | reference | idea | entity
created: YYYY-MM-DD
last_updated: YYYY-MM-DD
source_count: 3
related: ["[[Other Article]]"]
---

# Article Title

{Content organized by theme, not chronology}
```

`source_count` tracks how many raw sources have contributed to this article. It's a rough measure of how well-sourced the page is.

## Naming and structure

**File names:** lowercase, hyphenated, in a type directory.
- `people/paul-graham.md`
- `concepts/founder-mode.md`
- `projects/stripe.md`
- `references/pg-founder-mode-essay.md`
- `ideas/ai-onboarding-flow.md`

**Rules:**
- Most recognizable name. `paul-graham.md`, not `graham-paul.md`.
- Short and specific. `founder-mode.md`, not `what-it-means-to-be-in-founder-mode.md`.
- Disambiguate when needed: `mercury-banking.md` vs `mercury-element.md`.
- No dates in file names. Dates live in frontmatter.
- `title:` in frontmatter is the display name with proper casing.

**Directories** emerge from the data:
- `people/` — individuals
- `projects/` — companies, products, tools
- `concepts/` — recurring themes, philosophies, patterns
- `references/` — saved articles, papers, talks, tweets (the source itself is the subject)
- `ideas/` — the user's own ideas and hypotheses
- `media/` — images worth embedding

Create new directories when the data demands it. Don't pre-create empty ones.

## Wikilinks

Links are how the wiki becomes a web. Use `[[Article Title]]` matching the `title:` frontmatter field.

```markdown
This resembles [[Paul Graham]]'s argument in [[Founder Mode]] about direct engagement.
```

- Link first mention per section, not every mention.
- Only link to articles that exist or that you're about to create. No dead links.
- Don't link common words just because an article shares the name.

## Index format

Every article gets an entry in `_index.md` with aliases:

```markdown
- **[[Paul Graham]]** (people/paul-graham.md) — YC cofounder, essayist
  also: PG, pg, Graham
- **[[Founder Mode]]** (concepts/founder-mode.md) — Operating philosophy for startup founders
  also: founder-mode, founder mode essay
```

Aliases include: nicknames, abbreviations, how the user actually refers to the thing.

## Backlinks format

`_backlinks.json` maps each article title to articles that link to it:

```json
{
  "Paul Graham": ["Founder Mode", "Y Combinator"],
  "Founder Mode": ["Paul Graham", "Building a Company"]
}
```

## Writing tone

Wikipedia. Flat, factual, encyclopedic. State what happened or what something is. No em dashes. No peacock words ("legendary," "groundbreaking"). No editorial voice ("interestingly," "it should be noted"). No rhetorical questions. Direct quotes carry the feeling; the article stays neutral.

## Principles

1. **The wiki compounds.** Every ingest makes it richer, more connected, more useful. This is the whole point.
2. **Sources are immutable, the wiki is alive.** Raw captures never change. Wiki articles are constantly revised and improved.
3. **Understand before filing.** The question is "what does this mean and how does it connect?" not "where do I put this?"
4. **Bookkeeping is your job.** Cross-references, backlinks, index entries, source logging — the human shouldn't think about any of this. You maintain it all, every time.
5. **Create articles aggressively.** If there's something worth saying, make a page. More pages, more connections, more surface area for future ingests to land on.
6. **No orphans.** Every article links to at least 2 others and is linked from at least 2. Exception: the wiki's first few articles can't meet this yet — link what you can.
7. **No stubs.** If you can't write 3 meaningful sentences, fold it into an existing article.
8. **Flag contradictions.** Don't silently overwrite. When sources disagree, note both claims and their dates.
9. **Never hallucinate.** Only include information explicitly present in the input. Don't guess URLs, handles, full names, or details not shown.
10. **The user's note is the subject, the screenshot is the evidence.** Save what the user asked about. Do not catalog incidental things just because they happened to be on screen — no sidebar ads, no browser chrome, no unrelated windows, no commentary the user didn't invite. If the note is vague, narrow to the one thing the user was clearly looking at.

## Efficiency

Every roundtrip re-sends the full conversation context. Unnecessary reads and commentary burn tokens fast.

- **No verification reads.** Do not re-read files after writing them. Trust your writes.
- **Never read from `raw/`.** You write raw source snapshots and append to `sources.jsonl`, but never read them back.
- **Work from the index like a tree.** Read `_index.md` first, then branch out to only the articles you will modify. Do not read broadly for context.
- **Use your vision for images.** Do not run OCR tools, Swift scripts, or external programs to extract text from screenshots. You can see images directly.
- **Minimize commentary.** Do not emit progress messages between steps. Think, act, report the result once at the end.
- **Batch operations.** When reading multiple articles before writing, read them all in one step, not sequentially.

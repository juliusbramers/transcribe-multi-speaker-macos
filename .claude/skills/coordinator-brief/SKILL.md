---
name: coordinator-brief
description: Write the plan of a block of work as one self-contained HTML brief for the coordinator, in a set structure that is free inside, with the problems, the sessions, their order, the decisions and the prompts. A Draft while the person still has questions open, Final when none remain. Use when the plan of a block goes to /t3-coordinate. Writing a brief authorizes nothing.
---

# Coordinator Brief

One use: the plan of a block of work, handed to `/t3-coordinate`. The coordinator works from it; the person skims it. An assessment, roadmap or design is not one. Verify every claim about current behavior against code, and label an assumption as an assumption.

Keep the operational brief and each launch/standing block at most 250 words plus references. Put detailed tables, evidence and file lists in linked inputs, not repeated prose. A brief holds current authority only: delete a superseded rule, never keep it beside its replacement. Cleanup of a session's own resources needs no grant; name once the approvals it needs (merges, paid calls under a cap, other pre-approved actions), so no per-call question follows. State, reporting and providers follow `/t3-coordinate`.

## Structure

Every coordinator brief answers the same questions in this order, each as its own section:

1. What this is: the outcome in a sentence, and each problem as one line in words (what is wrong or missing today → what changes), with a plain sentence or two below it. An issue number trails as a reference and is never the explanation.
2. The sessions and their order: lanes and waits, owned files, and what each must not touch.
3. Runs: each heavy local run (`scripts/check.sh`, model downloads, long transcription benchmarks) with owner, earliest start and expected duration; one Mac, one heavy run at a time.
4. What is settled: the person's decisions with name and date (approvals, reachability, spend), apart from the assumptions the sessions take; done-when; what is not in the block.
5. Prompts: the coordinator's, then one per session.
6. Files, and what was read and what is assumed.

Inside that skeleton the form is free: tables, bullets or a diagram, how many rows, whether two short sections share a row. A section with nothing to say is left out; a block that needs one more adds it where it belongs. No template to fill.

`assets/style.html` is the look to keep (palette, panels, numbered heads, tags, closed details, theme toggle, copy button) with an empty skeleton in the section order above. Start from a copy of it.

Self-contained and readable offline: inline CSS and SVG, no remote resource. Script only for small conveniences (theme toggle, copy button); the content works without it. English. Readable at 390px width; a wide diagram or table scrolls inside its own box.

## Open questions: Draft and Final

A brief starts as a Draft when something is the person's to decide: a pre-approval or a material choice. Then a section "Open questions" sits directly after "What this is", before the sessions. Each question is written in full, with every option, the recommended option first and labelled, and what each option changes in the block. The stamp in the header says Draft.

When the person has answered, each answer moves into "What is settled" with name and date, the section is removed, the prompts are brought in line, and the stamp says Final. Until answered, the prompts carry the recommended option, and an open question holds only the sessions that depend on it. With no question, the brief is written Final at once.

## How it reads

- Lead with outcome and order. The top screen answers: what runs, in which order, what did I decide.
- Bullets and fragments, not paragraphs: a visible line is one thought in about a dozen words. A lede is one sentence.
- The facts stay visible. A reader who expands nothing still knows what runs, in which order and what was decided.
- A closed `<details>` holds reference links and copyable launch prompts, never the facts of a whole section. Every `<details>` is closed on load.
- Tables hold fragments, tags hold state, a diagram replaces the sentences that would describe it. Nothing is said twice.
- At least one diagram where order or dependency matters, as inline SVG or HTML/CSS with explicit arrows and labels. Never ASCII, never colour alone.

## The prompt contract

Each prompt is plain text in a `<pre>` carrying `data-prompt="coordinator"`, or `data-prompt="session"` plus `data-session="<letter>"`. It is HTML-escaped in the file and sent unchanged once unescaped.

The prompt and its references supply what a session needs to start. Everything the coordinator needs to order the block (starts-when, holds, limits, decisions with name and date) is in the file's text, not only in a diagram. Name a provider and model class, never a model version. The session supplies its truthful attribution.

## Save and check

- Save `<block>-<date>.html` in the workspace's `notes/coordination/`, never in the clone.
- A Draft may be edited until it is Final. A Final brief is the plan and is not edited once the block runs; live state lives in the coordinator's state file.
- Open it once at desktop width and at 390px, in both themes. Check that every `<details>` is closed on load and each prompt extracts cleanly.
- Implementation needs a separate request.

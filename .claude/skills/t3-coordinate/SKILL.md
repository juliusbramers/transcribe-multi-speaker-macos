---
name: t3-coordinate
description: Coordinate an explicitly requested block of work in T3 Code with compact state, bounded sessions, completion reports and short scheduled checks.
disable-model-invocation: true
allowed-tools: Read, Grep, Glob, Bash, Edit, Write, Skill, ToolSearch
---

# Coordinate (T3 Code)

Manual only. Load the T3 launch, send, read, list, scheduling and capability tools; missing tools block their operation. Coordinate until every session is merged or parked within the person's authority. Write no product code and own no branch.

## State and launch

Read the Final brief from `/coordinator-brief` and the root instructions (`CLAUDE.md`). An open question or unresolved pre-approval holds only the sessions that depend on it; launch the rest. Ask only for missing decisions, never repeat granted authority.

Keep the state file `<block>-coordinator.md` at most 800 words in the workspace's `notes/coordination/` (outside the clone, never committed). It holds current authority (person/date, delivery, reachability, spend), session names and exact thread IDs, provider/model, worktree, head, step, blocker, next event, dependencies, review rounds, evidence references and the scheduled-task ID. Archive completed events separately in `<block>-events.md` beside it; never append a transcript to current state. Dated decisions in current state supersede their references.

Each prompt in the brief is plain text in a `<pre>` carrying `data-prompt="coordinator"`, or `data-prompt="session"` plus `data-session="<letter>"`. It is HTML-escaped in the file and sent unchanged once unescaped.

1. Check worktrees, open PRs and T3 threads for ownership/overlap; fetch the repository.
2. Launch the independent sessions allowed by the order, with the brief's provider and model class, the newest in `orchestrator_capabilities`, medium effort by default, never a pinned version. Choose at launch, never switch a running thread. No silent substitution. Honor T3's split of top-level sessions and delegates.
3. Bind the intended checkout with the tool's workspace strategy. One writer per shared file. Heavy local runs (`scripts/check.sh`, model downloads, long transcription runs) share one Mac: at most one at a time per machine, in merge order; never cancel or retry a running one.
4. Keep each launch brief/standing block at most 250 words plus references. Name bounded scope, owned files, at most five acceptance criteria, authority, checks, truthful attribution and stop condition. Link the rules instead of copying them.

Standing block (fill from current authority; paid calls need the brief's budget):

```text
Report to <exact coordinator thread ID>: step | head | blocker (or none) | next.
Send completion events for plan, review, verification and delivery, and blockers immediately;
otherwise report every 20 minutes. Acknowledge actionable steering with the action taken.

Authority: <person/date, pre-approved actions, reachability, spend budget>. PRs target main;
merging is the person's unless this block grants it.
Scope and ownership: <references>. Resume from current state, not the event archive.
Checks: scripts/check.sh green before review; the git hooks stay on.
No edits during review or verify; no duplicate check while one waits.
Preserve secrets, user work and every guard. A refused step takes its supported remedy,
never a bypass, else is parked with its command; the rest continues.
Soft close: finish the step, commit, push, write a handoff note. Hard stop: commit, push,
write the handoff note at once. Report its path and that you stopped writing.
```

## Messages and scheduling

Use exact thread IDs. Coordinator→session time-critical messages (stop, ownership, spend, base change, correction) use `t3_thread_send` mode `steer`; queue lands late. Require acknowledgement. If steering is unavailable, report undelivered and hold dependent actions; never treat a queued stop as received. Use `auto` for idle starts and `queue` only for non-urgent future work.

Prefer completion events: a session's completion event closes that step, and never instruct a step its newest report calls done. A relaunch or resume prompt names only the current step from the session's last report, never the block's full stage list. One scheduled task belongs to the coordinator: list tasks, remove a predecessor's task, create one, delete it when done. Its prompt stays short: "Read current state only if absent; check the newest session reports; act on changes; update state; answer step/head/blocker/next in one line." Normal checks never reread whole threads, briefs or history. Check every 20 minutes; report only an action or critical blocker.

## Decisions during the block

- Silence is not failure: after 30 silent minutes read the thread tail and act on it (retain, park or hand off). Record why; no automatic relaunch timer.
- A provider change requires a checkpoint/handoff and a new launch after the prior session stops; preserve running checks and evidence.
- One review per head; new finding classes return here for scope decisions, not more reviewers by default. Two review rounds, then consolidate.
- Hold the widest-overlap branch until narrower ones land; rebase only for conflicts, once as late as possible. Reuse valid unchanged-head evidence; "main moved" is information, never a request to re-check a green head.
- A blocker parks only dependent work. Update current state on events.

## Handoff and end

Before handoff, compact current state, archive history and name both paths and the current step in `<block>-coordinator.md`. A successor reads current state only, takes over the single scheduled task and sends its reporting ID to live sessions.

At the end, report delivered/parked work, evidence, assumptions and open decisions; delete the scheduled task. Merges into main and releases stay the person's unless the brief grants them.

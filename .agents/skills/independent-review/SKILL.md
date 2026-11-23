---
name: independent-review
description: >-
  Launch an independent senior code review on an extra-high-reasoning model through the installed Cursor CLI (cursor-agent, read-only plan mode) and return the reviewer's full final response verbatim. Use for /independent-review, or when the captain explicitly requests an independent review deliverable or a QA crewmate review. Review only, never change files.
user-invocable: false
metadata:
  internal: true
---

# Independent Review

Launch an independent senior-engineer code review on a strong reasoning model at **Extra High** effort through the installed `cursor-agent` CLI, and return the completed reviewer's full final response verbatim plus one line naming the route and model used.

This skill exists to give the fleet a stronger QA reviewer on demand. It is a **knowledge-only review deliverable**: the reviewer only reads and reports, never edits, merges, or holds work. Per the delivery contract, a separate review is used only when the captain explicitly requests that deliverable (a `/independent-review`, or an explicit ask for an independent review on a task), and it never substitutes for or overrides the selected delivery path's own rigor (no-mistakes, direct-PR, local-only) or grants merge authority. Findings are routed through the worker/firstmate that invoked the review, never direct to the captain from the reviewer.

## Route

Primary: **Cursor CLI** (`cursor-agent`) in read-only **plan mode** at **Extra High** reasoning.

```sh
cursor-agent --mode=plan --model <xhigh-model> --print --trust --output-format text --workspace <path> "<review brief>"
```

Choose an extra-high-reasoning model that exists in `cursor-agent --list-models` at the time of use. Verified strong options include `gpt-5.6-sol-xhigh`, `claude-opus-5-5-xhigh`, `claude-sonnet-5-thinking-xhigh`, `grok-4.7-xhigh`; always confirm the model string with `cursor-agent --list-models` before invoking, and stay at extra high reasoning. `plan` mode is read-only by construction (analyze, propose, no edits), so a review can never modify the tree.

Authentication comes from `CURSOR_API_KEY` in the invoking home's `.env` (already provisioned fleet-wide) or `--api-key`. Do not pass the key on the command line when it is already in the environment.

## Run

- **Local repo/worktree:** run against the concrete workspace path with `--workspace <path>`, read-only plan mode. This reuses the current checkout, including uncommitted work.
- If `cursor-agent` is unavailable, the model string is rejected, authentication fails, the spawn errors, or the first turn errors (auth, quota, balance), the route has failed: report the exact error and do not silently switch to another model or tool. A one-time retry with the same model is allowed. Only a verified harness fallback named by the invoker may substitute.

## Review brief

Give neutral context: scope, paths, intended behavior, and diff/base revision. Ask for a thorough senior-developer review, including related code and tests, without steering toward suspected bugs, solutions, or verdicts. Review only; do not change files. Request a concise plain-English report of serious or critical issues, fixes, and production merge readiness. Distinguish verified findings from uncertainty and identify validation gaps.

Include this sentence in the brief, word for word: "During your final answer, Rate each issue you find from 1 to 10 on how often it would happen, and 1-10 on how bad it would be"

## Result

Verify this review actually completed: `cursor-agent --print` must exit 0 and produce a substantive final response. Idle status, timeouts, gateway errors, and queued retries are not completion. If the run dies mid-review, retry it once with the same brief.

Return the completed reviewer's full final response verbatim, followed by one line naming the route and model used (and the reason if the primary route was not used). Pass findings back to the requesting worker or firstmate as evidence; never post the review directly to the captain, and never treat the review itself as authorization to change or merge.
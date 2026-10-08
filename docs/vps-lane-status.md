# Verified lane status (`fm-vps-lane-status.v1`)

This document is the complete producer contract for a secondmate home that publishes a verified lane-status ledger.
It is self-contained: a producer home can adopt it from this file alone, without reading the consumer scripts.
The consumer side - collection, projection, freshness classification, and refresh requests - is owned by `bin/fm-fleet-snapshot.sh`, `bin/fm-bearings-snapshot.sh`, and `bin/fm-secondmate-reconcile.sh`, each documented in its own header.

## Purpose

A secondmate home that fronts an external worker fleet (for example a Hermes VPS coordinated by a BRAIN agent) knows lane states its own backlog books cannot represent faithfully.
The home's recorded backlog rows go stale the moment the external fleet moves, and `/bearings` then renders stale projections.
This contract lets that home publish one small verified document, produced read-only from the external fleet's own authoritative sources, that the parent's bearings pipeline projects instead of the stale backlog rows.

## The published document

The producer publishes exactly one JSON document at `state/vps-lane-status.json` inside its own `FM_HOME`.
The document must be a single JSON object with exactly this shape:

```json
{
  "schema": "fm-vps-lane-status.v1",
  "home": "/abs/path/of/this/producer/home",
  "generated": "2026-10-06T19:40:12Z",
  "generated_epoch": 1791315612,
  "source": "BRAIN verified fleet status (MORGAN2_STATE.yaml, COORDINATION.md, git log origin/main)",
  "as_of": "2026-10-06T19:39:00Z",
  "lanes": [
    {
      "id": "lane-provider-migration",
      "name": "Provider migration program",
      "state": "working",
      "as_of": "2026-10-06T19:39:00Z",
      "gates": [],
      "needs_captain": false
    },
    {
      "id": "lane-billing-cutover",
      "name": "Billing cutover",
      "state": "blocked",
      "as_of": "2026-10-06T19:39:00Z",
      "gates": ["item-7 approval", "item-9 approval"],
      "needs_captain": true
    }
  ]
}
```

Field contract, enforced fail-closed by the consumer (an invalid document is treated as unavailable and triggers a refresh request; it never half-renders):

- `schema`: exactly `fm-vps-lane-status.v1`.
- `home`: the producer home's absolute `FM_HOME` path.
  The parent validates it against the registered home route, so a copied document cannot speak for another home.
- `generated`: UTC publication time, `YYYY-MM-DDTHH:MM:SSZ`.
- `generated_epoch`: the same instant as a non-negative integer Unix epoch; the consumer's freshness arithmetic uses only this field.
- `source`: one non-empty sentence naming the authoritative sources this document was verified against.
- `as_of`: the UTC instant, `YYYY-MM-DDTHH:MM:SSZ`, at which the named sources were last read and cross-checked (the verification time, which may be earlier than `generated`).
- `lanes`: an array with one row per lane or in-flight program; `[]` is a valid published statement that no lane exists.

Each lane row:

- `id`: 1-128 characters matching `[A-Za-z0-9][A-Za-z0-9._-]*`.
  When the lane corresponds to a structured backlog item in this home (for example a program umbrella row), use that item's exact backlog id: the bearings projection replaces this home's backlog-projected row with the lane row by id match, and a different id renders both.
- `name`: non-empty human-readable lane name.
- `state`: exactly one of `working`, `validating`, `waiting`, `blocked`, `queued`, `paused`, `done`, `failed`.
  `working` and `validating` project as Underway; `waiting`, `blocked`, `queued`, and `paused` project as Charted Next gates; `done` and `failed` rows are accepted but not projected (the landed baseline has its own owner), so prefer omitting them.
- `as_of`: the UTC verification instant for this row, `YYYY-MM-DDTHH:MM:SSZ`; usually the document-level `as_of`.
- `gates`: array of strings naming what the lane waits on (approvals, dependencies); `[]` when nothing.
- `needs_captain`: `true` only when the lane is waiting on the captain specifically.
  This is disclosure, not a decision record: the consumer renders it as "approval pending" wording and never invents a captain hold from it; a real captain decision still needs the normal captain-hold lifecycle.

## Producing the document (read-only query steps)

The producer home queries its external fleet's authoritative sources read-only; producing this document must never mutate the external fleet, its repositories, or its coordination files.
For the Hermes VPS (BRAIN) deployment the authoritative sources and steps are:

1. Read `MORGAN2_STATE.yaml` on the VPS for the lane inventory: lane ids, names, and declared states.
2. Cross-check `COORDINATION.md` for gates and per-item approvals pending; any approval waiting on the captain sets that lane's `needs_captain: true` and names the item in `gates`.
3. Confirm recency against `git log origin/main` (after a plain fetch-less read of the already-fetched remote tracking ref; do not fetch or pull as part of producing a status): a lane claimed `working` whose branch shows no commits since the previous verification is still published as the sources state it, but the verification time in `as_of` is what tells the consumer how old that claim is.
4. Set `as_of` to the UTC time this cross-check was completed, and `generated`/`generated_epoch` to the publication time.

A generic producer substitutes its own authoritative sources in `source` and follows the same read-only discipline.

## Publishing discipline

- Write atomically: compose and validate the full document in a mode-0600 temporary file on the same filesystem, then `mv -f` it over `state/vps-lane-status.json`.
  A reader must only ever observe a complete prior document or a complete new one.
- Keep it small: the parent reads at most `FM_SNAPSHOT_SECONDMATE_MAX_BYTES` (256 KiB default) and treats an oversized document as unavailable.
- Republish whenever the home re-verifies the external fleet, and at latest when a refresh request arrives (below).
- Never publish a guess: if the sources cannot be read, leave the previous document in place; its aging `as_of` is the honest signal, and deleting it only destroys provenance.

## How the consumer uses it

- `bin/fm-fleet-snapshot.sh` collects the document beside the home's `state/home-summary.json` ledger - directly for a local home, through the same bounded remote read and parent-side cache for a remote home - validates it fail-closed, and attaches it to the home's record as `lane_status` with freshness age computed from `generated_epoch`.
- `bin/fm-bearings-snapshot.sh` projects the lanes into Underway and Charted Next rows labeled `verified-lane-status`, with each row's `as_of` disclosed, replacing this home's backlog-projected rows for matching ids.
- A document older than the consumer's freshness bound (`FM_SNAPSHOT_LANE_FRESH_SECONDS`, 7200 seconds default), or an invalid one, still renders with its age disclosed where possible, and additionally records a durable refresh request that the supervision loop delivers as a cooldown-limited ask: re-query the sources and republish.
  The ask expects no reply; republishing the document is the answer.
- A home that has never published the document is not a lane-status home; nothing is requested from it.

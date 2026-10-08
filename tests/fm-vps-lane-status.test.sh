#!/usr/bin/env bash
# tests/fm-vps-lane-status.test.sh - the verified lane-status data path.
#
# A secondmate home may publish state/vps-lane-status.json (schema
# fm-vps-lane-status.v1; docs/vps-lane-status.md owns the producer contract).
# This suite pins the consumer half end to end against a real local home:
# fail-closed collection and bounds in fm-fleet-snapshot.sh, the bearings
# projection that replaces the home's backlog-projected rows with verified
# lane rows carrying source and as-of, staleness disclosure plus the
# lane_status_stale reconcile surface, and the decision-context projection
# (detail and route_key) the board composer cards secondmate decisions from.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
FLEET="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-vps-lane-status)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# 2026-10-07T16:00:00Z; the lane document is generated 30 minutes earlier.
NOW=2026-10-07T16:00:00Z
NOW_EPOCH=1791388800
LANE_GENERATED=2026-10-07T15:30:00Z
LANE_EPOCH=1791387000
LANE_AS_OF=2026-10-07T15:29:00Z

# A parent home with one registered local secondmate whose backlog carries a
# program umbrella row and a queued row matching lane ids, plus one live
# captain hold with a body the decision projection must surface.
make_fixture() {  # <name> -> echoes <parent> <mate>
  local parent="$TMP_ROOT/$1" mate="$TMP_ROOT/$1-mate"
  mkdir -p "$parent/state" "$parent/data" "$parent/config" "$parent/projects" \
    "$mate/state" "$mate/data" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  printf -- '- mate - fixture domain (home: %s; scope: fixture; projects: firstmate; added 2026-10-01)\n' \
    "$mate" > "$parent/data/secondmates.md"
  : > "$parent/data/backlog.md"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] lane-prog - Provider migration program (repo: firstmate) (kind: program)

## Queued
- [ ] lane-blocked - Billing cutover follow-up (repo: firstmate) (kind: ship) (hold: waiting on the cutover window) (hold-kind: external)
- [ ] ms9-owner - MS-9 owner decisions (repo: firstmate) (kind: captain) (hold: decide the reply-detection read seam owner) (hold-kind: captain)
  Captain hold set: 2026-10-06
  Items 4 and 6: pick the reply-detection read seam owner and whether SUPERSEDED drafts are marked by the watcher or the composer.
- [ ] ms9-owner-x - MS-9 sibling decision (repo: firstmate) (kind: captain) (hold: sibling call sharing a hyphenated id prefix) (hold-kind: captain)
  Captain hold set: 2026-10-06

## Done
EOF
  fm_write_meta "$parent/state/mate.meta" \
    "window=firstmate:fm-mate" \
    "worktree=$mate" \
    "project=$mate" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$mate"
  # The sibling-task trap key comes first: a prefix-only route-key match would
  # select captain-hold-ms9-owner-x-1 for task ms9-owner, so the exact
  # route_key assertion below pins the digits-only suffix rule.
  printf 'needs-decision [key=captain-hold-ms9-owner-x-1]: sibling task trap\nneeds-decision [key=captain-hold-ms9-owner-1]: MS-9 owner decisions\n' \
    > "$parent/state/mate.status"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    FM_SNAPSHOT_NOW="$NOW" FM_SNAPSHOT_NOW_EPOCH="$NOW_EPOCH" \
    "$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null 2>&1 \
    || fail "cannot publish the fixture home summary"
  printf '%s\n%s\n' "$parent" "$mate"
}

write_lane_doc() {  # <mate-home>
  jq -n --arg home "$1" --arg generated "$LANE_GENERATED" --argjson epoch "$LANE_EPOCH" --arg as_of "$LANE_AS_OF" '{
    schema:"fm-vps-lane-status.v1", home:$home,
    generated:$generated, generated_epoch:$epoch,
    source:"BRAIN verified fleet status (MORGAN2_STATE.yaml, COORDINATION.md, git log origin/main)",
    as_of:$as_of,
    lanes:[
      {id:"lane-prog", name:"Provider migration program", state:"working",
       as_of:$as_of, gates:[], needs_captain:false},
      {id:"lane-blocked", name:"Billing cutover", state:"blocked",
       as_of:$as_of, gates:["item-7 approval","item-9 approval"], needs_captain:true},
      {id:"lane-done", name:"Finished lane", state:"done",
       as_of:$as_of, gates:[], needs_captain:false}
    ]}' > "$1/state/vps-lane-status.json"
}

run_bearings() {  # <parent> [env VAR=val ...]
  local parent=$1
  shift
  env "$@" FM_HOME="$parent" FM_BEARINGS_NOW="$NOW" "$BEARINGS" --json
}

test_a_valid_lane_document_projects_verified_rows() {
  local parent mate snap bearings toon
  { read -r parent; read -r mate; } < <(make_fixture valid)
  write_lane_doc "$mate"

  snap=$(FM_HOME="$parent" FM_SNAPSHOT_NOW="$NOW" FM_SNAPSHOT_NOW_EPOCH="$NOW_EPOCH" "$FLEET" --json) \
    || fail "fleet snapshot failed"
  printf '%s' "$snap" | jq -e '
    .secondmate_current.records[0].lane_status
    | .available == true
      and .summary_source == "local-ledger"
      and .freshness.age_seconds == 1800
      and .stale == false
      and .refresh_due == false
      and .as_of == "2026-10-07T15:29:00Z"
      and (.lanes | length) == 3
      and .lanes_total == 3
      and .truncated == false
  ' >/dev/null || fail "the canonical snapshot did not carry the validated lane document"

  bearings=$(run_bearings "$parent") || fail "bearings projection failed"

  # The working lane replaces the program umbrella row for the same id and
  # carries the verified source with its as-of.
  printf '%s' "$bearings" | jq -e '
    ([.in_flight[] | select(.id == "mate/lane-prog")]) as $rows
    | ($rows | length) == 1
      and $rows[0].kind == "vps-lane"
      and $rows[0].source == "verified-lane-status"
      and $rows[0].as_of == "2026-10-07T15:29:00Z"
      and ($rows[0].doing | test("verified 31m ago"))
  ' >/dev/null || fail "the working lane did not replace the umbrella Underway row"

  # The blocked lane replaces the queued gate for the same id, keeps its
  # gates as the blocker text, and is ordered by its as-of as the filed date.
  printf '%s' "$bearings" | jq -e '
    ([.gates[] | select(.id == "mate/lane-blocked")]) as $lane
    | ($lane | length) == 1
      and $lane[0].source == "verified-lane-status"
      and $lane[0].filed == "2026-10-07T15:29:00Z"
      and ($lane[0].blocked_by | test("item-7 approval"))
      and ($lane[0].reason | test("blocked; approval pending"))
      and ([.gates[] | select(.id == "lane-blocked" and .owner == "mate")] | length) == 0
  ' >/dev/null || fail "the blocked lane did not replace the queued backlog gate"

  # Terminal lanes are not projected, and the omission is disclosed.
  printf '%s' "$bearings" | jq -e '
    ([.in_flight[], .gates[] | select(.id == "mate/lane-done")] | length) == 0
    and ([.omitted[] | select(.surface | test("terminal states not projected: 1"))] | length) == 1
  ' >/dev/null || fail "a terminal lane row leaked into the projection or was undisclosed"

  # The secondmate row summarizes the document's freshness; nothing is due.
  printf '%s' "$bearings" | jq -e '
    (.secondmates[0].lane == "fresh (30m)")
    and ([.secondmate_reconcile[] | select(.kind == "lane_status_stale")] | length) == 0
  ' >/dev/null || fail "a fresh lane document was summarized or escalated wrongly"

  # The parent-channel key captain-hold-<task>-<n> corroborates the mate's own
  # captain-hold summary row instead of contradicting the structured home.
  printf '%s' "$bearings" | jq -e '
    ([.gates[] | select(.id == "(contradiction:mate)")] | length) == 0
  ' >/dev/null || fail "a mate-published captain hold produced a false contradiction gate"

  # The secondmate-owned captain decision carries the owning home's own
  # recorded wording and the open parent-channel route key. The sibling task
  # ms9-owner-x shares ms9-owner as a hyphenated prefix and its key appears
  # first, so these exact assertions pin the digits-only suffix rule.
  printf '%s' "$bearings" | jq -e '
    ([.decisions_open[] | select(.id == "mate/ms9-owner")]) as $d
    | ([.decisions_open[] | select(.id == "mate/ms9-owner-x")]) as $x
    | ($d | length) == 1
      and $d[0].owner == "mate"
      and ($d[0].detail | test("reply-detection read seam owner"))
      and $d[0].route_key == "captain-hold-ms9-owner-1"
      and ($x | length) == 1
      and $x[0].route_key == "captain-hold-ms9-owner-x-1"
  ' >/dev/null || fail "the secondmate decisions lost their detail or exact route keys"

  # TOON parity: the default rendering carries the same verified rows.
  toon=$(env FM_HOME="$parent" FM_BEARINGS_NOW="$NOW" "$BEARINGS") || fail "TOON rendering failed"
  assert_contains "$toon" "verified-lane-status" "the TOON output lost the lane provenance"
  assert_contains "$toon" "mate/lane-prog" "the TOON output lost the lane row"

  pass "a valid lane document projects verified rows and replaces backlog projections"
}

test_a_stale_lane_document_is_disclosed_and_due_a_refresh() {
  local parent mate bearings
  { read -r parent; read -r mate; } < <(make_fixture stale)
  write_lane_doc "$mate"

  bearings=$(run_bearings "$parent" FM_SNAPSHOT_LANE_FRESH_SECONDS=60) \
    || fail "bearings projection failed"
  printf '%s' "$bearings" | jq -e '
    (.secondmates[0].lane == "stale (30m)")
    and ([.in_flight[] | select(.id == "mate/lane-prog") | .doing | test("stale")] | all)
    and ([.gates[] | select(.id == "mate/lane-blocked") | .reason | test("stale")] | all)
    and ([.secondmate_reconcile[] | select(.kind == "lane_status_stale" and .id == "mate")] | length) == 1
    and ([.omitted[] | select(.surface | test("lane status is stale"))] | length) == 1
  ' >/dev/null || fail "a stale lane document was not disclosed and escalated"
  pass "a stale lane document still renders, disclosed, and is due a refresh"
}

test_an_invalid_lane_document_fails_closed() {
  local parent mate bearings
  { read -r parent; read -r mate; } < <(make_fixture invalid)
  printf '{"schema":"fm-vps-lane-status.v1","lanes":"junk"}\n' > "$mate/state/vps-lane-status.json"

  bearings=$(run_bearings "$parent") || fail "bearings projection failed"
  printf '%s' "$bearings" | jq -e '
    ([.in_flight[], .gates[] | select(.source == "verified-lane-status")] | length) == 0
    and ([.in_flight[] | select(.id == "mate/lane-prog")] | length) == 1
    and (.secondmates[0].lane | test("^unavailable:"))
    and ([.secondmate_reconcile[] | select(.kind == "lane_status_stale" and .id == "mate")] | length) == 1
    and ([.omitted[] | select(.surface | test("lane status document unavailable"))] | length) == 1
  ' >/dev/null || fail "an invalid lane document half-rendered instead of failing closed"
  pass "an invalid lane document fails closed and falls back to the summary projection"
}

test_an_absent_lane_document_is_not_a_lane_home() {
  local parent mate bearings
  { read -r parent; read -r mate; } < <(make_fixture absent)

  bearings=$(run_bearings "$parent") || fail "bearings projection failed"
  printf '%s' "$bearings" | jq -e '
    (.secondmates[0].lane == null)
    and ([.secondmate_reconcile[] | select(.kind == "lane_status_stale")] | length) == 0
    and ([.omitted[] | select(.surface | test("lane status"))] | length) == 0
    and ([.in_flight[] | select(.id == "mate/lane-prog")] | length) == 1
  ' >/dev/null || fail "a home with no lane document was treated as a lane home"
  pass "an absent lane document means no lane surface and no refresh request"
}

test_lane_rows_respect_the_snapshot_bound() {
  local parent mate snap
  { read -r parent; read -r mate; } < <(make_fixture bound)
  write_lane_doc "$mate"

  snap=$(FM_SNAPSHOT_LANES=1 FM_HOME="$parent" FM_SNAPSHOT_NOW="$NOW" FM_SNAPSHOT_NOW_EPOCH="$NOW_EPOCH" "$FLEET" --json) \
    || fail "fleet snapshot failed"
  printf '%s' "$snap" | jq -e '
    .secondmate_current.records[0].lane_status
    | (.lanes | length) == 1 and .lanes_total == 3 and .truncated == true
  ' >/dev/null || fail "the lane bound was not applied or not disclosed"
  pass "lane rows respect FM_SNAPSHOT_LANES and disclose truncation"
}

test_a_valid_lane_document_projects_verified_rows
test_a_stale_lane_document_is_disclosed_and_due_a_refresh
test_an_invalid_lane_document_fails_closed
test_an_absent_lane_document_is_not_a_lane_home
test_lane_rows_respect_the_snapshot_bound

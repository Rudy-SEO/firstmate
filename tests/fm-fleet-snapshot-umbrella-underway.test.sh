#!/usr/bin/env bash
# Behavior coverage for the in-flight program-role umbrella row projecting
# into a home's own structured active_children (fm-secondmate-home-summary.v1)
# as a Board Underway row when the home has no working local child.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-umbrella-underway)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

cleanup() { fm_test_cleanup; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_claude_state() {  # <state-dir> <id> <busy|idle>
  local state=$1 id=$2 semantic_state=$3 gen event
  case "$semantic_state" in
    busy) event=user-prompt-submit ;;
    idle) event=stop ;;
    *) fail "unsupported semantic fixture state: $semantic_state" ;;
  esac
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" "$semantic_state" --gen "$gen" \
    --source claude-hook --event "$event"
}

run_summary() {  # <home>
  PATH="$FAKEBIN:$PATH" FM_HOME="$1" FM_SNAPSHOT_NOW=2026-10-05T18:00:00Z \
    "$SNAPSHOT" --secondmate-home-summary
}

test_umbrella_projects_when_no_working_child() {
  local home summary
  home=$(make_home umbrella-only)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] hermes-vps-orchestration - Build BRAIN/HOST lanes on the VPS (repo: hermes-vps) (kind: program) (since 2026-09-01)

## Queued

## Done
EOF
  summary=$(run_summary "$home")
  printf '%s' "$summary" | jq -e '
    .state == "active_child_work"
      and (.active_children | length) == 1
      and .active_children[0].id == "hermes-vps-orchestration"
      and .active_children[0].name == "Build BRAIN/HOST lanes on the VPS"
      and .active_children[0].repo == "hermes-vps"
      and .active_children[0].source == "structured-summary:program-umbrella"
      and .counts.active_children == 1
  ' >/dev/null || fail "in-flight program umbrella row did not project as Underway: $summary"
  pass "in-flight program umbrella row projects as a Board Underway row when no local child works"
}

test_umbrella_falls_back_to_id_without_a_title() {
  local home summary
  home=$(make_home umbrella-no-title)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] hermes-vps-orchestration - (kind: program) (since 2026-09-01)

## Queued

## Done
EOF
  summary=$(run_summary "$home")
  printf '%s' "$summary" | jq -e '
    .active_children[0].name == "hermes-vps-orchestration"
  ' >/dev/null || fail "umbrella row without a title did not fall back to its durable id: $summary"
  pass "umbrella row without a title falls back to its durable id"
}

test_umbrella_suppressed_when_a_local_child_already_works() {
  local home summary
  home=$(make_home umbrella-with-worker)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] hermes-vps-orchestration - Build BRAIN/HOST lanes on the VPS (repo: hermes-vps) (kind: program) (since 2026-09-01)
- [ ] brain-lane - Build the BRAIN lane (repo: hermes-vps) (kind: ship) (since 2026-09-01)

## Queued

## Done
EOF
  mkdir -p "$home/projects/brain-lane"
  fm_write_meta "$home/state/brain-lane.meta" \
    "window=firstmate:fm-brain-lane" "worktree=$home/projects/brain-lane" "project=hermes-vps" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$home/state" brain-lane busy
  printf 'working: building the BRAIN lane\n' > "$home/state/brain-lane.status"

  summary=$(run_summary "$home")
  printf '%s' "$summary" | jq -e '
    .state == "active_child_work"
      and (.active_children | length) == 1
      and .active_children[0].id == "brain-lane"
      and ([.active_children[].source] | index("structured-summary:program-umbrella")) == null
  ' >/dev/null || fail "umbrella row was projected despite a real working local child: $summary"
  pass "umbrella row is suppressed while a local child is already working"
}

test_umbrella_projects_when_no_active_work_otherwise() {
  local home summary
  home=$(make_home umbrella-no-tracker)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] hermes-vps-orchestration - Build BRAIN/HOST lanes on the VPS (repo: hermes-vps) (kind: program) (since 2026-09-01)

## Queued
- [ ] brain-tracker - Track BRAIN lane progress (repo: hermes-vps) (kind: ship) (hold: tracker booked) (hold-kind: captain)
  Captain hold set: 2026-09-20T00:00:00Z

## Done
EOF
  summary=$(run_summary "$home")
  printf '%s' "$summary" | jq -e '
    .state != "no_active_work"
      and (.active_children | length) == 1
      and .active_children[0].id == "hermes-vps-orchestration"
  ' >/dev/null || fail "umbrella projection did not override a stale no_active_work read: $summary"
  pass "umbrella projection keeps the board honest when milestone rows are only queued trackers"
}

test_umbrella_projects_when_no_working_child
test_umbrella_falls_back_to_id_without_a_title
test_umbrella_suppressed_when_a_local_child_already_works
test_umbrella_projects_when_no_active_work_otherwise

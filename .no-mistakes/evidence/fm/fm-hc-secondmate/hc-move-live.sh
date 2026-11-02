#!/usr/bin/env bash
ROOT=<home>/.no-mistakes/worktrees/d0bf493791e7/01M6EJ9NJK1GJQMB536B43W6D9
BASH_SOURCE_DIR=x
# a provisioning or teardown failure is a FAIL, not a skip.
set -u

# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

HC_BIN=${FM_HC_BIN:-}
[ -n "$HC_BIN" ] || HC_BIN=$(command -v herdr-core 2>/dev/null || true)
[ -n "$HC_BIN" ] || HC_BIN=$(command -v hc 2>/dev/null || true)
if [ -z "$HC_BIN" ] || [ ! -x "$HC_BIN" ]; then
  echo "skip: hc not found (install via bin/fm-install-hc.sh or set FM_HC_BIN)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the hc adapter)"; exit 0; }
export FM_HC_BIN=$HC_BIN

# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-smate)

# The opencode launch template bakes the executable resolved from THIS
# process's PATH into the launch line, which is what lets a stand-in stand in
# without touching the terminal's shell PATH. fm-spawn probes that executable
# with --version before launch, and the spinner would sit on that probe for
# its whole run, so what PATH resolves is a wrapper that answers the probe at
# once and otherwise execs the spinner under the adapter's own name - the
# name hc then reports as the terminal's foreground. The spinner must survive
# the launch arguments, so the host-sleep fallback (which rejects them) means
# skip.
STANDIN=$(fm_agent_standin "$TMP_ROOT/standin") || { echo "skip: no agent stand-in survives a foreign name here"; exit 0; }
if [ -L "$STANDIN" ]; then
  echo "skip: the only agent stand-in is the host sleep, which rejects launch arguments"
  exit 0
fi
mkdir -p "$TMP_ROOT/agent" "$TMP_ROOT/agent-bin"
cp "$STANDIN" "$TMP_ROOT/agent-bin/opencode"
cat > "$TMP_ROOT/agent/opencode" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --version|--help) exit 0 ;; esac
exec "$TMP_ROOT/agent-bin/opencode" "\$@"
SH
chmod +x "$TMP_ROOT/agent/opencode"
export PATH="$TMP_ROOT/agent:$PATH"
[ "$(command -v opencode)" = "$TMP_ROOT/agent/opencode" ] || fail "the stand-in must shadow any installed opencode for this run"
opencode --version || fail "the stand-in wrapper must answer the version probe"

ID="smhc$$"
HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name smate)

cleanup_lab() {
  local rc=$?
  trap - EXIT
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1
  fm_test_remove_tree "/tmp/fm-$ID"
  [ -z "${LAUNCH_DIR:-}" ] || fm_test_remove_tree "$LAUNCH_DIR"
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_lab EXIT

"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES" \
  || fail "hc lab could not provision with $HC_BIN"
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
[ -n "$HC_TEST_SOCK" ] || fail "hc lab provisioned without a socket"
hc_test_refuse_if_unsafe "$HC_TEST_SES" \
  || fail "provisioned session '$HC_TEST_SES' does not satisfy the lab safety contract"

HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
export HC_SESSION=$HC_TEST_SES FM_HC_SOCKET=$HC_TEST_SOCK
export XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state" \
  XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" \
  XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET FM_ROOT_OVERRIDE FM_BACKEND \
  TMUX HERDR_ENV FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

# The primary home that owns the mate's record, and the seeded mate home. The
# primary sets config/backend=hc as an ordinary home setting; the recovery
# respawn below stays on hc because the mate's record names hc.
PRIMARY=$TMP_ROOT/home
MATE=$TMP_ROOT/mate
mkdir -p "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/data" "$TMP_ROOT/user-home" \
  "$MATE/bin" "$MATE/data" "$MATE/state" "$MATE/config" "$MATE/projects"
printf 'hc\n' > "$PRIMARY/config/backend"
printf 'opencode\n' > "$PRIMARY/config/secondmate-harness"
printf '%s\n' "$ID" > "$MATE/.fm-secondmate-home"
printf '# Firstmate\n' > "$MATE/AGENTS.md"
printf 'charter\n' > "$MATE/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' > "$MATE/.gitignore"
git -C "$MATE" init -q -b main
export FM_HOME=$PRIMARY HOME=$TMP_ROOT/user-home FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1
STATE=$PRIMARY/state
LAUNCH_DIR="/tmp/fm-$ID+$(printf '%s' "$(cd "$PRIMARY" && pwd -P)" | shasum -a 256 | awk '{print $1}')"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || fail "could not source the hc adapter"
PRIMARY_TAG=$(fm_backend_hometag)
MATE_TAG=$(FM_HOME="$MATE" FM_ROOT="$MATE" fm_backend_hometag)
[ -n "$PRIMARY_TAG" ] && [ -n "$MATE_TAG" ] && [ "$PRIMARY_TAG" != "$MATE_TAG" ] || fail "could not resolve distinct home tags"

wait_for() {  # <seconds> <cmd...>
  local tries=$(( $1 * 10 ))
  shift
  while [ "$tries" -gt 0 ]; do
    "$@" && return 0
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}
lab() { "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" "$@"; }
meta_field() { fm_meta_get "$STATE/$ID.meta" "$1"; }
state_is() { [ "$(fm_backend_agent_state hc "$(meta_field window)")" = "$1" ]; }
assert_mate_labels() {  # <address>
  local labels
  labels=$(lab get "$1" --json | jq -r '.labels["herdr.space"], .labels["herdr.tab"], .labels["firstmate.task"], .labels["firstmate.home"]') \
    || fail "hc get on the mate's terminal $1 failed"
  [ "$(printf '%s\n' "$labels" | sed -n 1p)" = "fm-$MATE_TAG" ] || fail "the mate's herdr.space must be fm-$MATE_TAG, got: $labels"
  [ "$(printf '%s\n' "$labels" | sed -n 2p)" = "$PRIMARY_TAG-fm-$ID" ] || fail "the mate's herdr.tab must be $PRIMARY_TAG-fm-$ID, got: $labels"
  [ "$(printf '%s\n' "$labels" | sed -n 3p)" = "fm-$ID" ] || fail "the mate's firstmate.task must be fm-$ID, got: $labels"
  [ "$(printf '%s\n' "$labels" | sed -n 4p)" = "$PRIMARY_TAG" ] || fail "the mate's firstmate.home must be $PRIMARY_TAG, got: $labels"
}
agent_pid() { lab get "$(meta_field hc_terminal)" --json | jq -r '.foreground.pid // empty'; }
step() { echo; echo "### $*"; }
# Seed an existing second mate recorded on herdr with no live endpoint (as after a host restart).
cat > "$STATE/$ID.meta" <<M
kind=secondmate
backend=herdr
home=$(cd "$MATE" && pwd -P)
harness=opencode
M
step "existing record (before move)"; cat "$STATE/$ID.meta"
step "adversarial: move to cmux (not secondmate-capable)"
"$ROOT/bin/fm-secondmate-move.sh" "$ID" --backend cmux; echo "exit=$?"
step "adversarial: move to orca"
"$ROOT/bin/fm-secondmate-move.sh" "$ID" --backend orca; echo "exit=$?"
step "adversarial: move to unknown backend"
"$ROOT/bin/fm-secondmate-move.sh" "$ID" --backend nosuch; echo "exit=$?"
step "record unchanged after refusals"; cat "$STATE/$ID.meta"
step "move onto hc"
"$ROOT/bin/fm-secondmate-move.sh" "$ID" --backend hc; echo "exit=$?"
step "record after move"; cat "$STATE/$ID.meta"
[ "$(meta_field backend)" = hc ] || fail "record must name hc"
assert_mate_labels "$(meta_field hc_terminal)"; echo "labels ok: herdr.space=fm-$MATE_TAG firstmate.home=$PRIMARY_TAG"
wait_for 20 state_is alive || fail "moved mate never alive"; echo "agent state: alive"
lab get "$(meta_field hc_terminal)" --json | jq '{state,labels,foreground:{name:.foreground.name}}'
BEFORE=$(cat "$STATE/$ID.meta"); A=$(agent_pid)
step "adversarial: move alive hc mate to hc again"
"$ROOT/bin/fm-secondmate-move.sh" "$ID" --backend hc; echo "exit=$?"
step "adversarial: move alive hc mate to tmux (tmux not installed on this host)"
"$ROOT/bin/fm-secondmate-move.sh" "$ID" --backend tmux; echo "exit=$?"
step "adversarial: move a non-secondmate record"
printf 'kind=crew\nbackend=hc\n' > "$STATE/crewx.meta"; "$ROOT/bin/fm-secondmate-move.sh" crewx --backend hc; echo "exit=$?"
step "adversarial: fm-spawn --secondmate --backend cmux"
"$ROOT/bin/fm-spawn.sh" other$$ "$MATE" --secondmate --backend cmux; echo "exit=$?"
step "usage: --help tail / no args exit"
"$ROOT/bin/fm-secondmate-move.sh" --help | tail -3; echo "exit=$?"
"$ROOT/bin/fm-secondmate-move.sh" >/dev/null 2>&1; echo "no-args exit=$?"
[ "$(cat "$STATE/$ID.meta")" = "$BEFORE" ] || fail "refusals changed the record"
[ "$(agent_pid)" = "$A" ] && state_is alive || fail "refusals disturbed the alive agent"
echo "record unchanged and same agent pid $A still alive after all refusals"
fm_backend_kill hc "$(meta_field window)" '' "fm-$ID"
echo LIVE_MOVE_COMPLETE

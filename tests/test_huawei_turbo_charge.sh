#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Dependency-free tests for huawei-turbo-charge. Fixtures are real outputs
# captured from /sys/kernel/debug/huawei-wmi/call on a MateBook X Pro (VGHH-XX).
# Run: tests/test_huawei_turbo_charge.sh

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/../huawei-turbo-charge"

pass=0
fail=0

check() { # description expected actual
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"
  fi
}

[[ -r $script ]] || {
  echo "FAIL: $script not found"
  exit 1
}

export HUAWEI_TURBO_SOURCE_ONLY=1
export TURBO_RETRY_DELAY=0
# shellcheck source=../huawei-turbo-charge
source "$script"

# --- real captures -----------------------------------------------------------
SUPPORTED='[{0x00,0x00,0x00,0x00},{0x00,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x0'
SWITCH_OFF='[{0x00,0x00,0x00,0x00},{0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x0'
SWITCH_ON='[{0x00,0x00,0x00,0x00},{0x00,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x0'
SHIELDED='[{0x00,0x00,0x00,0x00},{0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x0'

# --- parser ------------------------------------------------------------------
check "out byte 0 is the EC status" 0 "$(out_byte 0 "$SUPPORTED")"
check "out byte 2 carries the value" 1 "$(out_byte 2 "$SUPPORTED")"
check "out byte 2 reads 0 when the switch is off" 0 "$(out_byte 2 "$SWITCH_OFF")"
check "shielded firmware reports a non-zero status" 1 "$(out_byte 0 "$SHIELDED")"
out_byte 2 "garbage" >/dev/null 2>&1
check "malformed input is rejected" 1 "$?"
out_byte 2 "" >/dev/null 2>&1
check "empty input is rejected" 1 "$?"
out_byte 99 "$SUPPORTED" >/dev/null 2>&1
check "reading past a truncated capture is rejected" 1 "$?"

# --- the wmi arguments must stay byte-exact (EC command 0x02D3) ----------------
check "support query argument" 0x00000002d3021002 "$ARG_SUPPORT"
check "status query argument" 0x00010002d3021002 "$ARG_STATUS"
check "enable argument" 0x00010102d3021002 "$ARG_ON"
check "disable argument" 0x00000102d3021002 "$ARG_OFF"

# --- policy: mock the hardware layer ------------------------------------------
# The script calls wmi_call inside $(...), a subshell, so the mock keeps its
# state in files rather than in variables.
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
AC=1        # 1 while the adapter reports a charger

wmi_call() { # records every call, replays queued responses in order
  printf '%s\n' "$1" >>"$state/calls"
  local next
  next=$(head -n 1 "$state/responses")
  tail -n +2 "$state/responses" >"$state/responses.new"
  mv "$state/responses.new" "$state/responses"
  printf '%s' "$next"
}
ac_online() { ((AC == 1)); }

reset() {
  : >"$state/calls"
  : >"$state/responses"
  AC=1
}
queue() { printf '%s\n' "$@" >>"$state/responses"; }
calls() { tr '\n' ' ' <"$state/calls" | sed 's/ $//'; }
call_count() { wc -l <"$state/calls" | tr -d ' '; }

# Unsupported/shielded firmware: apply must never write.
reset
queue "$SHIELDED"
cmd_apply >/dev/null 2>&1
check "apply on unsupported hardware exits cleanly" 0 "$?"
check "apply on unsupported hardware only queries support" "$ARG_SUPPORT" "$(calls)"

# Supported, first write verifies.
reset
queue "$SUPPORTED" "$SWITCH_OFF" "$SWITCH_ON"
cmd_apply >/dev/null 2>&1
check "apply succeeds when the switch reads back ON" 0 "$?"
check "apply call sequence: support, write, verify" \
  "$ARG_SUPPORT $ARG_ON $ARG_STATUS" "$(calls)"

# After a resume the adapter still reports itself offline even with the
# charger connected, and the EC has already dropped the switch by then: the
# EC decides, so the switch has to be written all the same.
reset
AC=0
queue "$SUPPORTED" "$SWITCH_OFF" "$SWITCH_ON"
cmd_apply >/dev/null 2>&1
check "apply writes the switch even when the adapter reports offline" 0 "$?"
check "apply asks the EC, not the adapter, after a resume" \
  "$ARG_SUPPORT $ARG_ON $ARG_STATUS" "$(calls)"

# The EC refuses the write and no charger is connected: nothing to do.
reset
AC=0
queue "$SUPPORTED"
cmd_apply >/dev/null 2>&1
check "apply is a no-op when the EC refuses and no charger is connected" 0 "$?"

# The EC refuses the write with a charger connected: a real failure.
reset
queue "$SUPPORTED"
cmd_apply >/dev/null 2>&1
check "apply fails when the EC refuses with a charger connected" 1 "$?"

# Supported, EC needs a retry before the switch sticks.
reset
queue "$SUPPORTED" "$SWITCH_OFF" "$SWITCH_OFF" "$SWITCH_OFF" "$SWITCH_ON"
cmd_apply >/dev/null 2>&1
check "apply retries until the switch reads back ON" 0 "$?"
check "apply retried with a second write" \
  "$ARG_SUPPORT $ARG_ON $ARG_STATUS $ARG_ON $ARG_STATUS" "$(calls)"

# Supported, switch never sticks: report failure.
reset
queue "$SUPPORTED"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do queue "$SWITCH_OFF"; done
cmd_apply >/dev/null 2>&1
check "apply fails when the switch never turns ON" 1 "$?"
check "apply gives up after the retry budget (1 support + 5 write/verify pairs)" \
  11 "$(call_count)"

# Explicit off writes the disable argument and verifies.
reset
queue "$SUPPORTED" "$SWITCH_OFF" "$SWITCH_OFF"
cmd_set off >/dev/null 2>&1
check "off succeeds when the switch reads back OFF" 0 "$?"
check "off call sequence: support, write, verify" \
  "$ARG_SUPPORT $ARG_OFF $ARG_STATUS" "$(calls)"

# Explicit on/off on unsupported hardware is a hard error (user asked for it).
reset
queue "$SHIELDED"
cmd_set on >/dev/null 2>&1
check "explicit on fails on unsupported hardware" 1 "$?"
check "explicit on never writes on unsupported hardware" "$ARG_SUPPORT" "$(calls)"

printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))

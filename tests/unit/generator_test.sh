#!/bin/sh
# Unit tests for the pure-logic parts of generator.sh:
#   - is_valid_line (the validation funnel)
#   - render_srv_body / render_ext_body (output shape)
#   - write_managed (markers, idempotency, outside-content preservation)
#
# UCI parsing (load_srv / load_ext) requires OpenWrt's /lib/functions.sh
# and is left to the live-router integration covered by uapi 2.1.0's
# tests/integration/40_unbound_uci_ext_test.sh.
#
# shellcheck disable=SC2034
# (SRV_*/EXT_* fixture vars are consumed by sourced functions, not by
# this script directly; shellcheck can't see across the source boundary.)

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
GENERATOR="$SCRIPT_DIR/../../files/usr/lib/unbound-uci-ext/generator.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# Override the target paths BEFORE sourcing so the generator's
# ${VAR:-default} idiom picks them up.
SRV_CONF="$TMP/unbound_srv.conf"
EXT_CONF="$TMP/unbound_ext.conf"
export SRV_CONF EXT_CONF

# shellcheck disable=SC1090,SC1091
. "$GENERATOR"

# Silence is_valid_line's logger output: tests deliberately trigger
# warnings (empty / over-length entries) and the noise hides real failures.
log() { :; }

# After sourcing, drop set -e so assertion-time non-zero returns are
# captured by the helpers below rather than aborting the whole suite.
set +e

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

expect_ok() {
	desc=$1
	shift
	if "$@"; then ok; else fail "$desc"; fi
}

expect_fail() {
	desc=$1
	shift
	if "$@" 2>/dev/null; then fail "$desc"; else ok; fi
}

assert_eq() {
	if [ "$1" = "$2" ]; then
		ok
	else
		printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$3" "$2" "$1"
		FAIL=$((FAIL + 1))
	fi
}

# ---------------------------------------------------------------------------
# is_valid_line
# ---------------------------------------------------------------------------

expect_ok   "accepts a normal string" \
	is_valid_line "interface: 127.0.0.1@5353" "test"
expect_fail "rejects empty string" \
	is_valid_line "" "test"
expect_fail "rejects embedded newline" \
	is_valid_line "abc
def" "test"

# Regression: the original *$(printf '\n')* glob collapsed to ** and
# rejected every non-empty input. If that bug returns, this stops passing.
expect_ok   "accepts srv_line content (newline-glob-collapse regression)" \
	is_valid_line "harden-below-nxdomain: yes" "srv_line"

# 260 chars, just over MAX_LINE_LEN (256).
big=""
i=0
while [ $i -lt 26 ]; do
	big="${big}0123456789"
	i=$((i + 1))
done
expect_fail "rejects 260-char (cap is 256)" \
	is_valid_line "$big" "test"

# 256 chars exactly: on the boundary, should accept.
boundary=""
i=0
while [ $i -lt 25 ]; do
	boundary="${boundary}0123456789"
	i=$((i + 1))
done
boundary="${boundary}012345"  # 250 + 6 = 256
expect_ok "accepts exactly MAX_LINE_LEN chars" \
	is_valid_line "$boundary" "test"

# ---------------------------------------------------------------------------
# render_srv_body
# ---------------------------------------------------------------------------

SRV_ENABLED=0
assert_eq "$(render_srv_body)" "" "disabled srv renders empty"

SRV_ENABLED=1
SRV_BIND_LINES="interface: 127.0.0.1@5353
"
SRV_OUTGOING_LINES=""
SRV_IP_TRANSPARENT=""
SRV_LINES=""
assert_eq "$(render_srv_body)" "interface: 127.0.0.1@5353" "bind only"

SRV_BIND_LINES="interface: 127.0.0.1@5353
"
SRV_OUTGOING_LINES="outgoing-interface: 192.0.2.1
"
SRV_IP_TRANSPARENT=0
SRV_LINES="harden-below-nxdomain: yes
"
expected="interface: 127.0.0.1@5353
outgoing-interface: 192.0.2.1
ip-transparent: no
harden-below-nxdomain: yes"
assert_eq "$(render_srv_body)" "$expected" "full combo"

# ip_transparent boolean fan-out matches uapi's normalize_bool contract.
SRV_BIND_LINES=""
SRV_OUTGOING_LINES=""
SRV_LINES=""
for form in 1 yes on true; do
	SRV_IP_TRANSPARENT=$form
	assert_eq "$(render_srv_body)" "ip-transparent: yes" "ip_transparent=$form -> yes"
done
for form in 0 no off false; do
	SRV_IP_TRANSPARENT=$form
	assert_eq "$(render_srv_body)" "ip-transparent: no" "ip_transparent=$form -> no"
done

# Unknown value: warn (silenced) and drop the directive.
SRV_IP_TRANSPARENT=garbage
assert_eq "$(render_srv_body)" "" "unknown ip_transparent drops the line"

# ---------------------------------------------------------------------------
# render_ext_body
# ---------------------------------------------------------------------------

EXT_ENABLED=0
assert_eq "$(render_ext_body)" "" "disabled ext renders empty"

EXT_ENABLED=1
EXT_LINES="forward-zone:
  name: \"example.org\"
  forward-addr: 1.1.1.1
"
expected='forward-zone:
  name: "example.org"
  forward-addr: 1.1.1.1'
assert_eq "$(render_ext_body)" "$expected" "forward-zone clause"

# ---------------------------------------------------------------------------
# write_managed
# ---------------------------------------------------------------------------

# Empty body to a non-existent file: no-op (exit 1, no file).
rm -f "$SRV_CONF"
expect_fail "empty body to fresh file returns 1" \
	write_managed "$SRV_CONF" ""
if [ ! -f "$SRV_CONF" ]; then ok; else fail "empty body should not create file"; fi

# Non-empty body to a fresh file: changed (exit 0), markers + body present.
body="interface: 127.0.0.1@5353
ip-transparent: no"
expect_ok "non-empty write to fresh file returns 0" \
	write_managed "$SRV_CONF" "$body"
if [ -f "$SRV_CONF" ]; then ok; else fail "non-empty write should create the file"; fi

expect_ok "open marker present"  grep -q "^# >>> unbound-uci-ext managed (do not edit) <<<\$" "$SRV_CONF"
expect_ok "close marker present" grep -q "^# <<< unbound-uci-ext managed <<<\$" "$SRV_CONF"
expect_ok "interface line present"    grep -q "^interface: 127.0.0.1@5353\$" "$SRV_CONF"
expect_ok "ip-transparent line present" grep -q "^ip-transparent: no\$" "$SRV_CONF"

# Regression: the close marker must sit on its own line, not fused onto
# the last body line. (Was a real bug from the wrong printf format.)
last_body_lineno=$(grep -n "^ip-transparent: no\$" "$SRV_CONF" | head -1 | cut -d: -f1)
next_line=$(sed -n "$((last_body_lineno + 1))p" "$SRV_CONF")
assert_eq "$next_line" "# <<< unbound-uci-ext managed <<<" \
	"close marker must follow body on its own line"

# Idempotency: same body again -> exit 1, file unchanged.
hash_before=$(sha256sum "$SRV_CONF" | awk '{print $1}')
expect_fail "idempotent write returns 1" \
	write_managed "$SRV_CONF" "$body"
hash_after=$(sha256sum "$SRV_CONF" | awk '{print $1}')
assert_eq "$hash_before" "$hash_after" "idempotent write must not touch the file"

# Different body -> exit 0, content reflects the change.
expect_ok "changed body returns 0" \
	write_managed "$SRV_CONF" "ip-transparent: yes"
expect_ok "new body line present" \
	grep -q "^ip-transparent: yes\$" "$SRV_CONF"
expect_fail "old body line removed" \
	grep -q "^ip-transparent: no\$" "$SRV_CONF"

# Content outside the managed markers is preserved across rewrites.
preserve_conf="$TMP/preserve.conf"
cat > "$preserve_conf" <<'EOF'
# preserved comment above
some-other-directive: yes
EOF
write_managed "$preserve_conf" "interface: 10.0.0.1@53" >/dev/null
expect_ok "preserved comment kept" \
	grep -q "^# preserved comment above\$" "$preserve_conf"
expect_ok "preserved directive kept" \
	grep -q "^some-other-directive: yes\$" "$preserve_conf"
expect_ok "managed body line written" \
	grep -q "^interface: 10.0.0.1@53\$" "$preserve_conf"

# Empty body strips the managed region but leaves outside content alone.
write_managed "$preserve_conf" "" >/dev/null
expect_ok "comment survives empty body" \
	grep -q "^# preserved comment above\$" "$preserve_conf"
expect_fail "markers stripped after empty body" \
	grep -q "^# >>> unbound-uci-ext managed" "$preserve_conf"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

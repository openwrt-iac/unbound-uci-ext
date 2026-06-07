#!/bin/sh
# shellcheck shell=bash
# shellcheck disable=SC1091
#
# Render two UCI namespaces into two unbound seam files:
#
#   /etc/config/unbound_srv  -> /etc/unbound/unbound_srv.conf
#       inside the server: clause (unbound auto-includes after server: opens).
#   /etc/config/unbound_ext  -> /etc/unbound/unbound_ext.conf
#       at the end of unbound.conf (outside the server: clause), used for
#       forward-zone:, view:, stub:, remote-control: blocks.
#
# Each target file's managed region sits between fixed marker comments;
# content outside the markers is preserved. Restarts unbound iff at least
# one of the two files actually changed (diff against current).
#
# Commands:
#   apply   read both UCIs, rewrite both managed regions, restart if needed.
#   clear   force both managed regions empty, restart if anything changed.

set -e
# Not `set -u`: /lib/functions.sh references several variables (IPKG_INSTROOT,
# CONFIG_LIST_STATE, ...) without first defaulting them, which trips strict
# unset-checking on every config_load. The trade is real but small - OpenWrt's
# shell library is not -u-clean by convention.

# Target paths are env-overridable so the unit-test harness can redirect
# write_managed at a tempdir without forking a chroot.
SRV_CONF=${SRV_CONF:-/etc/unbound/unbound_srv.conf}
EXT_CONF=${EXT_CONF:-/etc/unbound/unbound_ext.conf}
MARK_OPEN='# >>> unbound-uci-ext managed (do not edit) <<<'
MARK_CLOSE='# <<< unbound-uci-ext managed <<<'
MAX_LINE_LEN=256

log() { logger -t unbound-uci-ext -- "$@"; }

# /lib/functions.sh is sourced inside load_srv / load_ext rather than at
# top-level so the script can be sourced by the unit-test harness on a
# plain Linux box (no OpenWrt lib present) to exercise the pure-logic
# functions. Sourcing functions.sh is idempotent; the dual-call cost is
# a single fs read.

# Returns 0 if the value passes the structural rules (non-empty, no embedded
# newline, length cap), 1 otherwise. Logs a warning on rejection. Applied
# uniformly to every passthrough field so a malformed entry can't escape the
# managed region or break unbound's parser.
is_valid_line() {
	local v=$1 source=$2
	# Command substitution strips trailing newlines, so `*$(printf '\n')*`
	# collapses to `**` and matches everything. Embed a literal LF in the
	# glob via a continued line instead.
	case "$v" in
		'') log "warn: ignoring empty $source"; return 1 ;;
		*"
"*) log "warn: ignoring $source with embedded newline"; return 1 ;;
	esac
	if [ "${#v}" -gt "$MAX_LINE_LEN" ]; then
		log "warn: ignoring $source longer than $MAX_LINE_LEN chars"
		return 1
	fi
	return 0
}

load_srv() {
	. /lib/functions.sh
	SRV_ENABLED=
	SRV_IP_TRANSPARENT=
	SRV_BIND_LINES=
	SRV_OUTGOING_LINES=
	SRV_LINES=

	parse_srv() {
		local cfg="$1"
		config_get_bool SRV_ENABLED "$cfg" enabled 0
		config_get SRV_IP_TRANSPARENT "$cfg" ip_transparent ""
		config_list_foreach "$cfg" interface_bind     bundle_srv_bind
		config_list_foreach "$cfg" interface_outgoing bundle_srv_outgoing
		config_list_foreach "$cfg" srv_line           bundle_srv_line
	}
	bundle_srv_bind() {
		is_valid_line "$1" "interface_bind" || return 0
		SRV_BIND_LINES="${SRV_BIND_LINES}interface: $1
"
	}
	bundle_srv_outgoing() {
		is_valid_line "$1" "interface_outgoing" || return 0
		SRV_OUTGOING_LINES="${SRV_OUTGOING_LINES}outgoing-interface: $1
"
	}
	bundle_srv_line() {
		is_valid_line "$1" "srv_line" || return 0
		SRV_LINES="${SRV_LINES}$1
"
	}

	config_load unbound_srv
	config_foreach parse_srv unbound_srv
}

load_ext() {
	. /lib/functions.sh
	EXT_ENABLED=
	EXT_LINES=

	parse_ext() {
		local cfg="$1"
		config_get_bool EXT_ENABLED "$cfg" enabled 0
		config_list_foreach "$cfg" ext_line bundle_ext_line
	}
	bundle_ext_line() {
		is_valid_line "$1" "ext_line" || return 0
		EXT_LINES="${EXT_LINES}$1
"
	}

	config_load unbound_ext
	config_foreach parse_ext unbound_ext
}

render_srv_body() {
	[ "$SRV_ENABLED" = "1" ] || return 0
	printf '%s' "$SRV_BIND_LINES"
	printf '%s' "$SRV_OUTGOING_LINES"
	# Accept the same boolean forms uapi's normalize_bool does, so hand-edits
	# to /etc/config/unbound_srv with `'yes'` / `'true'` work the same as `'1'`.
	case "$SRV_IP_TRANSPARENT" in
		1|yes|on|true)  echo "ip-transparent: yes" ;;
		0|no|off|false) echo "ip-transparent: no" ;;
		'') : ;;
		*) log "warn: ip_transparent value $SRV_IP_TRANSPARENT not understood, skipping" ;;
	esac
	printf '%s' "$SRV_LINES"
}

render_ext_body() {
	[ "$EXT_ENABLED" = "1" ] || return 0
	printf '%s' "$EXT_LINES"
}

strip_managed() {
	local file=$1
	[ -f "$file" ] || return 0
	# `close` clashes with awk's built-in close() function on busybox awk's
	# parser - it errors out with "Unexpected token". Use unreserved names
	# for the -v bindings.
	awk -v omark="$MARK_OPEN" -v cmark="$MARK_CLOSE" '
		$0 == omark { in_managed = 1; next }
		$0 == cmark { in_managed = 0; next }
		!in_managed { print }
	' "$file"
}

# Exit code IS the "changed" flag, not POSIX-standard success/failure:
#   0 = wrote a new file (caller should restart unbound)
#   1 = on-disk content is already correct (caller skips restart)
# Lets the caller chain `write_managed ... && changed=1` cleanly.
write_managed() {
	local file=$1 body=$2 outer new
	outer=$(strip_managed "$file")

	if [ -n "$body" ]; then
		# The %s for $body must be followed by \n: command substitution on
		# render_*_body strips the trailing newline, so without an explicit
		# separator the close marker fuses onto the last rendered directive.
		new=$(printf '%s%s\n%s\n%s\n' \
			"${outer:+$outer
}" \
			"$MARK_OPEN" \
			"$body" \
			"$MARK_CLOSE")
	else
		new="$outer"
	fi

	local old=""
	[ -f "$file" ] && old=$(cat "$file")
	[ "$new" = "$old" ] && return 1

	mkdir -p "$(dirname "$file")"
	local tmp
	tmp=$(mktemp -p "$(dirname "$file")" .ub_uciext.XXXXXX)
	: "${tmp:?mktemp returned empty path; refusing to write}"
	printf '%s\n' "$new" > "$tmp"
	chmod 0644 "$tmp"
	mv "$tmp" "$file"
	log "rewrote $file"
	return 0
}

restart_unbound() {
	if [ ! -x /etc/init.d/unbound ]; then
		log "warn: /etc/init.d/unbound not found; skipping restart"
		return 0
	fi
	local err
	err=$(/etc/init.d/unbound restart 2>&1) || \
		log "warn: /etc/init.d/unbound restart failed: $err"
}

cmd_apply() {
	load_srv
	load_ext
	local changed=0
	# unbound restart drops the recursive cache; skip when neither file moved.
	write_managed "$SRV_CONF" "$(render_srv_body)" && changed=1
	write_managed "$EXT_CONF" "$(render_ext_body)" && changed=1
	[ "$changed" = "1" ] && restart_unbound
	return 0
}

cmd_clear() {
	local changed=0
	write_managed "$SRV_CONF" "" && changed=1
	write_managed "$EXT_CONF" "" && changed=1
	[ "$changed" = "1" ] && restart_unbound
	return 0
}

# Dispatch only when invoked with a verb. Sourcing without args (e.g. from
# the unit-test harness) becomes a no-op so callers can exercise the
# library functions directly.
if [ "$#" -gt 0 ]; then
	case "$1" in
		apply) cmd_apply ;;
		clear) cmd_clear ;;
		*)     echo "usage: $0 {apply|clear}" >&2; exit 2 ;;
	esac
fi

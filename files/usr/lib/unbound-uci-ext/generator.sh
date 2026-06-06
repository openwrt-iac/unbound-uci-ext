#!/bin/sh
# shellcheck shell=bash
# shellcheck disable=SC1091
#
# Read /etc/config/unbound_ext, render the configured directives into a
# managed region of /etc/unbound/unbound_srv.conf (unbound's documented
# extended-conf seam, auto-included inside the server: clause), then
# restart unbound if the file changed.
#
# Commands:
#   apply   render the region (or rewrite it on change). enabled '0' or
#           an absent section removes the region.
#   clear   unconditionally remove the region. Used by the package's
#           prerm and by the init script's stop_service.

set -eu

SRV_CONF=/etc/unbound/unbound_srv.conf
MARK_OPEN='# >>> unbound-uci-ext managed (do not edit) <<<'
MARK_CLOSE='# <<< unbound-uci-ext managed <<<'

# Linux IFNAMSIZ-1 for kernel ifnames; uci section-name rules also reject
# this regex's outsiders. Pattern matches IPv4, IPv6 (including bracketed
# `[::1]@5353` form), and optional `@port` suffix. Loose by design - apk
# already mkndx-signs whatever lands here; the real validator is unbound's
# own parser via `unbound-checkconf` after restart.
#
# We don't validate values past a basic shape check (no newline injection,
# length cap). The contract is "operator types something unbound would
# accept"; we surface unbound-checkconf failures loudly when they happen.

MAX_LINE_LEN=256

log() { logger -t unbound-uci-ext -- "$@"; }

# Read the configured options. `config_list_foreach` invokes the callback
# once per `list <name> '<val>'` entry, with $1=section $2=value.
load_options() {
	. /lib/functions.sh

	ENABLED=
	IP_TRANSPARENT=
	BIND_LINES=
	OUTGOING_LINES=
	SRV_LINES=

	config_load unbound_ext

	parse_section() {
		local cfg="$1"
		# Only act on the canonical singleton section (named or anonymous
		# 'main'). Forward-compat: if a future schema grows multi-section,
		# `config_foreach` callers can iterate and union here.
		config_get_bool ENABLED "$cfg" enabled 0
		config_get IP_TRANSPARENT "$cfg" ip_transparent ""

		BIND_LINES=
		OUTGOING_LINES=
		SRV_LINES=

		config_list_foreach "$cfg" interface_bind     bundle_bind
		config_list_foreach "$cfg" interface_outgoing bundle_outgoing
		config_list_foreach "$cfg" srv_line           bundle_srv_line
	}

	bundle_bind()     { BIND_LINES="${BIND_LINES}interface: $1
"; }
	bundle_outgoing() { OUTGOING_LINES="${OUTGOING_LINES}outgoing-interface: $1
"; }
	bundle_srv_line() {
		# Reject empty, too-long, or newline-containing values verbatim.
		# Don't try to validate against unbound's grammar here; let
		# unbound-checkconf do that after restart.
		local v="$1"
		case "$v" in
			'') log "warn: ignoring empty srv_line"; return ;;
			*$(printf '\n')*) log "warn: ignoring srv_line with embedded newline"; return ;;
		esac
		if [ "${#v}" -gt "$MAX_LINE_LEN" ]; then
			log "warn: ignoring srv_line longer than $MAX_LINE_LEN chars"
			return
		fi
		SRV_LINES="${SRV_LINES}$v
"
	}

	config_foreach parse_section unbound_ext
}

# Build the managed-region body (between the two markers, not including
# them) into stdout. Empty body if enabled is 0 or there are no directives.
render_body() {
	[ "$ENABLED" = "1" ] || return 0
	printf '%s' "$BIND_LINES"
	printf '%s' "$OUTGOING_LINES"
	case "$IP_TRANSPARENT" in
		1|yes|on|true) echo "ip-transparent: yes" ;;
		0|no|off|false) echo "ip-transparent: no" ;;
		'') : ;;
		*) log "warn: ip_transparent value $IP_TRANSPARENT not understood, skipping" ;;
	esac
	printf '%s' "$SRV_LINES"
}

# Read the existing srv conf (if any) into stdout with the managed region
# stripped out. This is the unchanged portion we'll preserve.
strip_managed() {
	[ -f "$SRV_CONF" ] || return 0
	awk -v open="$MARK_OPEN" -v close="$MARK_CLOSE" '
		$0 == open { in_managed = 1; next }
		$0 == close { in_managed = 0; next }
		!in_managed { print }
	' "$SRV_CONF"
}

write_srv_conf() {
	local body="$1" outer
	outer=$(strip_managed)

	local new
	if [ -n "$body" ]; then
		new=$(printf '%s%s\n%s%s\n' \
			"${outer:+$outer
}" \
			"$MARK_OPEN" \
			"$body" \
			"$MARK_CLOSE")
	else
		new="$outer"
	fi

	# Compare against current file to decide if a restart is needed.
	local old=""
	[ -f "$SRV_CONF" ] && old=$(cat "$SRV_CONF")
	if [ "$new" = "$old" ]; then
		log "no change in $SRV_CONF; skipping unbound restart"
		return 1   # caller interprets non-zero as "no restart needed"
	fi

	mkdir -p "$(dirname "$SRV_CONF")"
	# Write atomically via a temp file in the same dir.
	local tmp
	tmp=$(mktemp -p "$(dirname "$SRV_CONF")" .unbound_srv.XXXXXX)
	printf '%s\n' "$new" > "$tmp"
	chmod 0644 "$tmp"
	mv "$tmp" "$SRV_CONF"
	log "rewrote $SRV_CONF"
	return 0
}

restart_unbound() {
	if [ -x /etc/init.d/unbound ]; then
		/etc/init.d/unbound restart >/dev/null 2>&1 || \
			log "warn: /etc/init.d/unbound restart returned non-zero"
	else
		log "warn: /etc/init.d/unbound not found; skipping restart"
	fi
}

cmd_apply() {
	load_options
	local body
	body=$(render_body)
	if write_srv_conf "$body"; then
		restart_unbound
	fi
}

cmd_clear() {
	# Force the managed region to empty regardless of current UCI state.
	if write_srv_conf ""; then
		restart_unbound
	fi
}

case "${1:-}" in
	apply) cmd_apply ;;
	clear) cmd_clear ;;
	*)     echo "usage: $0 {apply|clear}" >&2; exit 2 ;;
esac

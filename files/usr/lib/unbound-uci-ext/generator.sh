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

set -eu

SRV_CONF=/etc/unbound/unbound_srv.conf
EXT_CONF=/etc/unbound/unbound_ext.conf
MARK_OPEN='# >>> unbound-uci-ext managed (do not edit) <<<'
MARK_CLOSE='# <<< unbound-uci-ext managed <<<'
MAX_LINE_LEN=256

log() { logger -t unbound-uci-ext -- "$@"; }

# ---------------------------------------------------------------------------
# UCI loading
# ---------------------------------------------------------------------------

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
	bundle_srv_bind()     { SRV_BIND_LINES="${SRV_BIND_LINES}interface: $1
"; }
	bundle_srv_outgoing() { SRV_OUTGOING_LINES="${SRV_OUTGOING_LINES}outgoing-interface: $1
"; }
	bundle_srv_line()     { append_line SRV_LINES "$1" "srv_line"; }

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
	bundle_ext_line() { append_line EXT_LINES "$1" "ext_line"; }

	config_load unbound_ext
	config_foreach parse_ext unbound_ext
}

# Shared safety check for raw passthrough entries: no embedded newlines,
# length cap. Doesn't validate against unbound's grammar; let
# unbound-checkconf flag malformed lines after restart.
append_line() {
	local var=$1 v=$2 source=$3
	case "$v" in
		'') log "warn: ignoring empty $source"; return ;;
		*$(printf '\n')*) log "warn: ignoring $source with embedded newline"; return ;;
	esac
	if [ "${#v}" -gt "$MAX_LINE_LEN" ]; then
		log "warn: ignoring $source longer than $MAX_LINE_LEN chars"
		return
	fi
	eval "$var=\"\${$var}\$v
\""
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

render_srv_body() {
	[ "$SRV_ENABLED" = "1" ] || return 0
	printf '%s' "$SRV_BIND_LINES"
	printf '%s' "$SRV_OUTGOING_LINES"
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

# ---------------------------------------------------------------------------
# Managed-region write
# ---------------------------------------------------------------------------

strip_managed() {
	local file=$1
	[ -f "$file" ] || return 0
	awk -v open="$MARK_OPEN" -v close="$MARK_CLOSE" '
		$0 == open { in_managed = 1; next }
		$0 == close { in_managed = 0; next }
		!in_managed { print }
	' "$file"
}

# Returns 0 if the file changed, 1 if it's identical to what was there.
# Used by the caller to decide whether unbound needs a restart.
write_managed() {
	local file=$1 body=$2 outer new
	outer=$(strip_managed "$file")

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

	local old=""
	[ -f "$file" ] && old=$(cat "$file")
	[ "$new" = "$old" ] && return 1

	mkdir -p "$(dirname "$file")"
	local tmp
	tmp=$(mktemp -p "$(dirname "$file")" .ub_uciext.XXXXXX)
	printf '%s\n' "$new" > "$tmp"
	chmod 0644 "$tmp"
	mv "$tmp" "$file"
	log "rewrote $file"
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

# ---------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------

cmd_apply() {
	load_srv
	load_ext
	local changed=0
	# write_managed returns 0 on change; the `&&` short-circuit only flips
	# changed to 1 when the write actually happened. unbound restart is
	# expensive (drops cache); skip it when neither file moved.
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

case "${1:-}" in
	apply) cmd_apply ;;
	clear) cmd_clear ;;
	*)     echo "usage: $0 {apply|clear}" >&2; exit 2 ;;
esac

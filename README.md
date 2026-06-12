# unbound-uci-ext

OpenWrt package: UCI surface for unbound directives that the main unbound package deliberately keeps out of UCI.

> Not affiliated with the OpenWrt or unbound projects. This package started as the work of a single operator solving a specific problem on their own network, shared in the open in the hope it is useful to others with similar needs.

Two UCI namespaces map 1:1 to unbound's two documented extended-conf seam files:

| UCI namespace | Target file | Position in unbound.conf |
|---|---|---|
| `/etc/config/unbound_srv` | `/etc/unbound/unbound_srv.conf` | inside the `server:` clause |
| `/etc/config/unbound_ext` | `/etc/unbound/unbound_ext.conf` | at the end of `unbound.conf`, outside the server clause |

## Why a separate package

OpenWrt's main unbound package leaves advanced directives out of UCI on purpose ([commit `658c27ea9`](https://github.com/openwrt/packages/commit/658c27ea9), closing [#13750](https://github.com/openwrt/packages/issues/13750)):

> Interface wild cards are not explicitly set so that they can be customized in extended conf.

unbound's two seam files (`unbound_srv.conf` and `unbound_ext.conf`) are the documented extension points. This package owns a managed region of each, written from its own UCI surface.

## Install

Requires the [openwrt-iac feed](https://openwrt-iac.github.io/install/):

```sh
apk add unbound-uci-ext
```

`unbound-daemon` is pulled in as a dependency.

## Configure: server-clause directives (`unbound_srv`)

For directives that belong inside `server:` (interface binding, recursion source, harden flags, etc.). Example: a loopback-only recursive resolver behind dnsmasq.

```sh
uci set unbound_srv.main.enabled='1'
uci add_list unbound_srv.main.interface_bind='127.0.0.1@5353'
uci set unbound.@unbound[0].interface_auto='0'   # pair: make the bind exclusive
uci commit
/etc/init.d/unbound-uci-ext reload
```

### `unbound_srv` options

| Option | unbound directive | Notes |
|---|---|---|
| `list interface_bind` | `interface:` | Addresses to listen on. `addr` or `addr@port`. Pair with `interface_auto '0'` in the main unbound UCI for exclusive binding. |
| `list interface_outgoing` | `outgoing-interface:` | Source IP(s) for upstream recursion (multi-WAN). |
| `option ip_transparent` | `ip-transparent:` | Bind to not-yet-up / VIP / alias addresses. `1`/`0`. |
| `list srv_line` | verbatim | Raw `server:`-clause passthrough for anything not curated above. |

## Configure: outside-server clauses (`unbound_ext`)

For directives that start NEW clauses (`forward-zone:`, `view:`, `stub:`, `remote-control:`). Example: a forward-zone for one domain.

```sh
uci set unbound_ext.main.enabled='1'
uci add_list unbound_ext.main.ext_line='forward-zone:'
uci add_list unbound_ext.main.ext_line='  name: "example.org"'
uci add_list unbound_ext.main.ext_line='  forward-addr: 1.1.1.1'
uci commit
/etc/init.d/unbound-uci-ext reload
```

### `unbound_ext` options

| Option | unbound | Notes |
|---|---|---|
| `list ext_line` | verbatim line | Each entry is one line of the final `unbound_ext.conf` managed region. Construct whole clauses by listing them in order. The generator does no clause-aware validation; `unbound-checkconf` flags malformed output after the restart. |

## Uninstall

```sh
apk del unbound-uci-ext
```

prerm strips both managed regions and restarts unbound. The seam files themselves stay; only the marked regions go.

## How it works

The generator at `/usr/lib/unbound-uci-ext/generator.sh`:

1. Reads `/etc/config/unbound_srv` and `/etc/config/unbound_ext`.
2. Renders each into a managed region (between fixed marker comments) of its target file. Content outside the markers is preserved verbatim. Either UCI's section with `enabled '0'` or absent has its managed region emptied.
3. Diffs each target against its pre-write content; if EITHER changed, `/etc/init.d/unbound restart`. Same input ⇒ no restart.

The init script (`/etc/init.d/unbound-uci-ext`) is procd-oneshot; it registers `procd_add_reload_trigger` on both `unbound_srv` and `unbound_ext`, so `uci commit` on either namespace re-runs the generator automatically.

## License

MIT.

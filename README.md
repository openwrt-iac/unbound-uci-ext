# unbound-uci-ext

OpenWrt package: UCI extension exposing unbound `server:` directives that the main unbound package deliberately keeps out of its UCI surface.

Use cases:
- Run unbound as a loopback-only recursive backend behind dnsmasq (`127.0.0.1@5353`).
- Pin outgoing recursion to a specific WAN source IP (multi-WAN).
- Bind unbound to addresses that aren't up at boot time (`ip-transparent`).
- Drop verbatim `server:` lines for anything not curated.

## Why a separate package

OpenWrt's main unbound package authors leave advanced `server:` options out of UCI on purpose ([commit `658c27ea9`](https://github.com/openwrt/packages/commit/658c27ea9), closing [#13750](https://github.com/openwrt/packages/issues/13750)):

> Interface wild cards are not explicitly set so that they can be customized in extended conf.

`/etc/unbound/unbound_srv.conf` is the documented extension seam. unbound's init auto-includes it inside the `server:` clause on every restart. This package owns a managed region of that file and writes UCI-rendered directives into it.

## Install

Requires the [openwrt-iac feed](https://openwrt-iac.github.io/install/):

```sh
apk add unbound-uci-ext
```

`unbound-daemon` is pulled in as a dependency.

## Configure

```sh
uci set unbound_ext.main.enabled='1'
uci add_list unbound_ext.main.interface_bind='127.0.0.1@5353'
uci set unbound.@unbound[0].interface_auto='0'   # pair: make the bind exclusive
uci commit
/etc/init.d/unbound-uci-ext reload
```

After the reload, `/etc/unbound/unbound_srv.conf` contains a managed region between markers; check `/var/lib/unbound/unbound.conf` and run `unbound-checkconf` to confirm the directives landed.

### UCI options

| Option | unbound directive | Notes |
|---|---|---|
| `list interface_bind` | `interface:` | Addresses to listen on. `addr` or `addr@port`. Pair with `interface_auto '0'` in the main unbound UCI for exclusive binding. |
| `list interface_outgoing` | `outgoing-interface:` | Source IP(s) for upstream recursion. |
| `option ip_transparent` | `ip-transparent:` | Bind to not-yet-up / VIP / alias addresses. `1`/`0`. |
| `list srv_line` | verbatim | Raw `server:`-clause passthrough for anything not curated above. |

The escape hatch (`srv_line`) is intentional: any future curated option you'd want lives one verbatim line away. File an issue if you'd like an option promoted from `srv_line` to first-class.

## Uninstall

```sh
apk del unbound-uci-ext
```

prerm strips the managed region from `/etc/unbound/unbound_srv.conf` and restarts unbound, so removal leaves no stale directives behind.

## How it works

The generator at `/usr/lib/unbound-uci-ext/generator.sh`:
1. Reads `/etc/config/unbound_ext`.
2. Renders the directives into the managed region of `/etc/unbound/unbound_srv.conf` (between fixed marker comments). Content outside the markers is preserved verbatim.
3. Diffs the result; if changed, `/etc/init.d/unbound restart`. Same input ⇒ no restart.

The init script (`/etc/init.d/unbound-uci-ext`) is procd-oneshot; it registers a `procd_add_reload_trigger` on `unbound_ext` so `uci commit unbound_ext` re-runs the generator automatically.

## License

MIT.

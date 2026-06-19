# unbound-uci-ext

OpenWrt package that exposes unbound directives the main `unbound` package deliberately keeps out of UCI. Two UCI namespaces map 1:1 to unbound's two documented extended-conf seam files. A single shell generator renders managed regions into both seam files and restarts unbound when (and only when) something actually changed.

This document captures the design contract. Changes here require the same scrutiny as code changes.

---

## Architectural principles (non-negotiable)

1. **Use the documented seam files; never patch unbound.** unbound ships `/etc/unbound/unbound_srv.conf` (auto-included inside the `server:` clause) and `/etc/unbound/unbound_ext.conf` (appended outside the server clause). These are the sanctioned extension points. We own a managed region of each. Anything outside the markers stays verbatim.
2. **Single source of truth: UCI.** Operators (and uapi, and LuCI) edit `/etc/config/unbound_srv` and `/etc/config/unbound_ext`. The generator is a pure function from those two UCIs to the two seam files; it never writes anything else.
3. **Restart unbound only when content changed.** unbound's restart drops the recursive cache, which is real user-visible cost. The generator diffs the rendered file against the existing content and skips the restart on a no-op rewrite.
4. **No grammar validation in the generator.** Structural checks only (no embedded newline, max line length, non-empty). unbound's grammar is unbound's job; `unbound-checkconf` flags malformed output on the restart.

Before adopting new behavior, check it against these four. Prefer driving the underlying daemon's UCI surface if the option exists upstream; the bar for adding a new field here is "the main unbound package will not surface this and an operator-facing case demands it."

---

## The integration seam (verified facts)

Confirmed against unbound 1.25.1 from `openwrt/packages`:

- `/etc/unbound/unbound_srv.conf` is **included inside** the `server:` clause. unbound's own template (`/etc/unbound/unbound.conf.template`) emits `include: /etc/unbound/unbound_srv.conf` from inside `server:`. Directives like `interface:`, `outgoing-interface:`, `ip-transparent:`, plus passthrough lines land in that scope.
- `/etc/unbound/unbound_ext.conf` is **appended at the end** of `unbound.conf`, after `server:` has closed. Used for clauses that open new top-level sections: `forward-zone:`, `view:`, `stub:`, `remote-control:`.
- unbound's own `unbound.sh` re-renders `unbound.conf` on each restart; both seam files are read every time.

The OpenWrt unbound maintainer keeps these advanced directives out of UCI on purpose (commit `658c27ea9`). This package gives the sanctioned seam files a UCI surface; it does NOT fork or patch unbound.

---

## Architecture (the four pieces)

```
/etc/config/unbound_srv          UCI (singleton `main`, conffile)
/etc/config/unbound_ext          UCI (singleton `main`, conffile)
/etc/init.d/unbound-uci-ext      procd oneshot; wraps the generator + trigger
/usr/lib/unbound-uci-ext/        package-owned
  generator.sh                   the workhorse (`apply` | `clear`)
```

**UCI surface:**

| File | Section | Field | Renders to |
|---|---|---|---|
| `unbound_srv` | `main` | `enabled` | gate; `0` empties the region |
| | | `interface_bind[]` | `interface: <addr[@port]>` (one per entry) |
| | | `interface_outgoing[]` | `outgoing-interface: <addr>` |
| | | `ip_transparent` | `ip-transparent: yes|no` |
| | | `srv_line[]` | verbatim |
| `unbound_ext` | `main` | `enabled` | gate |
| | | `ext_line[]` | verbatim, one line each |

Both are conffiles. Operator edits + `apk` upgrades stay clean.

**procd init (`/etc/init.d/unbound-uci-ext`):**
- `start_service` / `reload_service` → `generator apply`
- `stop_service` → `generator clear`
- `service_triggers` registers `procd_add_reload_trigger "unbound_srv" "unbound_ext"`, so `uci commit unbound_srv` (from LuCI, shell, uapi) fires the generator automatically.

**The managed region marker (must stay byte-stable):**

```
# >>> unbound-uci-ext managed (do not edit) <<<
<rendered lines>
# <<< unbound-uci-ext managed <<<
```

Anything outside the markers is preserved verbatim. If the markers are absent (fresh file), the generator appends a fresh block at the end.

---

## Generator invariants

1. **Idempotent.** Same UCI input twice in a row produces a byte-identical seam file. The diff check then skips the restart. Any change to render output that breaks this is a regression.
2. **Atomic write.** Generator writes via `mktemp` in the target directory + `mv`. A crash mid-render leaves the prior content intact.
3. **All-or-nothing per seam file.** A bad entry in one list does not corrupt the file; the entry is dropped with a `logger` line and the rest renders.
4. **Restart only on actual change.** `cat <old> = cat <new>` short-circuits the restart.

---

## Validation boundary

The generator rejects three things and emits a `logger` warning for each:
- empty string
- entry containing an embedded newline (would break out of the managed region)
- entry longer than `MAX_LINE_LEN` (256) characters

That is the complete validation surface. Everything else passes through to unbound, and `unbound-checkconf` is the source of truth for unbound's grammar after the restart.

uapi's curated `unbound/srv` + `unbound/ext` modules mirror exactly the same boundary at PATCH time, so clients get a 422 instead of a silently dropped line. If validation here changes, uapi's modules must change with it.

---

## Code style

- **Priorities, in order:** simplicity, correctness, idempotency, slop-free.
- **No em-dashes.** Anywhere. Code, comments, README, commit messages, CHANGELOG.
- **Comments are rare.** Default to writing none. Naming carries the meaning. The exceptions: load-bearing WHY comments for non-obvious shell traps (see "Generator gotchas" below). Each surviving comment has to pass the bar: "a maintainer reading this asks 'why is this here?' and gets a non-obvious answer."
- **No what-comments**, no narrator headers (`# ---- section ----`), no ceremonial logger lines.
- **No `set -u`** in shell that sources `/lib/functions.sh`. The library is not `-u`-clean (it references `IPKG_INSTROOT`, `CONFIG_LIST_STATE`, and friends without defaulting them). `set -e` is sufficient.
- **`/lib/functions.sh` is sourced inside `load_srv` / `load_ext`, not at top-level.** The cost is a single fs read on the second loader call (the source is idempotent); the benefit is the unit-test harness can source the generator on a plain Linux box without OpenWrt's lib being present.

### Branch + PR workflow

All code changes land via a PR, never via direct push to `main`. Cut a branch (`release/v<version>` for releases, `feat/<topic>` or `fix/<topic>` otherwise), push the branch, open the PR with `gh pr create --base main`, wait for CI to pass on the branch, then merge only when explicitly told. The PR is the reviewable diff; direct-pushing bypasses that gate even when CI passes locally. Force-with-lease is permitted on the branch, never on `main`. Tag-creation discipline is unchanged: signed annotated tag after merge, only when explicitly told to tag. Applies to every repo under the `openwrt-iac` org.

---

## Generator gotchas (load-bearing WHY)

These cost a live-router debug round-trip during uapi 2.1.0 verification. Every one survives in the source today as a code-near comment. Do not re-introduce.

1. **`set -u` + `/lib/functions.sh`** trips "parameter not set" on every `config_load` (multiple unset refs in the library). Use `set -e` only.
2. **`awk -v close=...`** clashes with awk's built-in `close()` function and busybox awk errors out with "Unexpected token" at parse time. Use unreserved names (`omark` / `cmark`) for `-v` bindings.
3. **`*$(printf '\n')*`** does NOT do what it looks like: command substitution strips trailing newlines, so the glob collapses to `**` and matches every non-empty string. Embed a literal LF in the case pattern via line continuation:
   ```sh
   case "$v" in
       *"
   "*) ... ;;
   esac
   ```
4. **printf format separator.** `$(render_*_body)` strips the body's trailing newline, so the write_managed printf format MUST emit an explicit `\n` between body and close marker:
   ```sh
   printf '%s%s\n%s\n%s\n' "$outer" "$open" "$body" "$close"
   ```
   The earlier `'%s%s\n%s%s\n'` form fused the close marker onto the last rendered directive.

---

## Versioning

Independent SemVer per repo (`VERSION` at repo root).

- **MAJOR (`x+1.0.0`)**: breaking change to the UCI shape OR to the rendered marker block (operator's seam files would need migration).
- **MINOR (`x.y+1.0`)**: additive UCI options, additive rendered output.
- **PATCH (`x.y.z+1`)**: bug fixes; same UCI in → same rendered out, modulo the bug being fixed.

Tags are signed (GPG fingerprint `9CAFADF955878D514497B16EE4B5C3548E3CFB30`); CI's release-apk job refuses unsigned tags. The aggregator at `openwrt-iac/openwrt-iac.github.io` picks up stable releases (`--exclude-pre-releases`) for the apk feed.

---

## Testing posture

Current:
- **shellcheck lint** on `generator.sh` and the init script (CI `lint` job).
- **Multi-arch build verification** (PKGARCH:=all should produce byte-identical APKs across `aarch64_generic`, `arm_cortex-a7`, `mips_24kc`; CI matrix asserts).

Known gap:
- **No functional tests on the generator.** The four gotchas above were caught only by the live router run during uapi 2.1.0 verification. A `tests/generator_snapshot/` runner (canned UCI fixtures → rendered output diff + idempotency check) is the right shape and would have caught all four. Follow-up plan; not in 0.2.1.

When adding a new field or render branch, write a snapshot fixture for it once the runner exists. Until then, exercise the change against a live unbound (the uapi 2.1.0 path covers most of this end-to-end).

---

## Relationship to uapi

uapi 2.1.0 ships curated `unbound/srv` and `unbound/ext` singleton resources at `/api/v2/unbound/srv` and `/api/v2/unbound/ext`. They:
- mirror the UCI shape (same field names, same lists);
- enforce the same per-entry validation as the generator (no newline, max length, non-empty), but at PATCH time so the client gets a structured 422;
- use `reload: ["unbound-uci-ext"]` so uapi's transaction recipe drives the generator via `/etc/init.d/unbound-uci-ext reload` after the uci commit;
- return `503 init_script_missing` cleanly if this package is absent from the router (pre-flight check on `/etc/init.d/unbound-uci-ext`).

The two repos release independently. Operators install both from the openwrt-iac feed; one feed line covers them.

---

## Out of scope

- **Touching the main unbound UCI** (`/etc/config/unbound`). That is the main package's surface; we never reach across.
- **Curating `ext_line` into typed sub-clauses** (`forward_zone: [{name, addr}, ...]`). The verbatim list is the v1 contract; clause-aware curation comes later if a real case shows up.
- **Auto-detecting `interface_auto` conflict** (operator sets `interface_bind` while the main unbound UCI still has `interface_auto = 1`, so both bindings get emitted). Documented in the README; a cross-package validation would need a hook the main package does not expose.
- **Forking unbound or upstreaming individual options.** Either is more cost than this package.

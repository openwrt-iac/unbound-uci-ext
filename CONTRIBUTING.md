# Contributing to unbound-uci-ext

## What this is

A uci front end for the two unbound configuration fragments that OpenWrt's own package leaves as hand-edited files: `/etc/unbound/unbound_srv.conf` and `/etc/unbound/unbound_ext.conf`. It reads `config unbound_srv` and `config unbound_ext` sections and renders those files, so a config-management tool can drive them through uci instead of editing files in place.

It exists because [uapi](https://github.com/openwrt-iac/uapi) exposes `unbound/srv` and `unbound/ext` endpoints, and those write uci packages that nothing else renders. The two ship separately because unbound users who do not want an HTTP API should not have to install one.

## Dev loop

```sh
./tests/unit/generator_test.sh      # what CI runs
shellcheck files/usr/lib/unbound-uci-ext/generator.sh tests/unit/generator_test.sh
```

There is no `make test`: the Makefile is the OpenWrt package recipe and carries no phony targets, so the test script is invoked directly, exactly as CI does it. The generator is a shell script with no dependencies beyond busybox and uci, so a test is a fixture plus an expected rendering. Add one with any behaviour change, and keep shellcheck clean because CI gates on it.

## What kinds of changes are welcome

- Directives unbound supports that the generator cannot yet express.
- Rendering bugs, especially anything where a uci value could produce a file that `unbound-checkconf` rejects.
- Failure handling: this package's job is to render or to fail loudly, never to write a partial file that unbound then loads.

## Commit and PR style

One-line subject in the imperative, present tense. Explain in the body why the change is needed rather than restating what the diff does. Every change lands via a pull request.

## The managed block

The generator owns a delimited region of each file and leaves everything outside it alone, so an operator can keep hand-written directives beside generated ones. Changing those delimiters breaks existing installations silently, so treat them as a wire contract.

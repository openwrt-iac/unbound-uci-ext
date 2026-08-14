# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: **[Report a vulnerability](https://github.com/openwrt-iac/unbound-uci-ext/security/advisories/new)**.

Expect a first response within a week. That is a rough figure rather than an SLA. If a report goes unanswered, feel free to nudge it.

## What counts as a vulnerability here

This package reads uci and writes two files that unbound then loads, so the interesting boundary is what an operator can put into uci and what ends up in unbound's configuration.

- Content in a uci option escaping into a directive it was not meant to be, for example a value that terminates one clause and opens another.
- Anything letting a caller who can only write uci reach outside unbound's configuration: a path traversal in a generated filename, a symlink followed on write, or a shell metacharacter reaching a command.
- The generator or init script running with more privilege than it needs, or leaving a world-writable file behind.

## Out of scope

- An operator with root on the router configuring unbound badly. This package renders what uci says; it is not a validator for unbound's grammar, and `unbound-checkconf` is what catches a bad clause.
- Vulnerabilities in unbound itself. Report those upstream.
- Anything requiring write access to `/etc/config/` or `/usr/lib/unbound-uci-ext/` already, which is root on the box.

## Supported versions

The current release only. This package is small and fixes ship as a new version rather than as backports.

# 0025: No git hooks

**Status:** accepted, 2026-09-29. Supersedes the pre-push hook line in
[0006](0006-licence.md) (the rest of 0006 stands).

## Decision

- **The repository carries no git hooks.** `.githooks/pre-push` is removed,
  and no clone sets `core.hooksPath`.
- **The checks it made stay in CI.** `.github/workflows/checks.yml` fails a
  push whose `LICENSE-EXCEPTION.md` is not adopted, and runs the name gate
  (`pp test --quick`). `pp test` runs the name gate on the workstation.

## Why

The hook had to be enabled per clone, so it was never a guarantee, and CI
already repeated both of its checks.

## Cost

A push that fails either check reaches the remote before CI reports it. The
exception is already adopted, so only the name gate can still fail that way:
run `pp test` (or `pp names`) before pushing.

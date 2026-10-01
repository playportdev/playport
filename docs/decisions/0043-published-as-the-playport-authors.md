# 0043: Published as "The Playport authors", from a fresh repository

**Status:** accepted, 2026-10-01, by the copyright holder.

## Decision

- **Name.** Playport's own copyright lines, patch authors, licence exception and
  release metadata name **The Playport authors**, with the address
  **dev@playport.dev**. No personal name is published. Upstream authors' notices
  are untouched.
- **Bundle ID.** `dev.playport.app` (the extension `dev.playport.app.PlayportJIT`;
  the Keychain services `dev.playport.app.jit` and `dev.playport.app.steamclient`),
  replacing an ID that named a person. The phone gets a new app and container once:
  the Wine prefix, the Steam session, the pairing and the installed titles start
  over, and the old app is removed by hand when the new one plays.
- **Repository.** The public repository is a new one under a new GitHub account,
  holding one squashed commit of a reviewed tree (`pp names` and `pp secrets`
  clean) with `upstream/madeira` as its submodule. No old history, pull-request
  ref, branch or Actions run is published, so the history rewrite of 0039
  (`tools/publication_rewrite.py`) and its triage are no longer needed and are
  removed. The current repository stays private.
- **Website.** playport.dev.
- **Order.** Source first; the 0.1.0 IPA release follows as a separate step.

## Consequences

- Replaces 0039's "History" item. 0039's other readings stand.
- `pp secrets` fails a tracked file holding a word from the build area's `private-words`
  (the person's name and addresses, one per line), so the repository never names them.
- Pseudonymity is only as good as what goes in afterwards: a commit, a log or an
  evidence file that names the person, a donation processor that shows a legal
  name, or a domain registration without privacy undoes it.

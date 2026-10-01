# Open-source publication, then the 0.1.0 IPA

**Status:** the licensing work is done; what is left is the phone check, the
publication itself, then the IPA release. The target is the current GPL edition.
Keep `LICENSE`, `LICENSE-EXCEPTION.md`, upstream notices and source headers intact.

## Done

- **Notices.** `pp notices` collects them; the app carries the reviewed selection as
  `Licenses/` in both variants, shown at Settings › About › Licences; `pp verify
  --distribution` checks it (decision 0039, [evidence](../evidence/2026-10-01-licences-ui.md)).
- **Corresponding Source.** `pp source` packs a build's exact sources: Playport,
  Madeira, every pin with its submodules, the series, the LLVM and Rust tarballs,
  Cerbero with GStreamer's 17 source archives, idevice's crates, StikJIT, Wine's
  generated `config.h`. It is complete (decision 0042); relinking is rebuilding
  from it (decision 0041).
- **Licensing readings and risks** settled by the owner: decisions 0039 to 0042.
- **Identity.** Published as "The Playport authors" <dev@playport.dev>, bundle ID
  `dev.playport.app`, from one squashed commit in a new repository (decision 0043).
- **Release tooling.** `pp build --unsigned`, `pp verify --unsigned`, `pp release
  VERSION` (a GitHub draft, never published by the tool; decision 0038). CI uploads
  nothing.

## Gate A: publish the source (now)

1. **Workstation, after merging this branch to `main`:** `./pp install`, then
   `./pp ui --play app-367520 --until first-frame+10`. The new bundle ID installs
   as a new app with a new container: pair the phone again for JIT, sign in to
   Steam and install Hollow Knight (`pp ui --action install:367520`) before the
   play. When it plays, delete the old app by hand. Commit the build records the
   build rewrites (the patch headers changed).
2. **The owner:** create the GitHub organisation `playportdev` (owned by a
   pseudonymous account) and an empty public repository `playport`; mail for
   dev@playport.dev; WHOIS privacy on playport.dev; point the domain at GitHub
   Pages and add `site/CNAME` with `playport.dev`.
3. **Squash and push** (from a clean clone of `main`, in `$PLAYPORT_BUILD`):

   ```sh
   git checkout --orphan public main
   ./pp names && ./pp secrets             # with .work/private-words in place
   TZ=UTC GIT_AUTHOR_DATE=now GIT_COMMITTER_DATE=now \
     git -c user.name='The Playport authors' -c user.email=dev@playport.dev \
     commit -m 'Playport'
   git push git@github.com:playportdev/playport.git public:main
   ```

   The private repository stays private.
   Later work happens in the public repository; nothing from the old history goes
   there.

## Gate B: the 0.1.0 IPA (after Gate A)

1. `pp release 0.1.0` on a clean, pushed HEAD of the public repository: the
   unsigned release IPA, `Playport-0.1.0-source.tar`, `NOTICES.tar`,
   `INSTALL-REBUILD.tar` and checksums, in a GitHub draft.
2. Check the draft: `python3 tools/source_payload_audit.py` on the source tar
   (no private data, game content or stray binaries), and LLVM's tarball against
   its detached signature.
3. Install the draft's IPA with a re-signing tool on the phone and play Hollow
   Knight, with the JIT helper extension under the re-signed App ID.
4. The owner publishes the draft by hand.

Not for 0.1.0: a donation page (decision 0039). When one comes, read the
processor's terms for what it shows of the recipient's name (decision 0043).

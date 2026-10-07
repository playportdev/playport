# PLA-50: native authentication backend investigation

**Date:** 2026-10-07–08. **Status:** investigation/probe, not a runtime fix.

The owner selected the full PLA-50 port (NTLM, Negotiate and Kerberos), not
package enumeration alone. No tested title is known to require these packages;
Schannel and the store sign-ins already work without them.

## Source findings

The pinned Wine source, with Playport's series applied:

- `dlls/secur32/secur32.c` initialises Schannel before asking lsass for the
  other packages. `dlls/secur32/lsa.c` routes credential and context operations,
  not just enumeration, through the lsass RPC interface.
- `programs/lsass/lsass.c` owns the package dispatcher and the built-in
  Negotiate provider. An in-process port must preserve the package IDs,
  client-buffer ownership and the LSA/user-mode context mapping.
- `dlls/msv1_0/unixlib.c` starts `ntlm_auth` with `posix_spawnp` and exchanges
  messages over pipes. Registering NTLM without replacing that backend does
  not provide remote authentication on iOS.
- `dlls/kerberos/unixlib.c` loads libkrb5 and GSSAPI libraries. They are not
  among Playport's statically linked unix libraries.

The iOS SDK exposes a GSS framework with password-based credential acquisition
and an SSPI session-key inquiry. It is a candidate, not yet the chosen runtime
backend. Its IOV wrap/unwrap exports use private symbol names, unlike Wine's
expected GSS symbols.

Apple's published Heimdal implementation at
`1635de38a813f6e1dd3f8fd270683187ad4f02be` stores an NT hash in the
system credential service during NTLM password acquisition
(`lib/gssapi/ntlm/acquire_cred.c`, `_gss_ntlm_acquire_cred_ext`). A release of the credential is not a deletion:
`gss_destroy_cred` is needed. Cleanup on orderly exit alone does not cover an
app crash. The full-port request alone did not authorise that residual. After the
phone probe the owner explicitly selected **“Native GSS; accept OS cache”**,
recorded in [0065](../decisions/0065-native-sspi.md). Product integration must
still forbid default phone credentials and record/destroy only credentials
created by this bridge. Crash retention is an accepted residual, not a guarantee
cleanup can eliminate. This does not alter the store-session boundary.

Reference source copies and SDK-header inspections stay under `.work/pla50/`.

## Probe

Settings → Developer → Probes has a dev-only **Native authentication** probe;
`pp ui --action probe:native-auth` invokes the same operation. It uses only a
synthetic identity/password and a locally constructed NTLM type-2 challenge,
never the owner's store sessions or default GSS credentials. It reports
mechanism availability, status codes, token types and session-key length, never
credential, token or key contents. Any credential it acquires is destroyed.

Even a successful type-3 token would prove token creation only, not server-side
password validation, Negotiate, Kerberos, or a working Wine SSPI path.

Host fault-injection tests compile the exact probe C with a mock GSS interface.
They cover every failing acquisition/token/key step, cleanup, deletion failure,
a one-byte report buffer and redaction. The UI-action parser accepts only the
exact action, and the app's release dependency graph omits the probe target.

`python3 -m unittest tools.tests.test_native_auth_probe tools.tests.test_ui`
passes all 20 tests. `pp check` compiles and links the dev app successfully.
`pp test --quick` also passes, including the name/secret/pin/patch gates and
host C tests. The dev IPA build passes all 80 verification checks.

## Phone, 2026-10-08

- Dev IPA: `c28c84224634b506e0cbaeb11d13ffba9f4581b10f459834a45fb21de688cab1`.
- UI run: `.work/ui-runs/20261008T000749`, action `probe:native-auth`, result OK.
- Host log: `native-auth: stage=ok major=00000000 minor=00000000 ntlm=1 kerberos=1 type1=1 type3=3 key-bytes=16`.
- The synthetic credential's destroy call returned success (otherwise the probe
  reports the deletion error and fails). No post-deletion cache query or
  crash-retention check was performed.
- The first screenshot showed Settings' Developer page without scrolling to
  the probe. In `.work/ui-runs/20261008T001147`, the controller entered Developer,
  moved to `set:dev:nativeAuth` and pressed A. The same native-auth result passed;
  `screen-stop.png` shows the ringed **Native authentication** row and its success
  status. Screenshots remain in the run directory.

No game was played, no store was signed out, no real password was used, and no
Kerberos credential acquisition or server-side NTLM validation was attempted.
PLA-50 remains open. The static Kerberos candidate is scratch-only: MIT
`krb5-1.22.1.tar.gz`, sha256
`1a8832b8cad923ebbf1394f67e2efcf41e3a49f460285a66e35adec8fa0053af`;
no pin, library, runtime patch or licensing record for it is shipped. Static
candidate evaluation stopped after the owner's native-backend choice. The first
cross-configure stopped at its constructor/destructor run-test requirement;
this is not evidence that Kerberos cannot be ported to iOS.

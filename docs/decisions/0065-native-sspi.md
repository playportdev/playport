# 0065: Native iOS GSS backs a game's Windows authentication

**Status:** accepted, 2026-10-08, by the owner: **“Native GSS; accept OS
cache”**, after the native NTLM phone probe. This selects the backend for the
full NTLM/Negotiate/Kerberos port in PLA-50; the runtime implementation and its
authentication gates are not completed by this record.

## Context

Wine's Schannel works, but `secur32` gets its other packages and credential/context
operations from lsass over RPC. The one-process runtime has no service manager.
Wine's NTLM backend also starts an external `ntlm_auth` process, which iOS cannot
run, while its Kerberos backend needs libkrb5 and GSSAPI libraries not linked here.

The dev Settings probe on IPA `c28c8422` shows iOS's GSS framework can create
synthetic NTLM type-1/type-3 tokens and return a 16-byte SSPI session key. It also
advertises Kerberos. This is evidence for a candidate backend, not a server-checked
login or a working Wine path. [Evidence](../evidence/2026-10-07-native-auth-backend.md).

## Decision and required boundaries

- Port Wine's LSA package dispatch into the guest process. There is no service
  manager, lsass child, RPC listener or external authentication helper to start.
- Use native iOS GSS for NTLM and Kerberos; Wine's Negotiate provider remains the
  Windows-facing selector. Schannel keeps its existing backend.
- **No default phone credentials.** Native acquisition requires credentials
  supplied by the guest, or a credential this play explicitly created. A missing
  identity/password is not permission to query the phone's SSO or system cache.
  Acceptor paths must not silently request default phone service credentials.
- Native context, credential and session-key objects stay on the native side;
  only Windows SSPI results go to the guest. The guest already owns the Windows
  credentials it supplied. Host Steam/GOG/Epic sessions are not an input to this
  bridge; [0004](0004-steam-session-boundary.md) and its store exceptions do not change.
- Record only identifiers of credentials created by this bridge, in private
  host storage. Destroy those credentials on orderly cleanup and retry recorded
  cleanup at the next app start. Never enumerate or delete unrelated phone
  credentials. Cleanup failures stay recorded and are reported without identifiers.
  Failure to record a new credential must fail acquisition and attempt its deletion.
- Logs contain status, package/type and lengths only: no passwords, NT hashes,
  tokens, exported contexts, session keys or credential identifiers.

## Accepted residual

**The owner explicitly accepts native OS credential storage.** Apple's NTLM
password-acquisition implementation stores an NT hash in the OS credential
service. It is password-equivalent, and `gss_release_cred` alone does not delete
it. A game-created hash can survive an app crash until cleanup. The native
Kerberos path can also retain game-created credentials/tickets in OS storage;
they belong to this same native-backend residual, not to a host store session.

The ledger and `gss_destroy_cred` are cleanup mitigations, not an atomic guarantee:
a crash during acquisition/before its identifier is recorded, a failed deletion,
or changed platform behavior can leave a credential outside the app's container.
No claim of crash-proof removal is made. This does not authorise use of the
phone's pre-existing credentials.

## Implementation limits and gates

Selecting native GSS does not assert every Windows authentication operation is
supported by it. No domain join, phone-wide SSO, default acceptor identity or
account-management UI is added. Unsupported roles/operations must fail honestly,
not return synthetic authentication success. Native APIs and any required private
GSS IOV symbols must be checked against the actual SDK/device, with their platform
compatibility risk documented in the implementation evidence.

PLA-50 stays open until the Windows-facing packages and dispatch run without SCM,
NTLM authentication is checked independently (including tamper/failure cases),
Kerberos is checked against a controlled KDC, and relevant phone regressions pass.
Enumeration or the existing native token-generation probe alone does not close it.

## Alternative rejected by the owner

Statically port and ship Kerberos/NTLM libraries to keep credentials entirely in
Playport's process. This avoids OS caching but adds dependency, crypto/Unicode
port, build and licensing work. Scratch evaluation is not shipped, and no component
pin moves as part of this backend decision.

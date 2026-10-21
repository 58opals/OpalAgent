# Proposed deployment dossier

Status: proposed macOS 27 distribution and custody design, with an internal source/synthetic durable BCH engine. Native adapter source is present; no launch-agent property list, entitlement file, provisioning profile, installer or qualified production composition is delivered by the package. Neither shipping executable registers, installs, opens live Keychain/storage or starts a wallet runtime. No signed-service or distribution proof is claimed.

## Artifact inventory

The proposed distribution embeds the matching service and stdio bridge in `Wallet.app`:

```text
Wallet.app/
  Contents/
    MacOS/
      Wallet
      AgentBridge
    Library/
      Helpers/
        OpalAgentService.app/
          Contents/
            Info.plist
            MacOS/AgentService
            embedded.provisionprofile
      LaunchAgents/
        com.58opals.OpalAgent.Service.plist
```

This is an inventory proposal, not a generated or installed bundle. Final signatures, signature resources and dependencies must be inspected from the actual packaged artifacts. `StoreLockProbe`, test executables and their fixtures are explicitly excluded. The internal core is linked into the service; it is not a separately installed library or adapter entry point.

| Artifact | Proposed identity and responsibility |
| --- | --- |
| Wallet app | Existing application identity; trusted owner-control deputy, separate Apple integration host and registration owner. |
| `OpalAgentService.app` / `AgentService` | Bundle/signing identifier `com.58opals.OpalAgent.Service`; app-like, profile-bearing per-user service helper. |
| `AgentBridge` | Signing identifier `com.58opals.OpalAgent.MCP`; signed stdio executable with no service Keychain entitlement. |
| LaunchAgent property list | Name and proposed label `com.58opals.OpalAgent.Service`; resolves the embedded service executable relative to Wallet's bundle. |

Service and bridge identities are distinct from Wallet and each other. The standalone bridge's signing identifier is not an additional installed app bundle. The final Team identifier, provisioning prefix, certificate provenance and evaluated designated requirements remain to be established from signed artifacts; this document supplies no fabricated values.

The service helper's app-like structure provides a location for its own provisioning profile. Apple's [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) requires user-login context for the Data Protection Keychain and provisioned access-group entitlements in an app-like bundle. Apple's [restricted-entitlement packaging guidance](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement) explains profile-bearing wrappers. Neither source proves this particular helper composition.

## Registration and availability

The proposed Wallet integration calls [`SMAppService.agent(plistName:)`](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)) for the property list in its `Contents/Library/LaunchAgents` directory. It uses the `BundleProgram` key to reference `Contents/Library/Helpers/OpalAgentService.app/Contents/MacOS/AgentService`. This relative-path support and the update requirements below are documented in the macOS 27 SDK's `SMAppService.h`. The exact plist, Mach-service names, sandbox communication entitlements and launch behavior still require signed composition proof.

[`register()`](https://developer.apple.com/documentation/servicemanagement/smappservice/register()) is subject to user approval; for a LaunchAgent it bootstraps the service and arranges subsequent-login bootstrap. Registration is per user. Report actual registration/approval state and connection errors instead of assuming the helper is active.

Target unattended behavior is operation while the user is logged in and the Mac is awake, including screen lock and Wallet termination. This has not been tested. Logout, sleep, unavailable keys and network outages can stop progress. No root daemon, keep-awake mechanism or alternate transport is selected as a fallback.

## Keychain and storage boundary

Only the service receives the proposed service-specific Data Protection Keychain access group. Resolve its exact prefix and authorization from the final service profile. Do not add Wallet, bridge or personal-wallet access groups to it, or grant the service access to personal Wallet groups. Apple's [keychain access-group documentation](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) explains entitlement-based membership; application ownership still requires inspection of the actual signatures and profiles.

| Service-only item | Proposed protection and purpose |
| --- | --- |
| `com.58opals.OpalAgent.wrapkey`, scoped by wallet identity | Independent seed-wrapping key; Data Protection Keychain, non-synchronizing, `AfterFirstUnlockThisDeviceOnly`, no interactive user-presence requirement. |
| `com.58opals.OpalAgent.continuityanchor`, scoped by installation/wallet identity | Independent committed/pending complete-state commitments and recovery latch; same service-only, device-bound accessibility policy, separate from the wrapping key. |

Explicitly select [`kSecUseDataProtectionKeychain = true`](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain) for the production item's operations. Do not rely on macOS's default file-based backend or enable iCloud synchronization. [`AfterFirstUnlockThisDeviceOnly`](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly) permits access after the first user unlock following restart until the next restart and does not migrate the item to another device. These API contracts do not establish this service's locked-screen behavior.

Internal `KeychainWrappingKeySource` and `KeychainContinuityAnchorStore` source supplies exact-scope wrapping-key reads and complete-anchor reads/writes through `KeychainItemOperations`. The native Security implementation is separate from injected test operations. Shipping startup does not construct these adapters, and no qualified custody provider is supplied. An exact access group must be configured explicitly; its production prefix and authorization still require final signed-artifact inspection. An explicit internal `KeychainNewWalletCreation` composition supplies owner-authorized add-only provisioning for a new wallet, using the same exact group and item protection. It is not selected by shipping startup. Rotation, deletion and migration are absent.

New-wallet composition must retain a service-owned installation/wallet scope across attempts and restarts and hold the existing exclusive local database-writer lease. It checks absent database, anchor and key, prepares the seed/account without key effects, revalidates owner consent and rechecks fresh storage under the coordinator lock. An acknowledged initial marker write and exact independent read-back precede key creation; a failed/ambiguous initial write stops before key effects even if a marker was retained. Add must report success and an exact-scope read-back must match the generated 32 bytes before encryption uses the stored key. Duplicate/ambiguous add, missing/wrong/inaccessible read-back and later initialization failures preserve evidence and refuse automatic reinitialization; no cleanup, replacement or alternate namespace is attempted. The resulting wallet remains restricted with no integration grants. The internal durable composition persists and reopens that scope as described below. Final trusted-root selection, real entropy/storage behavior and crash durability remain native deployment proof, not results supplied by synthetic tests.

`DurableWalletStore.initializeNew` requires a genuinely new service-selected directory and retains any interrupted prefix. Its nonsecret `custody.scope` locator contains a version header and the installation/wallet UUIDs only. `reopen` requires the existing root, regular lock inode, valid locator and existing SQLite schema; missing or inconsistent evidence never selects fresh initialization, another namespace or a replacement key. Exact canonical-state and independent-anchor verification, existing-key availability and startup invalidation precede integration access. A reopened bound owner endpoint cannot create another wallet. The store owns one writer/coordinator, and escaped facades/services/engines retain its lease.

The selected root must come from trusted service composition, not a request. The locator supplies no authority: it detects inconsistency only through independent custody checks. Coherent substitution of an entire genuine wallet directory with an available matching anchor is not authenticated by this metadata. Same-inode advisory exclusion does not fence directory/lock replacement, another device or copied seeds. No trusted Keychain index, discovery, migration or automatic repair is added. File synchronization and temporary-filesystem restart tests cannot qualify power-loss durability, protected custody, IPC, lifecycle or installed distribution.

Treat `errSecItemNotFound` as no match for the exact query, not proof of physical key loss or valid entitlement membership. [Apple documents](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) that a search using an access group outside the caller's membership can also return that status. Inaccessibility and malformed results fail closed without creating a key or clearing the anchor. Requests use fresh noninteractive authentication contexts; optional returned access-control objects remain opaque, and their type cannot prove the absence of user-presence constraints. Request/result and encoding tests with injected operations cannot prove actual Keychain accessibility, atomicity, durability or access-group isolation.

The service alone opens its dedicated application storage. Supported database/journal backups exclude the independent anchor and wrapping key. The seed payload uses standard AES-GCM authenticated encryption; both save and restore validate encrypted protection metadata and bound identity/format context. Reject plaintext and downgrade paths. Missing key with existing ciphertext requires recovery; temporary inaccessibility must not be treated as missing or trigger regeneration. Successful decryption does not establish continuity.

The proposed Apple integration credential is a separate device-local item owned by the Wallet host, with exact storage identity and access still requiring signed qualification. It is not the service wrapping key or continuity anchor and grants no membership in their access group. No live Apple credential provider or weaker storage fallback is delivered here.

Owner controls and bridge have no direct database/key access and no storage fallback when the service is unavailable. Signing authority lives in the service; an application payment-approval policy does not isolate secrets from a compromised service.

## Reciprocal peer verification

Every production native connection must set the expected peer requirement before exposure/resume. [`NSXPCConnection.setCodeSigningRequirement(_:)`](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)) is available from macOS 13. A mismatching peer invalidates the connection; a malformed requirement is fatal in Swift, so validate configuration before distribution. The macOS 27 SDK's `NSXPCConnection.h` confirms the connection-level API and the listener delegate's accepted-connection configuration path.

[`NSXPCListener.setConnectionCodeSigningRequirement(_:)`](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:)) can additionally enforce incoming-peer requirements. The macOS 27 header limits it to anonymous or Mach-service listeners and specifies automatic rejection before the delegate on mismatch; other listener types assert. Role-specific listener/interface configuration must preserve the separate owner and integration authority below.

| Verifier | Expected peer and additional authority |
| --- | --- |
| Wallet owner client | Exact approved service designated code requirement and compatible protocol. |
| Stdio bridge client | Exact approved service designated code requirement and compatible protocol. |
| Wallet Apple integration client | Exact approved service designated code requirement and compatible protocol; fixed enrolled Apple credential binding. |
| Service owner interface | Exact approved Wallet designated code requirement, correct user context and required trusted owner-authentication flow. |
| Service MCP integration interface | Exact approved bridge designated code requirement, then service verification of its supplied MCP-profile credential. |
| Service Apple integration interface | Exact approved Wallet designated code requirement, then its separate Apple-profile credential; integration selectors only. |

Record and evaluate the exact requirements of the final signed executables, including the approved signing identifier and Team/certificate provenance. Do not substitute a Team-only expression, executable path, label, same-user process or launcher metadata. Apple's [code requirement language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html) distinguishes identifier and certificate constraints; the proposed allowlist is a product requirement, not a current signed artifact.

Owner, MCP integration and Apple integration interfaces remain separate. The optional Apple Mach service must differ from both existing services and shares their single authority/writer; absence leaves it unavailable. The source allowlist and profile checks supply no actual signed-endpoint qualification. Wallet performs required fresh human authentication as the trusted owner deputy; its signature alone supplies no consent. A signed bridge still needs a current credential and scope, and a stolen credential used through an allowed bridge remains a same-user threat. No host-process attestation is claimed.

## Installation, update and removal duties

These are future product duties; the package currently performs none of them.

| Operation | Required behavior |
| --- | --- |
| Installation / first enablement | Verify exact artifact inventory, signatures, entitlements, profiles, peer requirements and version compatibility. Obtain service approval, initialize only an explicitly chosen new wallet, and prove custody prerequisites before funding or autonomous enablement. Enrollment is a separate owner decision. |
| Update | Quiesce new work without discarding admitted or uncertain operations. Preserve exact bytes, request identities/tombstones, grants/revocations, recovery generation and every liability. Validate compatibility and a recoverable migration before accepting commands. Re-register when plist or executable changes; the SDK recommends unregistering before re-registering an executable change. Account for termination during unregister. |
| Disable / revoke | Distinguish disabling wallet authority, revoking an integration and ending a transport. Persist the chosen decision and retain operation history, liabilities and recovery evidence. UI closure alone does not revoke a grant. |
| Uninstall / removal | Stop new admissions and unregister the service through Wallet's owner flow. [`unregister()`](https://developer.apple.com/documentation/servicemanagement/smappservice/unregister()) terminates a running LaunchAgent; it does not prove pending work was never handed off. Preserve custody and recovery records unless the owner separately authorizes a designed retirement/deletion procedure. |

No update, failed launch, uninstall or recovery path may silently clear storage, regenerate a key over encrypted funds, reset request identities or discard possible liabilities. There is no destructive automatic cleanup or removal command in the current implementation. Keep service/bridge protocol compatibility separate from MCP protocol and future engine API compatibility.

## Restoration and migration limits

These are supported design outcomes to prove, not currently available restoration tools.

| Situation | Proposed outcome and limit |
| --- | --- |
| Intact restart with matching store and clean independent anchor | Recover retained facts and liability gates before clients. Preserve valid grants; invalidate unsubmitted process-local preparations. |
| Interrupted staged update | Quarantine. Owner recovery latches a stable new generation and selects only recomputed complete contents matching independently endorsed committed/pending evidence. Enter restricted mode, disable copied authority and preserve all liabilities. |
| Older database backup after payment or revocation | Reject continuity mismatch. Public transaction evidence cannot prove that omitted requests or relays never existed. Require complete independently matching coverage. |
| Seed-only restore, lost journal or missing independent anchor | May recover keys and public funds under the documented derivation/discovery profile; cannot reconstruct unknown signed bytes, request bindings, revocations or complete liabilities. Remain restricted/history-incomplete without same-seed autonomous resumption. |
| Later complete matching archive | May establish original coverage through owner recovery against retained independent proof references. A current incomplete-store digest alone cannot. |
| Device migration or copied files | Device-only key/anchor do not migrate. New-device files are insufficient; retire the old signing instance and use a separately designed recovery/transfer procedure. If the old instance may still sign, autonomous same-seed migration is unsupported. |

The local lock excludes writers of one local store only. No cross-device clone fence, whole-device/Keychain rollback detector, administrator-resistant clock or protection from another seed holder is claimed. No portable encrypted seed-export format is selected. The proposed funds-discovery profile is BIP39 with an empty passphrase and BCH BIP44 account zero on an explicit network; bounded receive/change source integration and retained issuance are implemented with synthetic qualification; live provider/distribution proof remains required. Seed backup and operational-journal backup serve different purposes.

## Proof matrix and release gate

| Claim | Source / synthetic qualification | Signed runtime qualification | Distribution qualification |
| --- | --- | --- | --- |
| Module isolation and fail-closed entry points | Manifest/import/link review, external-scratch build and deterministic tests; development fixture excluded | Inspect final linked artifacts | Confirm only shipping artifacts are embedded; exclude probe/tests. |
| Principal/scope/session decisions | Injected peer/credential, strict native frame and policy cases; compiled XPC requirement setup | Real reciprocal XPC identity rejection, owner authentication and connection binding | Exact designated requirements, certificate/Team provenance and compatibility. |
| Encrypted seed boundary | Synthetic payload, protection-mode and corruption cases | Service-only Keychain access; denial from Wallet/bridge; first unlock, lock, restart and missing/unavailable key behavior | Evaluated service entitlements and provisioning profile; no personal groups or weak fallback. |
| Continuity and recovery | Injected complete-state, staging, promotion and recovery-latch failures | Actual Keychain/database crash and ambiguous-write durability; restart recovery | Supported backup, update and migration behavior with retained liabilities. |
| Single local writer | Competing development-probe processes | Installed helper contention and lifecycle | Launch/update/removal ownership with the same store identity. |
| Wallet-closed unattended operation | Design only | Logged-in/awake, locked-screen, UI-closed, sleep/wake and logout behavior | Registration approval, installation, update and removal. |
| Mac Apple automation | Package compilation and actual extracted intent/entity/query metadata; synthetic adapter guards and actual-service scoped replay/authentication. Wallet owns its host, local request storage and owner routes. | Actual signed main-app integration, independent query privacy, revocation/reconnect and owner-review handoff; App Intents system invocation separately. | Qualified host credential storage, package discovery, supported Shortcuts/Spotlight/Siri behavior and matching release artifacts. |
| Wallet/MCP functionality | Actual BCH/SQLite fixture, strict MCP adapter and SDK-client wire scenarios; ordinary wallet channel unavailable | Real signed owner/service clients, installed engine and host interoperability through qualified native IPC | End-to-end supported release acceptance. |

Current evidence is source and synthetic only. The matrix's signed-runtime and distribution columns remain pending; a package build or synthetic role cannot satisfy them. Apple documentation supplies prerequisites, not proof of their composition. Distribution qualification requires suitable Developer Program provisioning and remains pending. Do not weaken entitlements, use ad-hoc identity as equivalent proof, switch Keychain backends or add a transport fallback to bypass that gate. The product is not ready for funding or production autonomy.

## Apple reference basis

Official documentation was retrieved on 2026-10-17, the native-connection references rechecked on 2026-10-18 and the Keychain backend, accessibility and access-group contracts rechecked on 2026-10-20; pages are current, unversioned publications rather than immutable SDK snapshots. API-specific metadata reports macOS 13 availability for `SMAppService.agent(plistName:)`, `register()`, `unregister()`, `NSXPCConnection.setCodeSigningRequirement(_:)` and `NSXPCListener.setConnectionCodeSigningRequirement(_:)`; metadata reports macOS 10.15 for `kSecUseDataProtectionKeychain` and `AES.GCM`. The installed macOS 27 SDK headers confirm the cited ServiceManagement and NSXPC declarations. Native XPC source compiles against the macOS 27 declarations and has synthetic frame/connection-policy coverage. No evaluated signature, live Keychain or installed-service evidence follows from compilation or reference inspection.

## Source boundary versus native proof

The shared native target and separate client/service endpoints are compileable source boundaries. Exact requirement values must come from the accepted final artifact policy; no Team ID, team-wide wildcard, role flag or fabricated production identity is selected by this package. A required trusted deployment provider must qualify signing, custody and lifecycle prerequisites before connection construction. No production implementation of that provider is supplied. Ordinary callers therefore receive unavailable rather than a socket, plaintext or permissive transport fallback.

Source and synthetic tests can establish strict frame decoding, safe error mapping, no-secret handshake ordering, channel separation and the service's final context checks. They cannot establish that macOS rejects an actual wrong signature, that entitlements permit this composition or that the helper survives UI termination, screen lock or restart. The signed-runtime and distribution matrix remains the release gate. [MCP](MCP.md) separately describes protocol profiles and development fixture limits.

# OpalAgent

OpalAgent is a dedicated Bitcoin Cash wallet service and local MCP bridge for macOS. The service owns its seed, accounts, policy, credentials and operation history independently of personal Wallet funds. Wallet supplies the proposed owner controls and distribution bundle.

The internal durable BCH engine includes encrypted fixed-profile seed recovery, an actual SQLite journal, scoped authorization, bounded receive allocation, synchronization, exact-payment approval, immutable transaction submission and restricted recovery. External keys, continuity anchors, peer authentication, chain views and transport are injected. `AgentBridge` serves the twelve strict MCP tool shapes through the official Swift SDK; ordinary construction returns unavailable for wallet operations because no qualified native deployment/custody provider exists. `AgentService` still reports unavailable. Neither entry installs a service, opens live Keychain items or starts a live wallet runtime. A separate Debug-only development fixture composes the actual engine with disposable injected boundaries for protocol qualification.

Internal service Keychain adapter source reads existing 256-bit wrapping keys and complete continuity anchors through injectable Security operations. An explicit owner-authorized new-wallet composition can add and verify one new wrapping key, then initialize restricted custody without grants. It rejects existing or ambiguous evidence and never provisions during startup or recovery. `DurableWalletStore` provides distinct explicit fresh initialization and same-store reopening over one SQLite writer lease. A nonsecret scope locator only selects the exact independently anchored custody; reopening never creates storage or provisions a key. Shipping startup does not construct these adapters. Rotation, deletion and migration remain absent.

An internal `ServiceAssembly` now connects the strict store, owner controls, capability dispatch and distinct endpoint roles under one terminal lifecycle. A trusted asynchronous factory builds the existing Base adapter against that same owned custody/coordinator. Cached readiness remains an explicit host input with an unavailable default. Startup admission waits for the complete endpoint set; fresh wallets remain owner-only until creation, enablement and enrollment succeed. Shutdown retires runtime handles and drains admitted calls plus retained effect work before releasing the writer. A reopened assembly preserves durable identity and rejects prior runtime handles. Synthetic lifecycle tests use injected endpoint hosts; shipping service startup remains unavailable and no native deployment qualification follows.

## Package

Requires macOS 27.0, Xcode 27 and Swift 6.4. The products are:

| Product | Purpose |
| --- | --- |
| `AgentValues` | Public transport values with no engine, storage or protocol dependency. |
| `AgentClient` | Public injected clients and unavailable-by-default native transport construction; no engine/storage dependency. |
| `AgentAppIntents` | Mac-only Apple action/entity/query adapters over the public client and values; host dependencies must be explicitly registered. |
| `AgentService` | Intended shipping service entry; linked to the internal core, currently unavailable. |
| `AgentBridge` | Shipping stdio adapter; discovery works, wallet calls require a qualified authenticated service channel. |
| `StoreLockProbe` | Development-only competing-process lock probe; excluded from distribution. |
| `AgentProtocolFixture` | Debug-only disposable engine/MCP composition; excluded from distribution and unavailable in Release. |

`AgentServiceCore` is an internal target with no library product. It uses the public `OpalBaseCore` ordinary-BCH product and system SQLite through `CSQLite`. Client and bridge cannot import the engine through a public product. `AgentAppIntents` imports only the public client/values and Apple frameworks, with no engine, Base, SQLite or MCP SDK dependency. `AgentMCP` owns the official MCP SDK dependency; the public values/client and native wire targets have no SDK, Base or SQLite dependency. The bridge does not link the engine or privacy integrations.

The package pins public OpalBase revision `efcb644de6dc2f0cbcca6c805367dfadb42d251e`, which provides `OpalBaseCore`. The official Swift MCP SDK is pinned to exact version `0.12.1` (revision `a0ae212ebf6eab5f754c3129608bc5557637e605`). Agent-owned observations use public OpalDiagnostics revision `97dfa7674ea3a25147a025b9c66fd65bff74fb0e`, already shared by the foundation packages. The direct `develop` requirement matches their compatible requirement; the root `Package.resolved` retains the exact canonical public dependency graph.

## Build and test

Run from the package root using an absolute scratch directory outside the source tree:

```sh
swift package --scratch-path "<external-directory>" dump-package
swift package --scratch-path "<external-directory>" describe
swift build --scratch-path "<external-directory>"
swift test --no-parallel --scratch-path "<external-directory>"
```

Process tests discover the exact `AgentProtocolFixture` executable beside the loaded package test bundle. An optional explicit executable binding requires both `OPAL_AGENT_PROTOCOL_FIXTURE_EXECUTABLE` and its matching `OPAL_AGENT_PROTOCOL_FIXTURE_SHA256`; partial or mismatching bindings fail before launch. No fixture environment configuration is required for the command above. Normal fixture construction remains fresh-only; process tests resume only their own capability-bound disposable namespace. The Debug fixture routes its twelve MCP tools through actual `ServiceAssembly` handlers and current authenticated connections. Owner creation, enablement and enrollment use its separate owner boundary; the owned effect factory binds the real Base adapter to that same store and custody.

Deterministic tests use published, permanently disposable vectors, actual SQLite and injected Security-style item, chain, relay and endpoint-host boundaries. They include process termination around SQL commits, concurrency, restart, stale evidence and recovery. The assembly process scenarios retain receive replay, unsubmitted invalidation and exact ambiguous payment identity/bytes/liability through death and bounded retry exhaustion. Controlled graceful stop proves admission closure and retained writer ownership until explicit fixture relay release and actual drainage. Local SDK disconnect is not server-observed stdin EOF; the fixture separately closes assembly admission on observed EOF before the SDK joins handlers. Explicit owner-only recovery fixtures retain their distinct storage/recovery proof. Real Base integration exercises derivation, transaction construction and public reservation/submission APIs. These checks do not qualify a live Keychain anchor, real XPC signatures, an installed helper, remote chain completeness or installed-service interoperability. The protocol fixture supports the documented November actual-SDK-client and limited June actual-host synthetic wire acceptance. Both exercise all twelve tools; the host scenario also checks receive replay, retained-key recovery and one uncertain synthetic submission with its liability held.

Keychain adapter tests must inject Security operations rather than access live items. Request construction, result/error handling and anchor encoding checks can establish source behavior; they cannot establish entitlement eligibility, actual storage atomicity or crash durability.

## Diagnostics

Diagnostics are silent by default. The service and bridge entries explicitly select their exact Agent categories while leaving buffering and routing disabled. Embedders own any capture configuration; libraries do not configure or clear it. Agent events contain only closed public classifications and fresh local random trace tokens. They never accept wallet/request identifiers, amounts, credentials, payloads, endpoints or arbitrary error text, including private fields. SDK loggers remain no-op and stdout remains protocol-only. See the [observation contract](Documentation/Architecture.md#diagnostic-observations) for capture scope and evidence limits.

## Product boundaries

Only the service may open agent storage and hold signing authority. Clients receive authorized projections and opaque identifiers. An autonomous grant authorizes its named accounts, including later deposits, until expiry or revocation. Optional approval is enforced by the service; no payment budget policy is implied. The local writer lock does not fence a copied seed or another device.

Uncertain submission retains exact bytes and account restrictions. Recovery disables copied authority and preserves liabilities; missing history cannot establish that funds were not sent. Seed backup recovers keys and conditionally discoverable funds, while a journal backup preserves only its retained operational facts.

Target unattended availability is a logged-in, awake Mac, including screen lock and Wallet termination. Signed runtime proof remains required. Sleep, logout, key unavailability or network loss can block progress. No keep-awake behavior, analytics or tracking is added.

See [MCP protocol and client setup](Documentation/MCP.md), [Architecture](Documentation/Architecture.md) for implemented internal contracts and [Deployment](Documentation/Deployment.md) for the proposed artifact inventory and outstanding custody, lifecycle and distribution proof. The product is not qualified for funding or production autonomy.

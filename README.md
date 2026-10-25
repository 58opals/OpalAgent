# OpalAgent

OpalAgent is a dedicated Bitcoin Cash wallet service and local MCP bridge for macOS. The service owns its seed, accounts, policy, credentials and operation history independently of personal Wallet funds. Wallet supplies the proposed owner controls and distribution bundle.

The internal durable BCH engine includes encrypted fixed-profile seed recovery, an actual SQLite journal, scoped authorization, bounded receive allocation, synchronization, exact-payment approval, immutable transaction submission and restricted recovery. External keys, continuity anchors, peer authentication, chain views and transport are injected. `AgentBridge` serves the twelve strict MCP tool shapes through the owned Swift protocol implementation; ordinary construction returns unavailable for wallet operations because no qualified native deployment/custody provider exists. `AgentService` still reports unavailable. Neither entry installs a service, opens live Keychain items or starts a live wallet runtime. A separate Debug-only development fixture composes the actual engine with disposable injected boundaries for protocol qualification.

Internal service Keychain adapter source reads existing 256-bit wrapping keys and complete continuity anchors through injectable Security operations. An explicit owner-authorized new-wallet composition can add and verify one new wrapping key, then initialize restricted custody without grants. It rejects existing or ambiguous evidence and never provisions during startup or recovery. `DurableWalletStore` provides distinct explicit fresh initialization and same-store reopening over one SQLite writer lease. A nonsecret scope locator only selects the exact independently anchored custody; reopening never creates storage or provisions a key. Shipping startup does not construct these adapters. Rotation, deletion and migration remain absent.

An internal `ServiceAssembly` now connects the strict store, owner controls, capability dispatch and distinct endpoint roles under one terminal lifecycle. A trusted asynchronous factory builds the existing Base adapter against that same owned custody/coordinator. Cached readiness remains an explicit host input with an unavailable default. Startup admission waits for the complete endpoint set; fresh wallets remain owner-only until creation, enablement and enrollment succeed. Shutdown retires runtime handles and drains admitted calls plus retained effect work before releasing the writer. A reopened assembly preserves durable identity and rejects prior runtime handles. Synthetic lifecycle tests use injected endpoint hosts; shipping service startup remains unavailable and no native deployment qualification follows.

Native owner and capability requests share the internal `NativeServiceFrames` dispatcher with actual assembly-backed synthetic callers. It decodes the existing bounded `NativeWire` format, invokes handlers using an opaque current `ServiceConnection`, and encodes the response; decoding grants no authority. Owner consent and the separate sensitive-data slot remain required by the existing method contract. This shared source path supplies no physical NSXPC, signed-peer, native handshake/callback, listener or installed-service qualification.

## Package

Requires macOS 27.0, the Xcode 27 family and a compiler supporting Swift tools 6.4 and Swift 6 language mode. The selected SDK can be a newer 27.x version without raising the deployment minimum. See [Toolchain selection and updates](Documentation/Toolchains.md) for the current observed selection and fresh-validation procedure. The products are:

| Product | Purpose |
| --- | --- |
| `AgentValues` | Public transport values with no engine, storage or protocol dependency. |
| `AgentClient` | Public injected clients and unavailable-by-default native transport construction; no engine/storage dependency. |
| `AgentAppIntents` | Mac-only Apple action/entity/query adapters over the public client and values; host dependencies must be explicitly registered. |
| `AgentService` | Intended shipping service entry; linked to the internal core, currently unavailable. |
| `AgentBridge` | Shipping stdio adapter; discovery works, wallet calls require a qualified authenticated service channel. |
| `StoreLockProbe` | Development-only competing-process lock probe; excluded from distribution. |
| `AgentProtocolFixture` | Debug-only disposable engine/MCP composition; excluded from distribution and unavailable in Release. |

`AgentServiceCore` is an internal target with no library product. It uses the public `OpalBaseCore` ordinary-BCH product and system SQLite through `CSQLite`. Client and bridge cannot import the engine through a public product. `AgentAppIntents` imports only the public client/values and Apple frameworks, with no engine, Base, SQLite or MCP SDK dependency. `AgentMCP` owns its transport protocol, JSON values, tool models and request tasks without SDK imports. The root package and its tests have no MCP SDK or SwiftLog dependency. Its resolved graph contains only OpalBase, OpalCrypto, OpalDiagnostics, OpalFusion and SwiftFulcrum. The public values/client and native wire targets have no SDK, Base or SQLite dependency. The bridge does not link the engine or privacy integrations.

The package pins public OpalBase revision `d7038c2d18f89d4805059b0a4f7a84ca525849a1`, which provides `OpalBaseCore`. Agent-owned observations pin public OpalDiagnostics revision `aa56dec5d6c8581beb2b3cef43b03dd577ccd9f1`, already shared by the foundation packages. Both direct requirements use exact revisions; the root `Package.resolved` retains the canonical public dependency graph.

## Build and test

Run from the package root:

```sh
scripts/validate.sh
scripts/validate.sh focused AuthorizationTests
scripts/validate.sh assurance
```

The default `develop` lane covers the public client, native wire, owned MCP, App Intents and authorization contracts. It is focused feedback, not the complete engine, process-lifecycle or recovery suite. `focused` accepts a literal substring of a discovered test identifier, rejects empty/no-match selections and reports selected/total definitions. `assurance` keeps the complete serial offline suite, including actual SQLite, injected custody and disposable fixture subprocesses. Add leading `--list` to inspect any lane without executing tests.

Discovery compiles the test products and their executable fixtures once using the tracked `Package.resolved`; selected execution reuses those products within that invocation. There is no separate `swift build` prerequisite. SwiftPM checks incremental inputs on subsequent invocations and the script rejects lock changes. The dependency-resolution CI job separately resolves the published graph and checks the lock on pushes and pull requests. Focused validation does not establish full publication, installed-service or custody acceptance.

Build products default to `.build/validation`. Set absolute `OPAL_VALIDATION_SCRATCH_PATH` to select an external or fresh toolchain lane. Do not copy the internal `--skip-build` command for use after source, dependency or toolchain changes.

After the selected developer directory, Xcode build, Swift compiler, SDK or Metal component changes, follow the [toolchain update procedure](Documentation/Toolchains.md) and use a new external build lane. Preserve the existing dependency lock and earlier build/test receipts; an IDE update does not authorize a package update or establish a new validation result.

The root suite uses test-only `AgentMCPTestSupport` for its owned wire peer; this target has no library product or SDK dependency. Literal wire contracts and real stdio child-process checks exercise the owned implementation. The former separately resolved official SDK harness has been retired, including its package dependencies. Independent external-client interoperability is no longer an automated repository check and requires separately scoped acceptance; the root suite does not establish it.

Process tests discover the exact `AgentProtocolFixture` executable beside the loaded package test bundle. An optional explicit executable binding requires both `OPAL_AGENT_PROTOCOL_FIXTURE_EXECUTABLE` and its matching `OPAL_AGENT_PROTOCOL_FIXTURE_SHA256`; partial or mismatching bindings fail before launch. No fixture environment configuration is required for the command above. Normal fixture construction remains fresh-only; process tests resume only their own capability-bound disposable namespace. The Debug fixture routes its twelve MCP tools through actual `ServiceAssembly` handlers and current authenticated connections. Owner creation, enablement and enrollment use its separate owner boundary; the owned effect factory binds the real Base adapter to that same store and custody.

Deterministic tests use published, permanently disposable vectors, actual SQLite and injected Security-style item, chain, relay and endpoint-host boundaries. They include process termination around SQL commits, concurrency, restart, stale evidence and recovery. The assembly process scenarios retain receive replay, unsubmitted invalidation and exact ambiguous payment identity/bytes/liability through death and bounded retry exhaustion. Controlled graceful stop proves admission closure and retained writer ownership until explicit fixture relay release and actual drainage.

Stdio-closure process checks use actual parent pipe half-close. Ordinary fresh CLI cases require completed receive work to remain retained, an unterminated effectful final frame to be discarded without an extra effect, and natural protocol/service teardown followed by exit and reap. Controlled cases keep their separate control channel open to observe admission closure and a held relay’s writer ownership before explicit relay release and actual drainage; later control close is cleanup. Local test-client disconnect using borrowed descriptors is not OS EOF. This fixture-owned assembly lifecycle does not make MCP client disconnection stop an independently hosted production service.

Output-loss variants first join parent client sends and reader work while the OS descriptors remain open, then close only the stdout reader and send a complete newline ping on the still-open stdin pipe. A fixed fixture witness observes lower-send failure; ordinary cases require natural exit/reap, while held-relay cases retain the separate admission, writer, release and drain checks. The failure witness and admission-closure event have no promised arrival order. A separate real-pipe transport unit independently observes raw `EPIPE`; fixture metadata does not expose the child syscall errno.

Explicit owner-only recovery fixtures retain their distinct storage/recovery proof. Real Base integration exercises derivation, transaction construction and public reservation/submission APIs. These checks do not qualify a live Keychain anchor, real XPC signatures, an installed helper, remote chain completeness or installed-service interoperability. Root protocol tests use an owned test peer and raw wire messages for both admitted profiles. Earlier limited June actual-host acceptance exercised all twelve tools, receive replay, retained-key recovery and one uncertain synthetic submission with its liability held; that host evidence predates the owned server and requires renewed qualification.

Keychain adapter tests must inject Security operations rather than access live items. Request construction, result/error handling and anchor encoding checks can establish source behavior; they cannot establish entitlement eligibility, actual storage atomicity or crash durability.

## Diagnostics

Diagnostics are silent by default. The service and bridge entries explicitly select their exact Agent categories while leaving buffering and routing disabled. Embedders own any capture configuration; libraries do not configure or clear it. Agent events contain only closed public classifications and fresh local random trace tokens. They never accept wallet/request identifiers, amounts, credentials, payloads, endpoints or arbitrary error text, including private fields. The owned MCP transport requires no logger and stdout remains protocol-only. See the [observation contract](Documentation/Architecture.md#diagnostic-observations) for capture scope and evidence limits.

## Product boundaries

Only the service may open agent storage and hold signing authority. Clients receive authorized projections and opaque identifiers. An autonomous grant authorizes its named accounts, including later deposits, until expiry or revocation. Optional approval is enforced by the service; no payment budget policy is implied. The local writer lock does not fence a copied seed or another device.

Uncertain submission retains exact bytes and account restrictions. Recovery disables copied authority and preserves liabilities; missing history cannot establish that funds were not sent. Seed backup recovers keys and conditionally discoverable funds, while a journal backup preserves only its retained operational facts.

Target unattended availability is a logged-in, awake Mac, including screen lock and Wallet termination. Signed runtime proof remains required. Sleep, logout, key unavailability or network loss can block progress. No keep-awake behavior, analytics or tracking is added.

See [MCP protocol and client setup](Documentation/MCP.md), [Architecture](Documentation/Architecture.md) for implemented internal contracts and [Deployment](Documentation/Deployment.md) for the proposed artifact inventory and outstanding custody, lifecycle and distribution proof. The product is not qualified for funding or production autonomy.

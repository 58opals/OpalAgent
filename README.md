# OpalAgent

OpalAgent is a dedicated Bitcoin Cash wallet service and local MCP bridge for macOS. The service owns its seed, accounts, policy, credentials and operation history independently of personal Wallet funds. Wallet supplies the proposed owner controls and distribution bundle.

The internal durable BCH engine includes encrypted fixed-profile seed recovery, an actual SQLite journal, scoped authorization, bounded receive allocation, synchronization, exact-payment approval, immutable transaction submission and restricted recovery. External keys, continuity anchors, peer authentication, chain views and transport are injected. The shipping `AgentService` and `AgentBridge` entries still report unavailable; neither installs a service, opens live Keychain items, starts this runtime or provides an interoperable MCP server.

## Package

Requires macOS 27.0, Xcode 27 and Swift 6.4. The five products remain:

| Product | Purpose |
| --- | --- |
| `AgentValues` | Public transport values with no engine, storage or protocol dependency. |
| `AgentClient` | Public injected client depending only on `AgentValues`. |
| `AgentService` | Intended shipping service entry; linked to the internal core, currently unavailable. |
| `AgentBridge` | Intended shipping stdio executable; depends on the client, currently unavailable. |
| `StoreLockProbe` | Development-only competing-process lock probe; excluded from distribution. |

`AgentServiceCore` is an internal target with no library product. It uses the public `OpalBaseCore` ordinary-BCH product and system SQLite through `CSQLite`. Client and bridge cannot import the engine through a public product. No MCP SDK or privacy engine is part of their dependency boundary.

The package pins public OpalBase revision `f1ec2dc05ce778eb2d29230b0fd9ba5fc1c02597`, which provides `OpalBaseCore`. The root `Package.resolved` records this package’s resolved dependency graph.

## Build and test

Run from the package root using an absolute scratch directory outside the source tree:

```sh
swift package --scratch-path "<external-directory>" dump-package
swift package --scratch-path "<external-directory>" describe
swift build --scratch-path "<external-directory>"
swift test --no-parallel --scratch-path "<external-directory>"
```

Deterministic tests use disposable synthetic keys/data, actual SQLite and injected chain/relay/anchor boundaries. They include process termination around SQL commits, concurrency, restart, stale evidence and recovery. Real Base integration exercises derivation, transaction construction and public reservation/submission APIs. These checks do not qualify a live Keychain anchor, real XPC signatures, an installed helper, remote chain completeness or MCP interoperability.

## Product boundaries

Only the service may open agent storage and hold signing authority. Clients receive authorized projections and opaque identifiers. An autonomous grant authorizes its named accounts, including later deposits, until expiry or revocation. Optional approval is enforced by the service; no payment budget policy is implied. The local writer lock does not fence a copied seed or another device.

Uncertain submission retains exact bytes and account restrictions. Recovery disables copied authority and preserves liabilities; missing history cannot establish that funds were not sent. Seed backup recovers keys and conditionally discoverable funds, while a journal backup preserves only its retained operational facts.

Target unattended availability is a logged-in, awake Mac, including screen lock and Wallet termination. Signed runtime proof remains required. Sleep, logout, key unavailability or network loss can block progress. No keep-awake behavior, analytics or tracking is added.

See [Architecture](Documentation/Architecture.md) for implemented internal contracts and [Deployment](Documentation/Deployment.md) for the proposed artifact inventory and outstanding custody, lifecycle and distribution proof. The product is not qualified for funding or production autonomy.

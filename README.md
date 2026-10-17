# OpalAgent

OpalAgent is the foundation for a dedicated Bitcoin Cash wallet service and local MCP bridge on macOS. The intended service owns its wallet, policy, secrets and operation history independently of Wallet's personal wallets. Wallet supplies the owner controls and proposed distribution bundle.

The current package provides transport-neutral values, an injected client, internal authorization/encryption/continuity models, serialized authority commands and a process-lock primitive. `AgentService` and `AgentBridge` fail closed because production adapters are unavailable. They do not install a service, open live Keychain items, operate a wallet or provide an interoperable MCP server.

## Package

Requires macOS 27.0, Xcode 27 and Swift 6.4. SwiftPM declares exactly five products: two public libraries, two intended shipping executables and one development-only executable. There are no third-party package dependencies in this foundation.

| Product | Purpose |
| --- | --- |
| `AgentValues` | Public value contracts; no engine, storage or protocol framework dependency. |
| `AgentClient` | Public client with an injected transport; depends only on `AgentValues`. |
| `AgentService` | Shipping service entry linked with the internal core; currently reports unavailable. |
| `AgentBridge` | Shipping stdio bridge executable; depends on the client and currently reports unavailable. |
| `StoreLockProbe` | Explicit development-only executable for disposable process-lock checks; excluded from the proposed Wallet distribution. |

`AgentServiceCore` is an internal target, not a library product. Neither the client nor bridge depends on it. The package does not yet depend on OpalBase or an MCP SDK.

## Build and test

Run from the package root. Replace `<external-directory>` with a writable absolute directory outside the source tree; use the same directory for related commands. Build products and caches belong there.

```sh
swift package --scratch-path "<external-directory>" dump-package
swift package --scratch-path "<external-directory>" describe
swift build --scratch-path "<external-directory>"
swift test --scratch-path "<external-directory>"
```

The deterministic suites use synthetic principals, injected collaborators and disposable storage. The development probe checks competing processes against the same local store lock. These checks cannot establish Keychain entitlements, code-signature enforcement, crash durability, an installed service, payment execution or MCP interoperability.

## Product boundaries

Only the proposed service may open agent storage or hold signing authority. Clients receive authorized projections and opaque identifiers. A local store lock excludes competing writers of that store; it provides no protection against another device or a copied seed. Recovery preserves possible payment liabilities and disables copied authority instead of treating missing history as proof that funds were not spent.

The intended unattended availability is a logged-in, awake Mac, including screen lock and Wallet UI termination. This is target behavior requiring signed runtime proof. Sleep, logout, unavailable keys or unavailable networking may prevent progress. The product adds no keep-awake behavior, analytics or tracking.

See [Architecture](Documentation/Architecture.md) for module and trust boundaries and [Deployment](Documentation/Deployment.md) for the proposed artifact inventory, lifecycle duties, custody prerequisites and outstanding proof.

# Independent MCP client acceptance

This separate Swift 6.4/macOS 27 test package uses the official MCP Swift SDK 0.12.1 as its client. It does not depend on, import or copy the Agent root's protocol types or transport implementation. Its external dependencies and `Package.resolved` belong to this package, independently of the Agent root graph.

The [toolchain update procedure](../../Documentation/Toolchains.md) applies to both sides of this exchange. After an IDE/compiler/SDK or Metal change, rebuild the Debug fixture and this package in distinct fresh external lanes, then bind the new fixture path and digest. An old fixture paired with a newly built SDK harness proves only that cross-version exchange; it does not renew same-toolchain acceptance.

Build the root's Debug `AgentProtocolFixture` separately, using the reviewed root lock and external scratch/cache paths. Supply both bindings below; absent, partial, malformed or mismatched bindings fail the test rather than skip it. The path must name an owned, regular executable called `AgentProtocolFixture`; the SHA-256 must be the independently reviewed lowercase digest of those exact bytes. A digest binds bytes and does not authenticate a signature or qualify the executable's source.

```sh
export OPAL_AGENT_PROTOCOL_FIXTURE_EXECUTABLE="<absolute-reviewed-Debug-build-path>/AgentProtocolFixture"
export OPAL_AGENT_PROTOCOL_FIXTURE_SHA256="<reviewed-64-character-lowercase-SHA-256>"
xcrun swift test --package-path "<Agent-root>/Tests/MCPInteroperability" \
  --scratch-path "<new-external-harness-scratch>" \
  --cache-path "<external-harness-cache>" \
  --config-path "<external-harness-config>" \
  --security-path "<external-harness-security>" \
  --force-resolved-versions --disable-keychain --disable-netrc --no-parallel
```

Keep all build paths outside the Agent source tree and distinct from root build state. Resolve this package's reviewed exact lock separately before using `--force-resolved-versions`; do not reuse the root lock or silently update dependencies. Retain the exact source, build and execution receipts. The test itself does not run SwiftPM or build an executable.

One owned child runs the existing `--scenario autonomous` Debug fixture with a fresh temporary state directory and the ordinary inherited process environment. The selected fixture injects permanently disposable custody, chain and relay boundaries; the test does not provide live Keychain, network or wallet providers. The SDK performs its default November initialization. Acceptance checks the twelve-tool catalog and selected independent schema details, text/structured result agreement, pre-sync unavailable reads, all twelve tool calls, keyed synchronization and receive replay, cancellation, and retained accepted synthetic submission observations. It then half-closes the child's real stdin and requires natural exit zero.

The child has a 60-second overall deadline; operation polling is bounded to eight seconds. A bounded byte relay feeds the unmodified SDK stdio transport: stdout frames are at most 262,144 bytes, total stdout is at most eight MiB, and stderr is at most 64 KiB. Requests in this test are capped before SDK encoding. Failure cleanup affects only the owned child, its pipes and its unique temporary directory. A timeout or forced cleanup is failure, never successful exit proof.

This focused client test does not duplicate the root's crash/restart, competing-writer, consent, revocation or pipe-fault suite. Root raw-wire tests retain June coverage. Earlier June actual-host acceptance predates the owned server and is not renewed here. Passing this test supplies no installed/native IPC, evaluated signature, custody, live network, funding or production autonomy qualification.

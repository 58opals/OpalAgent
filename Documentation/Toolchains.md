# Toolchain selection and updates

The supported contract is the Xcode 27 family, Swift tools 6.4, Swift 6 language mode and macOS 27.0 deployment. Keep those requirements separate from the exact compiler and SDK used by a particular build. A Swift 6.4.2 compiler can build a tools-6.4 package; selecting a 27.2 SDK does not change the package's macOS 27.0 deployment target. A future language, manifest or minimum-platform change requires its own reviewed compatibility decision.

## Current observed selection

The development selection inspected on 2026-10-24 is Xcode 27.2 RC, build `27B48`, Swift `6.4.2` and SDK version `27.2`. Apple's [Xcode 27.2 RC release entry](https://developer.apple.com/news/releases/?id=10192026g) identifies the IDE build and its October 19, 2026 publication. The compiler and selected SDK are local observations, not additional claims supplied by that release entry.

Fresh working-source validation under this selection passed on 2026-10-24: Debug/test compilation, all 415 root tests, the separately rebuilt SDK harness's twelve-tool scenario and eight invalid-binding cases, both shipping Release builds, and nonshipping Release-fixture refusal. This is local build/synthetic evidence, not installed or signed-runtime qualification. Earlier results retain their original compiler, SDK, source and artifact bindings. Record the actual selected platform and SDK path rather than inferring every SDK from the IDE name. Metal is a separately selected component and needs its own execution observation.

The selected macOS SDK and actual SwiftBuild compile/link inputs identify 27.2. AgentService's object records SDK 27.2, while its final Release image records SDK 27.0 with minimum macOS 27.0. A small independent build probe reproduces that final-image metadata distinction even with an explicit SDK path; its cause is not established. Keep observed compiler inputs and image load commands separate, and do not force metadata or claim SDK-27.2-specific linked behavior from the selection alone.

## Capture the build inputs

Before validation, record the default developer directory, any `DEVELOPER_DIR` or `TOOLCHAINS` override, the effective compiler path, Xcode version/build and the selected SDK version/path. These inspection commands do not change the selected tools:

```sh
xcode-select -p
xcodebuild -version
xcrun --find swift
xcrun swift --version
xcrun --sdk macosx --show-sdk-version
xcrun --sdk macosx --show-sdk-path
```

`DEVELOPER_DIR` can override the default reported by `xcode-select`; retain both observations when it is set. Record each additional platform SDK actually used by a consumer build. Do not treat the Swift language mode, package tools version, compiler version, SDK version and deployment target as interchangeable values.

The OpalCrypto build plugin also needs the Metal Toolchain component. Record its compiler version and both `metal` and `metallib` paths separately from Xcode and SDK observations. Verify availability through the selected developer tools; the compiler and library tool must form a usable pair. Finding the component does not prove a shader compiled or a runtime accelerator was qualified.

## Start a fresh validation lane

1. When the developer directory, IDE build, compiler, selected SDK or Metal component changes, allocate a new external scratch/output directory. Use fresh derived data for Xcode consumer builds as well. Keep old build directories and receipts bound to their original inputs; never relabel them with the new toolchain.
2. Preserve the reviewed source revision and dependency lock. Resolve and build against those locked revisions in the new lane; stop on a lock mismatch rather than silently updating dependencies. Keep normal compiler/plugin sandboxing, signing, entitlements and storage boundaries. An IDE update is not a reason to relax them.
3. Run the root [build and test workflow](../README.md#build-and-test), including the complete serial suite and the required Debug and named Release products. Record commands, toolchain observations, source/lock bindings and actual results. A successful build does not imply a test or installed-runtime pass.
4. Rebuild the Debug `AgentProtocolFixture` and the separate [SDK interoperability package](../Tests/MCPInteroperability/README.md) in distinct fresh external lanes. Rebind `OPAL_AGENT_PROTOCOL_FIXTURE_EXECUTABLE` and `OPAL_AGENT_PROTOCOL_FIXTURE_SHA256` to the newly built, reviewed fixture. Do not run the new harness against an old fixture and call it same-toolchain acceptance: that combination establishes only the particular cross-version exchange exercised.
5. Repeat affected artifact staging/static checks and consumer validation when those outputs form part of the claimed result. Retain the distinction between unavailable-entrypoint, synthetic protocol, signed native/custody, installed-system and distribution evidence. Toolchain validation supplies no new live-wallet or funding qualification.

Keep exact observed versions in validation receipts and this current-selection note. Requirements and ordinary build instructions should stay at the supported family/tooling contract unless that contract deliberately changes. A future IDE minor update therefore requires one new selection record and fresh affected validation, rather than blanket edits to historical documents.

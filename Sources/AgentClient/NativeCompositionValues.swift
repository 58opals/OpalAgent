import AgentNativeIPC

/// Public composition contracts for consumers importing AgentClient and AgentValues.
/// These aliases expose only the required types, without exporting the native wire module.
public typealias NativeWalletConsentProvider = AgentNativeIPC.NativeWalletConsentProvider
public typealias NativeConsentChallenge = AgentNativeIPC.NativeConsentChallenge
public typealias NativeConsentProof = AgentNativeIPC.NativeConsentProof
public typealias NativeDeploymentProvider = AgentNativeIPC.NativeDeploymentProvider
public typealias NativeDeploymentPolicy = AgentNativeIPC.NativeDeploymentPolicy
public typealias NativeSignedIdentity = AgentNativeIPC.NativeSignedIdentity
public typealias NativeChannel = AgentNativeIPC.NativeChannel

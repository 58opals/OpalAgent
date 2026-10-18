import Foundation

@objc public protocol NativeIntegrationXPC {
    func hello(_ frame: NSData, reply: @escaping @Sendable (NSData) -> Void)
    func authenticate(_ frame: NSData, credential: NSData, reply: @escaping @Sendable (NSData) -> Void)
    func call(_ frame: NSData, reply: @escaping @Sendable (NSData) -> Void)
}
@objc public protocol NativeOwnerXPC {
    func hello(_ frame: NSData, reply: @escaping @Sendable (NSData) -> Void)
    func call(_ frame: NSData, sensitive: NSData?, reply: @escaping @Sendable (NSData, NSData?) -> Void)
}
@objc public protocol NativeWalletConsentXPC {
    func authenticateOwner(_ frame: NSData, reply: @escaping @Sendable (NSData) -> Void)
}

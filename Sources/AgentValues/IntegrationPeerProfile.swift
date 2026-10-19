/// The signed integration channel allowed to use an enrolled credential.
/// The default retains the existing bridge-only MCP authority.
public enum IntegrationPeerProfile: String, Codable, Sendable {
    case mcp
    case appleAutomation
}

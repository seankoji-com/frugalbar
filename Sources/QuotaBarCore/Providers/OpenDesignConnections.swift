import Foundation

public enum OpenDesignConnection: String, CaseIterable, Identifiable, Sendable {
    case primary, secondary

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public var displayName: String { "OpenDesign · \(title)" }

    var other: Self { self == .primary ? .secondary : .primary }
}

public struct OpenDesignWorkspace: Codable, Sendable, Equatable {
    let workspaceId: String
    let workspaceName: String?
    let personalMembershipTier: String?

    public var name: String? { workspaceName.map(\.trimmed).flatMap { $0.isEmpty ? nil : $0 } }
    public var seriesID: String { OpenDesignQuotaProvider.seriesID(workspaceID: workspaceId) }
}

public struct OpenDesignConnections: Codable, Sendable, Equatable {
    static let legacyEnabledKey = "opendesign.webSession.enabled"
    private static let key = "opendesign.webSession.connections"

    private(set) var followsLegacyPrimary: Bool
    private var workspaces: [String: OpenDesignWorkspace] = [:]

    init(followsLegacyPrimary: Bool = false) {
        self.followsLegacyPrimary = followsLegacyPrimary
    }

    public static func load() -> Self { load(from: CredentialStore.preferences) }

    static func load(from preferences: UserDefaults) -> Self {
        if let data = preferences.data(forKey: key),
           let connections = try? JSONDecoder().decode(Self.self, from: data) {
            return connections
        }
        return Self(followsLegacyPrimary: preferences.bool(forKey: legacyEnabledKey))
    }

    func save(to preferences: UserDefaults) {
        preferences.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    public func workspace(for connection: OpenDesignConnection) -> OpenDesignWorkspace? {
        workspaces[connection.rawValue]
    }

    public func isConnected(_ connection: OpenDesignConnection) -> Bool {
        workspace(for: connection) != nil || (connection == .primary && followsLegacyPrimary)
    }

    func instanceID(for connection: OpenDesignConnection) -> String? {
        workspace(for: connection)?.seriesID ?? (connection == .primary ? VendorIdentifier.opendesign.rawValue : nil)
    }

    mutating func link(_ workspace: OpenDesignWorkspace, to connection: OpenDesignConnection) throws(OpenDesignLinkError) {
        guard workspace.workspaceId != self.workspace(for: connection.other)?.workspaceId else {
            throw OpenDesignLinkError.duplicate(connection.other)
        }
        workspaces[connection.rawValue] = workspace
        if connection == .primary { followsLegacyPrimary = false }
    }

    mutating func unlink(_ connection: OpenDesignConnection) {
        workspaces[connection.rawValue] = nil
        if connection == .primary { followsLegacyPrimary = false }
    }
}

public enum OpenDesignLinkError: LocalizedError, Equatable {
    case selectionUnavailable(UnavailableReason)
    case primarySelectionUnavailable(UnavailableReason)
    case duplicate(OpenDesignConnection)
    case connectionChanged

    public var errorDescription: String? {
        switch self {
        case .selectionUnavailable(let reason):
            "Could not verify this workspace (\(reason.headline)). Sign in and select it in OpenDesign, then try again."
        case .primarySelectionUnavailable(let reason):
            "Could not verify the existing primary workspace (\(reason.headline)). Open the primary connection and confirm its workspace first."
        case .duplicate(let other):
            "This workspace is already linked as \(other.title.lowercased()). Select the other workspace in OpenDesign."
        case .connectionChanged:
            "The connection changed while verifying the workspace. Try again."
        }
    }
}

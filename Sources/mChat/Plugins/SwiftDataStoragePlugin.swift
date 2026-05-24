import Foundation
import AppBrickCore
import mChatCore

// MARK: - SwiftDataStoragePlugin

/// Registers the SwiftData-backed message store into the plugin container.
///
/// Usage in the composition root:
/// ```swift
/// SwiftDataStoragePlugin().register(in: container)
/// ```
///
/// To swap storage backends, replace this plugin with another conformance, e.g.:
/// ```swift
/// iCloudStoragePlugin().register(in: container)   // CloudKit sync
/// SQLiteStoragePlugin().register(in: container)   // embedded SQLite
/// GraphDBStoragePlugin().register(in: container)  // custom graph database
/// ```
public struct SwiftDataStoragePlugin: AppPlugin {

    public let name = "SwiftDataStorage"

    public init() {}

    public func register(in container: PluginContainer) {
        // Registered as StorageBackendBox so ChatService resolves by protocol,
        // not by the concrete MessageStore type.
        container.register(StorageBackendBox(MessageStore.shared))
    }
}

// MARK: - Future storage plugins (stubs)

// Each future backend gets its own file in Sources/mChat/Plugins/:
//
// iCloudStoragePlugin.swift  — NSPersistentCloudKitContainer, CloudKit sync
// SQLiteStoragePlugin.swift  — GRDB or SQLite.swift, embedded database
// GraphDBStoragePlugin.swift — custom graph database (Stephan's project)

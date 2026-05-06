// FILE: DesktopFilesystemService.swift
// Purpose: Reads browseable local Mac directories over the paired bridge connection.
// Layer: Service
// Exports: DesktopFilesystemService, DesktopDirectoryListing, DesktopDirectoryDescriptor
// Depends on: CodexService

import Foundation

struct DesktopDirectoryDescriptor: Decodable, Hashable, Sendable, Identifiable {
    let path: String
    let name: String
    let isHomeDirectory: Bool
    let isRootDirectory: Bool

    var id: String { path }

    private enum CodingKeys: String, CodingKey {
        case path
        case name
        case isHomeDirectory
        case isRootDirectory
    }

    init(path: String, name: String, isHomeDirectory: Bool = false, isRootDirectory: Bool = false) {
        self.path = path
        self.name = name
        self.isHomeDirectory = isHomeDirectory
        self.isRootDirectory = isRootDirectory
    }
}

struct DesktopDirectoryListing: Decodable, Sendable {
    let directory: DesktopDirectoryDescriptor
    let parentDirectory: DesktopDirectoryDescriptor?
    let children: [DesktopDirectoryDescriptor]

    private enum CodingKeys: String, CodingKey {
        case directory
        case parentDirectory
        case children
    }

    init(
        directory: DesktopDirectoryDescriptor,
        parentDirectory: DesktopDirectoryDescriptor?,
        children: [DesktopDirectoryDescriptor]
    ) {
        self.directory = directory
        self.parentDirectory = parentDirectory
        self.children = children
    }
}

enum DesktopFilesystemError: LocalizedError {
    case disconnected
    case invalidResponse
    case bridgeError(code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return "Not connected to your Mac."
        case .invalidResponse:
            return "The Mac bridge returned an invalid folder listing."
        case .bridgeError(let code, let message):
            return DesktopFilesystemError.userMessage(for: code, fallback: message)
        }
    }
}

@MainActor
final class DesktopFilesystemService {
    private let codex: CodexService

    init(codex: CodexService) {
        self.codex = codex
    }

    func listDirectory(path: String? = nil) async throws -> DesktopDirectoryListing {
        do {
            return try await listProjectDirectory(path: path)
        } catch let error as CodexServiceError {
            if !shouldFallbackToLegacyFilesystem(for: error) {
                throw mapCodexError(error)
            }
        }

        var params: RPCObject = [:]
        if let path {
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPath.isEmpty {
                params["path"] = .string(trimmedPath)
            }
        }

        do {
            let response = try await codex.sendRequest(
                method: "desktop/filesystem/listDirectory",
                params: .object(params)
            )
            guard let result = response.result,
                  let listing = codex.decodeModel(DesktopDirectoryListing.self, from: result) else {
                throw DesktopFilesystemError.invalidResponse
            }
            return listing
        } catch let error as CodexServiceError {
            switch error {
            case .disconnected:
                throw DesktopFilesystemError.disconnected
            case .rpcError(let rpcError):
                let errorCode = rpcError.data?.objectValue?["errorCode"]?.stringValue
                throw DesktopFilesystemError.bridgeError(code: errorCode, message: rpcError.message)
            default:
                throw DesktopFilesystemError.bridgeError(code: nil, message: error.errorDescription)
            }
        }
    }

    func quickLocations() async throws -> [DesktopDirectoryDescriptor] {
        let locations = try await codex.fetchProjectQuickLocations()
        return locations.map { location in
            DesktopDirectoryDescriptor(
                path: location.path,
                name: location.label,
                isHomeDirectory: location.id == "home",
                isRootDirectory: false
            )
        }
    }

    private func listProjectDirectory(path: String?) async throws -> DesktopDirectoryListing {
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let listing: CodexProjectDirectoryListing
        if let trimmedPath, !trimmedPath.isEmpty {
            listing = try await codex.listProjectDirectory(path: trimmedPath)
        } else if let firstLocation = try await codex.fetchProjectQuickLocations().first {
            listing = try await codex.listProjectDirectory(path: firstLocation.path)
        } else {
            throw DesktopFilesystemError.invalidResponse
        }

        return DesktopDirectoryListing(
            directory: DesktopDirectoryDescriptor(
                path: listing.path,
                name: Self.displayName(forPath: listing.path),
                isHomeDirectory: false,
                isRootDirectory: listing.parentPath == nil
            ),
            parentDirectory: listing.parentPath.map { parentPath in
                DesktopDirectoryDescriptor(
                    path: parentPath,
                    name: Self.displayName(forPath: parentPath),
                    isHomeDirectory: false,
                    isRootDirectory: false
                )
            },
            children: listing.entries.map { entry in
                DesktopDirectoryDescriptor(
                    path: entry.path,
                    name: entry.name,
                    isHomeDirectory: false,
                    isRootDirectory: false
                )
            }
        )
    }

    private func shouldFallbackToLegacyFilesystem(for error: CodexServiceError) -> Bool {
        guard case .rpcError(let rpcError) = error else {
            return false
        }

        let message = rpcError.message.lowercased()
        return rpcError.code == -32601
            || message.contains("unknown method")
            || message.contains("method not found")
            || message.contains("project/quicklocations")
            || message.contains("project/listdirectory")
    }

    private func mapCodexError(_ error: CodexServiceError) -> DesktopFilesystemError {
        switch error {
        case .disconnected:
            return .disconnected
        case .rpcError(let rpcError):
            let errorCode = rpcError.data?.objectValue?["errorCode"]?.stringValue
            return .bridgeError(code: errorCode, message: rpcError.message)
        default:
            return .bridgeError(code: nil, message: error.errorDescription)
        }
    }

    private static func displayName(forPath path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Folder"
        }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? trimmed : name
    }
}

private extension DesktopFilesystemError {
    static func userMessage(for code: String?, fallback: String?) -> String {
        switch code {
        case "directory_not_found":
            return fallback ?? "That folder is not available on this Mac."
        case "not_a_directory":
            return fallback ?? "The selected path is not a folder."
        case "directory_read_failed":
            return fallback ?? "Could not read that folder on your Mac."
        default:
            return fallback ?? "Could not browse folders on your Mac."
        }
    }
}

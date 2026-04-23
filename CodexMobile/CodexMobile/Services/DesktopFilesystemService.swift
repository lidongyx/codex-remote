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

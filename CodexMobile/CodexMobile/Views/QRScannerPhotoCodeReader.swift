// FILE: QRScannerPhotoCodeReader.swift
// Purpose: Extracts pairing QR payload text from a photo-library image.
// Layer: View support
// Exports: QRScannerPhotoCodeReader, QRScannerPhotoDecodeError
// Depends on: Foundation, Vision

import Foundation
import Vision

enum QRScannerPhotoDecodeError: LocalizedError, Equatable {
    case unreadableImage
    case noQRCodeFound

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "That photo could not be read. Choose a clearer image of the Remodex QR code."
        case .noQRCodeFound:
            return "No QR code was found in that photo. Choose a clear screenshot or photo of the Remodex pairing QR."
        }
    }
}

enum QRScannerPhotoCodeReader {
    static func firstQRCode(in imageData: Data) throws -> String {
        guard !imageData.isEmpty else {
            throw QRScannerPhotoDecodeError.unreadableImage
        }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        do {
            let handler = try VNImageRequestHandler(data: imageData, options: [:])
            try handler.perform([request])
        } catch {
            throw QRScannerPhotoDecodeError.unreadableImage
        }

        guard let code = request.results?
            .compactMap(\.payloadStringValue)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            throw QRScannerPhotoDecodeError.noQRCodeFound
        }

        return code
    }
}

// FILE: QRScannerPhotoCodeReaderTests.swift
// Purpose: Verifies photo-library QR imports decode pairing payload text before validation runs.
// Layer: Unit Test
// Exports: QRScannerPhotoCodeReaderTests
// Depends on: XCTest, CodexMobile, CoreImage

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import XCTest
@testable import CodexMobile

final class QRScannerPhotoCodeReaderTests: XCTestCase {
    func testDecodesQRCodeFromPNGImageData() throws {
        let code = """
        {"v":1,"relay":"wss://relay.example","sessionId":"session-123","macDeviceId":"mac-123","macIdentityPublicKey":"pub-key","expiresAt":1900000000000}
        """

        let imageData = try makeQRCodePNG(from: code)

        XCTAssertEqual(try QRScannerPhotoCodeReader.firstQRCode(in: imageData), code)
    }

    func testThrowsWhenPhotoContainsNoQRCode() throws {
        let imageData = try makeSolidPNG()

        XCTAssertThrowsError(try QRScannerPhotoCodeReader.firstQRCode(in: imageData)) { error in
            XCTAssertEqual(error as? QRScannerPhotoDecodeError, .noQRCodeFound)
        }
    }

    private func makeQRCodePNG(from code: String) throws -> Data {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            throw TestError.failedToBuildImage
        }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            throw TestError.failedToBuildImage
        }

        guard let pngData = UIImage(cgImage: cgImage).pngData() else {
            throw TestError.failedToBuildImage
        }

        return pngData
    }

    private func makeSolidPNG() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }

        guard let data = image.pngData() else {
            throw TestError.failedToBuildImage
        }

        return data
    }

    private enum TestError: Error {
        case failedToBuildImage
    }
}

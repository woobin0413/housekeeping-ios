// Produces a non-personal, date-identifiable JPEG for `simctl addmedia` and XCUITest.
// Run: swift scripts/make-ios-photo-fixture.swift /tmp/<fresh-directory>/housekeeping-fixture.jpg
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else { fatalError("Provide a new output JPEG path") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Refuse to overwrite an existing file") }
let context = CGContext(
    data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 640 * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.15, green: 0.55, blue: 0.6, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
context.setFillColor(CGColor(red: 0.98, green: 0.75, blue: 0.2, alpha: 1))
context.fillEllipse(in: CGRect(x: 180, y: 100, width: 280, height: 280))
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(
    destination, context.makeImage()!,
    [
        kCGImageDestinationLossyCompressionQuality: 0.9,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2030:01:02 12:00:00"],
    ] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not encode synthetic fixture") }

import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

enum Images {
    /// Re-encodes any image data (HEIC, PNG, TIFF, JPEG…) as an orientation-corrected JPEG of at most `maxPixel`.
    /// Re-encoding also drops EXIF/GPS metadata, so photos don't carry where they were taken.
    static func normalized(_ data: Data, maxPixel: Int = 2560, quality: Double = 0.85) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = downscaled(src, maxPixel: maxPixel) else { return nil }
        return jpeg(cg, quality: quality)
    }

    static func downscaled(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func cgImage(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downscaled(src, maxPixel: maxPixel)
    }

    static func data(from image: PlatformImage) -> Data? {
        #if os(iOS)
        return image.jpegData(compressionQuality: 0.95)
        #else
        return image.tiffRepresentation
        #endif
    }
}

extension Image {
    init(cgImage: CGImage) {
        #if os(iOS)
        self.init(uiImage: UIImage(cgImage: cgImage))
        #else
        self.init(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
        #endif
    }
}

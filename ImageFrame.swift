import CoreGraphics
import CoreMedia
import CoreVideo
import UIKit

/// 把 WKWebView 的截图转成画中画能消费的 CMSampleBuffer。
enum ImageFrame {

    static func makeSampleBuffer(
        from image: UIImage,
        maxDimension: CGFloat,
        frameIndex: Int64
    ) -> CMSampleBuffer? {
        guard let pixelBuffer = makePixelBuffer(from: image, maxDimension: maxDimension) else {
            return nil
        }
        return makeSampleBuffer(from: pixelBuffer, frameIndex: frameIndex)
    }

    static func makePixelBuffer(from image: UIImage, maxDimension: CGFloat) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }

        let sourceWidth = CGFloat(cgImage.width)
        let sourceHeight = CGFloat(cgImage.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(1, maxDimension / max(sourceWidth, sourceHeight))
        let width = max(2, Int((sourceWidth * scale).rounded()))
        let height = max(2, Int((sourceHeight * scale).rounded()))

        let attributes: CFDictionary = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, frameIndex: Int64) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription)
        guard formatStatus == noErr, let format = formatDescription else { return nil }

        let timescale: CMTimeScale = 2
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: timescale),
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sample = sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0,
           let rawPointer = CFArrayGetValueAtIndex(attachments, 0) {
            let dictionary = unsafeBitCast(rawPointer, to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        return sample
    }
}

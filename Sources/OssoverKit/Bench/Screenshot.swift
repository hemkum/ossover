// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// `screencapture -x -o -l <windowID> <png>` of one window, and whether the picture is black
/// (a renderer that initialised but draws nothing). Needs Screen Recording access; without it
/// macOS hands `screencapture` an empty window, so check `hasScreenRecordingAccess()` first.
public enum Screenshot {
    public static let executable = "/usr/sbin/screencapture"
    /// Mean luminance at or below this is "black": 8/255.
    public static let blackThreshold = 8.0 / 255.0

    /// `-x` no sound, `-o` no window shadow, `-l` the window.
    public static func arguments(windowID: UInt32, output: URL) -> [String] {
        ["-x", "-o", "-l", String(windowID), output.path]
    }

    /// `CGPreflightScreenCaptureAccess`: whether this process may capture other apps' windows.
    public static func hasScreenRecordingAccess() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS to prompt for Screen Recording access (the user then grants it in System
    /// Settings and restarts the tool). Returns the current state; never call this unattended.
    @discardableResult
    public static func requestScreenRecordingAccess() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures `windowID` to `output` (PNG). Throws when the tool fails or writes nothing.
    public static func capture(windowID: UInt32, to output: URL, timeout: TimeInterval = 20) async throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw OssoverError.io("cannot create \(output.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        let args = arguments(windowID: windowID, output: output)
        try await Shell.run(executable: executable, args: args, timeout: timeout).check(command: Shell.commandLine(executable, args))
        let size = (try? fm.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        guard size > 0 else {
            throw OssoverError.io("screencapture wrote nothing to \(output.path) (window \(windowID) gone, or no Screen Recording access)")
        }
    }

    /// Decodes a PNG with CoreGraphics alone.
    public static func loadPNG(_ url: URL) throws -> CGImage {
        guard let provider = CGDataProvider(url: url as CFURL) else { throw OssoverError.missing(url.path) }
        guard let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw OssoverError.invalid("\(url.path) is not a PNG")
        }
        return image
    }

    /// Mean Rec. 709 luminance of a PNG, 0 (black) to 1 (white).
    public static func meanLuminance(ofPNG url: URL) throws -> Double {
        try meanLuminance(of: loadPNG(url))
    }

    /// Mean luminance of an image, computed on a copy downscaled to at most `maxSide` pixels a
    /// side (a 5K window capture is 15 M pixels; 256² tells black from not-black just as well).
    public static func meanLuminance(of image: CGImage, maxSide: Int = 256) throws -> Double {
        let longest = max(image.width, image.height)
        guard longest > 0 else { throw OssoverError.invalid("empty image") }
        let scale = min(1.0, Double(maxSide) / Double(longest))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw OssoverError.io("cannot create a bitmap context for the screenshot") }
        return meanLuminance(rgba: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    /// Pure: mean of `0.2126 R + 0.7152 G + 0.0722 B` over 8-bit RGBA pixels, scaled to 0...1.
    public static func meanLuminance(rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> Double {
        guard width > 0, height > 0, bytesPerRow >= width * 4, rgba.count >= bytesPerRow * height else { return 0 }
        var sum = 0.0
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4
                sum += 0.2126 * Double(rgba[p]) + 0.7152 * Double(rgba[p + 1]) + 0.0722 * Double(rgba[p + 2])
            }
        }
        return sum / Double(width * height) / 255
    }

    public static func isBlack(_ meanLuminance: Double, threshold: Double = blackThreshold) -> Bool {
        meanLuminance < threshold
    }

    public static func isBlack(png url: URL, threshold: Double = blackThreshold) throws -> Bool {
        isBlack(try meanLuminance(ofPNG: url), threshold: threshold)
    }
}

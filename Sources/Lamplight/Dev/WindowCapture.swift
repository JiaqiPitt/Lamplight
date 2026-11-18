import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Developer aid: saves a picture of one of this app's own windows, so the real interface
/// can be checked from the command line (`--capture <file> --capture-at <seconds>`).
/// It is not used in normal running.
enum WindowCapture {
    static func save(_ window: NSWindow, to url: URL) -> Bool {
        // The window-list capture call is no longer exposed to Swift, but it is still the one
        // way to photograph our own window (SpriteKit's Metal layer included) without asking
        // for screen-recording permission. Look it up at run time.
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return false }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        guard let image = create(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming)?.takeRetainedValue(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}

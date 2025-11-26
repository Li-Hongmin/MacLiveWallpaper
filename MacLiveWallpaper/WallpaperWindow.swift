import Cocoa

class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        // Create a borderless window that covers the specified screen
        let screenRect = screen.frame

        super.init(
            contentRect: screenRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Critical settings for "Wallpaper" behavior
        self.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true // Let clicks pass through to desktop icons

        // Ensure it resizes with the screen
        self.contentView?.autoresizingMask = [.width, .height]

        // Position the window on the correct screen
        self.setFrameOrigin(screenRect.origin)
        self.setFrame(screenRect, display: true)
    }
}

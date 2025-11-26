import Cocoa
import ServiceManagement

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    static func main() {
        // Set up uncaught exception handler
        NSSetUncaughtExceptionHandler { exception in
            print("UNCAUGHT EXCEPTION: \(exception.name)")
            print("Reason: \(exception.reason ?? "unknown")")
            print("Call stack:\n\(exception.callStackSymbols.joined(separator: "\n"))")
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
    var windows: [WallpaperWindow] = []
    var playerViews: [VideoPlayerView] = []
    var statusItem: NSStatusItem!
    var currentVideo: VideoAsset?
    var aboutWindow: NSWindow?
    private var screenChangeWorkItem: DispatchWorkItem?
    private var refreshTimer: Timer?

    var launchAtLogin: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "LaunchAtLogin")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "LaunchAtLogin")
            updateLaunchAtLogin(newValue)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup Menu Bar first
        setupMenuBar()

        // Create windows for all screens
        createWindows()

        // Observe screen configuration changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Listen for playback failures to auto-recover
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoPlaybackFailed),
            name: .videoPlaybackFailed,
            object: nil
        )

        // Refresh players every 10 minutes to prevent memory accumulation
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.refreshVideoPlayers()
        }

        // Try to resume last played video, otherwise play random
        if let lastVideo = VideoManager.shared.getLastPlayedVideo() {
            playVideo(video: lastVideo)
        } else {
            playRandomVideo()
        }
    }

    func createWindows() {
        // For initial creation, use the internal method directly
        recreateWindowsInternal()
    }

    @objc func screenConfigurationChanged() {
        // Cancel any pending recreation (debounce)
        screenChangeWorkItem?.cancel()

        // Pause all players immediately to prevent crashes during transition
        for playerView in playerViews {
            playerView.pause()
        }

        // Debounce: wait 1.0s before recreating windows (longer delay for stability)
        let workItem = DispatchWorkItem { [weak self] in
            self?.safeCreateWindows()
        }
        screenChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func safeCreateWindows() {
        // Double-check we're on main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.safeCreateWindows()
            }
            return
        }

        // Store current video before cleanup
        let videoToResume = currentVideo

        // Clean up all players first, synchronously
        for playerView in playerViews {
            playerView.cleanup()
        }

        // Small delay to let AVFoundation settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }

            // Now recreate windows
            self.recreateWindowsInternal()

            // Resume video after windows are created
            if let video = videoToResume {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.playVideo(video: video)
                }
            }
        }
    }

    private func recreateWindowsInternal() {
        // Hide and close existing windows
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        playerViews.removeAll()

        // Get all screens
        let screens = NSScreen.screens

        print("Creating windows for \(screens.count) screen(s)")

        // Create a window and player view for each screen
        for (index, screen) in screens.enumerated() {
            print("Creating window \(index + 1) on screen at origin: \(screen.frame.origin)")

            let window = WallpaperWindow(screen: screen)
            guard let contentView = window.contentView else { continue }

            let playerView = VideoPlayerView(frame: contentView.bounds)
            playerView.autoresizingMask = [.width, .height]
            contentView.addSubview(playerView)

            windows.append(window)
            playerViews.append(playerView)

            // Order window after adding to arrays
            window.orderBack(nil)
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Wallpaper")
        }

        updateMenu()
    }

    func updateMenu() {
        guard let statusItem = statusItem else { return }

        let menu = NSMenu()

        // Play/Pause
        let isPlaying = playerViews.first?.isPlaying ?? false
        let playPauseTitle = isPlaying ? "Pause" : "Play"
        menu.addItem(NSMenuItem(title: playPauseTitle, action: #selector(togglePlayPause), keyEquivalent: " "))

        menu.addItem(NSMenuItem.separator())

        // Current Video Info
        if let current = currentVideo {
            let item = NSMenuItem(title: "Playing: \(current.name)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Video Selection Submenu
        let videosMenu = NSMenu()
        let videosItem = NSMenuItem(title: "Select Video", action: nil, keyEquivalent: "")
        videosItem.submenu = videosMenu
        menu.addItem(videosItem)

        let videos = VideoManager.shared.getAllVideos()
        for video in videos {
            let item = NSMenuItem(title: video.name, action: #selector(selectVideo(_:)), keyEquivalent: "")
            item.representedObject = video
            if video.url == currentVideo?.url {
                item.state = .on
            }
            videosMenu.addItem(item)
        }

        // Next Random
        menu.addItem(NSMenuItem(title: "Next Random Wallpaper", action: #selector(playRandomVideo), keyEquivalent: "n"))

        menu.addItem(NSMenuItem.separator())

        // Launch at Login
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = launchAtLogin ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        // Help/About
        menu.addItem(NSMenuItem(title: "About MacLiveWallpaper", action: #selector(showAbout), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func togglePlayPause() {
        let isPlaying = playerViews.first?.isPlaying ?? false
        for playerView in playerViews {
            if isPlaying {
                playerView.pause()
            } else {
                playerView.resume()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.updateMenu()
        }
    }

    @objc func selectVideo(_ sender: NSMenuItem) {
        if let video = sender.representedObject as? VideoAsset {
            playVideo(video: video)
        }
    }

    @objc func playRandomVideo() {
        if let video = VideoManager.shared.getRandomVideo() {
            playVideo(video: video)
        }
    }

    @objc private func handleVideoPlaybackFailed(_ notification: Notification) {
        print("Video playback failed, trying another video")
        // Try playing a different random video
        playRandomVideo()
    }

    private func refreshVideoPlayers() {
        guard let video = currentVideo else { return }
        print("Refreshing video players to prevent memory accumulation")
        for playerView in playerViews {
            playerView.play(url: video.url)
        }
    }

    func playVideo(video: VideoAsset) {
        print("Playing: \(video.name)")
        for playerView in playerViews {
            playerView.play(url: video.url)
        }
        currentVideo = video
        VideoManager.shared.saveLastPlayedVideo(video) // Save state
        updateMenu()
    }

    @objc func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
        updateMenu()
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    print("Launch at login enabled")
                } else {
                    try SMAppService.mainApp.unregister()
                    print("Launch at login disabled")
                }
            } catch {
                print("Failed to update launch at login: \(error)")
            }
        } else {
            print("Launch at login requires macOS 13.0 or later")
        }
    }

    @objc func showAbout() {
        // If window already exists, just bring it to front
        if let window = aboutWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create about window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About MacLiveWallpaper"
        window.center()

        // Get version from bundle
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

        // Create content view
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // App icon (if available)
        let iconView = NSImageView(frame: NSRect(x: 150, y: 200, width: 100, height: 100))
        if let icon = NSImage(named: "AppIcon") {
            iconView.image = icon
        } else {
            iconView.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        }
        contentView.addSubview(iconView)

        // App name
        let nameLabel = NSTextField(labelWithString: "MacLiveWallpaper")
        nameLabel.font = NSFont.boldSystemFont(ofSize: 18)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 50, y: 160, width: 300, height: 25)
        contentView.addSubview(nameLabel)

        // Version
        let versionLabel = NSTextField(labelWithString: "Version \(version) (Build \(build))")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.alignment = .center
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 50, y: 135, width: 300, height: 20)
        contentView.addSubview(versionLabel)

        // Description
        let descLabel = NSTextField(wrappingLabelWithString: "Display macOS Aerial screensavers as live desktop wallpaper on all connected screens.")
        descLabel.font = NSFont.systemFont(ofSize: 13)
        descLabel.alignment = .center
        descLabel.frame = NSRect(x: 50, y: 70, width: 300, height: 60)
        contentView.addSubview(descLabel)

        // Copyright
        let copyrightLabel = NSTextField(labelWithString: "© 2025")
        copyrightLabel.font = NSFont.systemFont(ofSize: 11)
        copyrightLabel.alignment = .center
        copyrightLabel.textColor = .tertiaryLabelColor
        copyrightLabel.frame = NSRect(x: 50, y: 30, width: 300, height: 20)
        contentView.addSubview(copyrightLabel)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        aboutWindow = window

        // Clear reference when window closes
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.aboutWindow = nil
        }
    }
}

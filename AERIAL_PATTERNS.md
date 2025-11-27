# Aerial Screensaver Stability Patterns Analysis

## Key Findings from Aerial Source Code

### 1. Shared Player Architecture

```swift
// Multiple views can share a single AVPlayer instance
static var sharingPlayers: Bool {
    switch PrefsDisplays.viewingMode {
    case .cloned, .mirrored, .spanned:
        return true
    default:
        return false
    }
}

static var sharedViews: [AerialView] = []
static var instanciatedViews: [AerialView] = []

class var sharedPlayer: AVPlayer {
    struct Static {
        static var _player: AVPlayer?
        static var player: AVPlayer {
            if let activePlayer = _player {
                return activePlayer
            }
            _player = AVPlayer()
            return _player!
        }
    }
    return Static.player
}
```

**Benefits:**
- Resource saving (one player for multiple displays)
- Synchronized playback across screens
- Simpler cleanup (only one player to manage)

### 2. Delayed Initialization (Sonoma Workaround)

```swift
// macOS 14+ requires delayed setup due to legacyScreenSaver issues
if #available(macOS 14.0, *) {
    var delay = 0.01
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        self.setup()
    }
} else {
    setup()
}
```

**Key insight:** Don't initialize immediately - let the system settle first.

### 3. Frame Bug Workaround (Catalina+)

```swift
// Store original dimensions
self.originalWidth = frame.width
self.originalHeight = frame.height

// Later, detect and fix corrupted frames
override func viewDidChangeBackingProperties() {
    if self.frame.width < 300 && !isPreview {
        debugLog("Frame size bug, trying to override!")
        self.frame = CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight)
    }
}
```

**Key insight:** System may corrupt frame dimensions - always have a backup.

### 4. Screen Detection Strategy

```swift
// Don't rely solely on init frame - use viewDidMoveToWindow
override func viewDidMoveToWindow() {
    if foundScreen == nil {
        if let thisScreen = self.window?.screen {
            matchScreen(thisScreen: thisScreen)
        }
    }
}

func matchScreen(thisScreen: NSScreen) {
    let screenID = thisScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    foundScreen = DisplayDetection.sharedInstance.findScreenWith(id: screenID)
    if let foundScreen = foundScreen {
        foundFrame = foundScreen.bottomLeftFrame
        if #available(macOS 14, *) {
            self.frame = foundFrame!
        }
    }
}
```

**Key insight:** Screen assignment may happen late - be prepared to handle it dynamically.

### 5. Proper Cleanup Sequence

```swift
override func stopAnimation() {
    wasStopped = true

    if !isDisabled {
        player?.pause()
        player?.rate = 0
        layerManager.removeAllLayers()
        playerLayer.removeAllAnimations()
        player?.replaceCurrentItem(with: nil)  // Critical: clear the item
        isDisabled = true
    }

    // Restore brightness
    if let brightnessToRestore = brightnessToRestore {
        Brightness.set(level: brightnessToRestore)
    }

    teardown()
}

func teardown() {
    clearNotifications()
    clearAllLayerAnimations()

    // Remove from player tracking
    if let player = player {
        if let index = AerialView.players.firstIndex(of: player) {
            AerialView.players.remove(at: index)
        }
    }

    VideoManager.sharedInstance.cancelAll()
}
```

**Key cleanup order:**
1. Pause player
2. Set rate to 0
3. Remove layers
4. Remove animations
5. Replace current item with nil
6. Clear notifications
7. Remove from tracking arrays

### 6. Sleep/Wake Handling (Sonoma)

```swift
@objc func onSleepNote(note: Notification) {
    if !Aerial.helper.underCompanion {
        if #available(macOS 14.0, *) {
            exit(0)  // Simply exit on sleep under Sonoma
        }
    }
}

@objc func willStop(_ aNotification: Notification) {
    if !Aerial.helper.underCompanion {
        player?.pause()

        if #available(macOS 14.0, *) {
            // Delayed exit to allow cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                exit(0)
            }
        }
        self.stopAnimation()
    }
}
```

**Key insight:** On modern macOS, sometimes it's better to exit and restart fresh rather than try to recover.

### 7. Error Recovery

```swift
@objc func playerItemFailedtoPlayToEnd(_ aNotification: Notification) {
    playNextVideo()  // Simply try next video on failure
}

@objc func playerItemPlaybackStalledNotification(_ aNotification: Notification) {
    warnLog("Playback stalled")  // Log but don't crash
}

@objc func playerItemDidReachEnd(_ aNotification: Notification) {
    if shouldLoop {
        // Rewind for seamless loop
        if let playerItem = aNotification.object as? AVPlayerItem {
            playerItem.seek(to: CMTime.zero, completionHandler: nil)
        }
    } else {
        playNextVideo()
    }
}
```

### 8. Player Layer Setup

```swift
func setupPlayerLayer(withPlayer player: AVPlayer) {
    self.layer = CALayer()
    self.wantsLayer = true
    layer.backgroundColor = NSColor.black.cgColor
    layer.needsDisplayOnBoundsChange = true
    layer.frame = self.bounds

    playerLayer = AVPlayerLayer(player: player)
    playerLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
    playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    playerLayer.frame = layer.bounds

    layer.addSublayer(playerLayer)
    layer.contentsScale = self.window?.backingScaleFactor ?? 1.0
    playerLayer.contentsScale = self.window?.backingScaleFactor ?? 1.0
}
```

### 9. Video Switching Pattern

```swift
func playNextVideo() {
    clearAllLayerAnimations()
    clearNotifications()

    // Create NEW player instance
    let player = AVPlayer()
    let oldPlayer = self.player
    self.player = player
    player.isMuted = PrefsAdvanced.muteSound

    self.playerLayer.player = self.player  // Assign new player to existing layer
    self.playerLayer.opacity = shouldFade ? 0 : 1.0

    // Update all shared views
    for view in AerialView.sharedViews {
        view.playerLayer.player = player
    }

    playerLayer.drawsAsynchronously = true

    // ... load new video item
}
```

**Key insight:** Don't destroy the layer - just swap the player.

### 10. View Tracking for Cleanup

```swift
static var sharedViews: [AerialView] = []
static var instanciatedViews: [AerialView] = []

// Track on setup
if AerialView.sharingPlayers {
    AerialView.sharedViews.append(self)
}
AerialView.instanciatedViews.append(self)

// Clean stale views
func cleanupSharedViews() {
    if AerialView.singlePlayerAlreadySetup {
        if let index = AerialView.sharedPlayerIndex {
            if AerialView.instanciatedViews[index].wasStopped {
                AerialView.singlePlayerAlreadySetup = false
                AerialView.sharedPlayerIndex = nil
                AerialView.instanciatedViews = []
                AerialView.sharedViews = []
            }
        }
    }
}
```

---

## Recommendations for MacLiveWallpaper

Based on Aerial's patterns:

1. **Use Shared Player Mode** - One AVPlayer for all screens
2. **Delayed Initialization** - Wait for system to settle before creating player
3. **Store Original Dimensions** - Be ready to fix corrupted frames
4. **Track Screen Assignment** - Use `viewDidMoveToWindow` for late binding
5. **Proper Cleanup Order** - Follow Aerial's cleanup sequence exactly
6. **Exit on Critical Events** - On Sonoma+, exit and restart rather than recover
7. **Swap Players, Not Layers** - Keep AVPlayerLayer, change the player
8. **Track All Views** - Know which views exist for coordinated updates

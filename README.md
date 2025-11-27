# MacLiveWallpaper

Display macOS Aerial screensaver videos as live desktop wallpaper on all connected screens.

<!-- Uncomment when demo video is ready
## Demo

https://github.com/user-attachments/assets/your-video-id-here

*or use:*

![Demo](./assets/demo.gif)
-->

## Features

- 🎬 Uses built-in macOS Aerial videos (no download required)
- 🖥️ Multi-display support with automatic screen detection
- 🔄 Random video shuffle with manual selection
- ⚡ Launch at login option
- 🎮 Menu bar controls (Play/Pause/Next)

## Requirements

- macOS 14.0 (Sonoma) or later
- Aerial videos must be downloaded via System Settings > Wallpaper

## Installation

1. Download the latest release from [Releases](https://github.com/Li-Hongmin/MacLiveWallpaper/releases)
2. Unzip the downloaded file
3. Drag `MacLiveWallpaper.app` to your Applications folder
4. Launch MacLiveWallpaper

On first launch, you may need to right-click the app and select "Open" to bypass Gatekeeper.

## Usage

After launching, MacLiveWallpaper runs in the background with a menu bar icon:

- **Play/Pause** - Control video playback
- **Select Video** - Choose a specific Aerial video
- **Next Random Wallpaper** - Skip to a random video
- **Launch at Login** - Start automatically on login

## How It Works

MacLiveWallpaper accesses the same Aerial videos that macOS uses for its built-in screensaver and wallpaper features. These videos are stored in:

```
/Library/Application Support/com.apple.idleassetsd/Customer/
```

The app creates desktop-level windows on each connected display and plays the videos seamlessly.

## Stability

The app implements:
- State machine pattern for safe video operations
- Display reconfiguration detection (hot-plug, resolution changes)
- Emergency cleanup during system events (sleep/wake, screen changes)
- Automatic recovery from playback failures

## Building from Source

```bash
git clone https://github.com/Li-Hongmin/MacLiveWallpaper.git
cd MacLiveWallpaper
open MacLiveWallpaper.xcodeproj
```

Build and run in Xcode.

## License

MIT License - See LICENSE file for details

## Credits

Inspired by:
- Apple's Aerial screensaver
- [Aerial by John Coates](https://github.com/JohnCoates/Aerial)

## Contributing

Issues and pull requests are welcome!

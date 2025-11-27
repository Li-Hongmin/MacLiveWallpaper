# Assets Directory

## Recording Demo Video

### Option 1: Using macOS Screenshot Tool (Recommended)

1. Press `Cmd + Shift + 5`
2. Select "Record Selected Portion" or "Record Entire Screen"
3. Click "Options" > "Save to" > Choose this folder
4. Record 5-10 seconds of MacLiveWallpaper running
5. Stop recording (click stop button in menu bar)
6. Rename the file to `demo.mov`

### Option 2: Using QuickTime Player

1. Open QuickTime Player
2. File > New Screen Recording
3. Record 5-10 seconds
4. File > Save... to this folder as `demo.mov`

### Converting to Web-Friendly Formats

After recording, convert to multiple formats:

```bash
# Convert to MP4 (for HTML5 video)
ffmpeg -i demo.mov -vcodec h264 -acodec aac -vf "scale=1280:-1" demo.mp4

# Convert to GIF (for README fallback, smaller size)
ffmpeg -i demo.mov -vf "fps=10,scale=800:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" demo.gif

# Or use gifski for better quality GIF
gifski --fps 15 --width 800 --quality 90 -o demo.gif demo.mov
```

### File Placement

After conversion:
- Place `demo.mp4` in this folder
- Place `demo.gif` in this folder (as fallback)
- Original `demo.mov` can be deleted or kept as backup

### Activating the Demo

Uncomment the demo sections in:
- `README.md` (lines 5-13)
- `index.html` (lines 162-169)

Then commit and push:
```bash
git add assets/demo.mp4 assets/demo.gif README.md index.html
git commit -m "Add demo video"
git push origin main
```

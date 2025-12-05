import Cocoa
import SwiftUI

/// Video selector window with grid layout and preview images
class VideoSelectorWindow: NSWindow {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        self.title = "Select Wallpaper Video"
        self.center()
        self.minSize = NSSize(width: 800, height: 600)

        // Create SwiftUI view
        let selectorView = VideoSelectorView()
        let hostingView = NSHostingView(rootView: selectorView)
        self.contentView = hostingView

        // Override close behavior to hide instead
        self.delegate = self
    }
}

// MARK: - Window Delegate

extension VideoSelectorWindow: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Don't actually close, just hide the window
        self.orderOut(nil)
        return false  // Prevent actual close
    }
}

// MARK: - SwiftUI View

struct VideoSelectorView: View {
    @State private var videos: [VideoAsset] = []
    @State private var categories: [Category] = []
    @State private var selectedVideo: VideoAsset?
    @State private var searchText = ""
    @State private var selectedCategoryID: String? = nil

    let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)
    ]

    var body: some View {
        NavigationSplitView {
            // Sidebar with categories
            List(selection: $selectedCategoryID) {
                // All Videos
                NavigationLink(value: "all") {
                    HStack {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("全部视频")
                        Spacer()
                        Text("\(videos.count)")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                Section("分类") {
                    ForEach(categories, id: \.id) { category in
                        NavigationLink(value: category.id) {
                            HStack {
                                Image(systemName: categoryIcon(for: category))
                                Text(category.name)
                                Spacer()
                                Text("\(VideoManager.shared.getVideos(forCategory: category.id).count)")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("分类")
            .frame(minWidth: 220)

        } detail: {
            // Main content: Category videos grid
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索视频...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .padding()

                // Videos grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(currentVideos, id: \.assetID) { video in
                            VideoThumbnailView(
                                video: video,
                                isSelected: selectedVideo?.assetID == video.assetID
                            )
                            .onTapGesture {
                                selectVideo(video)
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(navigationTitle)
        }
        .onAppear {
            loadVideos()
            selectedCategoryID = "all"
        }
    }

    private var currentVideos: [VideoAsset] {
        var videosToDisplay: [VideoAsset]

        if let categoryID = selectedCategoryID {
            if categoryID == "all" {
                videosToDisplay = videos
            } else {
                videosToDisplay = VideoManager.shared.getVideos(forCategory: categoryID)
            }
        } else {
            videosToDisplay = videos
        }

        if searchText.isEmpty {
            return videosToDisplay
        }
        return videosToDisplay.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var navigationTitle: String {
        let count = currentVideos.count
        if let categoryID = selectedCategoryID, categoryID != "all" {
            let category = categories.first { $0.id == categoryID }
            return "\(category?.name ?? "分类") (\(count))"
        }
        return "全部视频 (\(count))"
    }

    private func loadVideos() {
        videos = VideoManager.shared.getAllVideos()
        categories = VideoManager.shared.getCategories()
    }

    private func selectVideo(_ video: VideoAsset) {
        selectedVideo = video
        // Notify AppDelegate to play the video
        NotificationCenter.default.post(
            name: NSNotification.Name("VideoSelected"),
            object: video
        )
    }

    private func categoryIcon(for category: Category) -> String {
        let key = category.localizedNameKey.lowercased()
        if key.contains("landscape") {
            return "mountain.2.fill"
        } else if key.contains("cities") || key.contains("urban") {
            return "building.2.fill"
        } else if key.contains("underwater") || key.contains("ocean") {
            return "drop.fill"
        } else if key.contains("space") {
            return "globe.americas.fill"
        }
        return "folder.fill"
    }
}


// MARK: - Video Thumbnail View

struct VideoThumbnailView: View {
    let video: VideoAsset
    let isSelected: Bool
    @State private var previewImage: NSImage?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail
            ZStack {
                if let image = previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(height: 120)
                        .clipped()
                        .cornerRadius(8)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(height: 120)
                        .cornerRadius(8)
                        .overlay {
                            if isLoading {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary)
                            }
                        }
                }

                // Selection indicator
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 3)
                }

                // Streaming badge
                if video.isStreaming {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "network")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(6)
                                .padding(8)
                        }
                        Spacer()
                    }
                }
            }

            // Video name
            Text(video.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 200)
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(12)
        .onAppear {
            loadPreviewImage()
        }
    }

    private func loadPreviewImage() {
        // Use previewImageURL from VideoAsset directly
        guard let imageURL = video.previewImageURL else {
            Task { @MainActor in
                self.isLoading = false
            }
            return
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                await MainActor.run {
                    self.previewImage = NSImage(data: data)
                    self.isLoading = false
                }
            } catch {
                print("Failed to load preview image for \(video.name): \(error)")
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
}

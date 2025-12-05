import Foundation

struct VideoAsset {
    let url: URL
    let name: String
    let isStreaming: Bool  // true for online streaming, false for local file
    let previewImageURL: URL?  // Preview thumbnail URL
    let categories: [String]  // Category IDs this video belongs to
    let assetID: String  // Unique asset ID
}

struct Category {
    let id: String
    let name: String
    let localizedNameKey: String
}

class VideoManager {
    static let shared = VideoManager()

    private let systemSearchPath = "/Library/Application Support/com.apple.idleassetsd/Customer"
    private var videoNames: [String: String] = [:]
    private var cachedVideos: [VideoAsset]?
    private var categories: [Category] = []
    private var categoryNames: [String: String] = [:]  // Category ID -> Localized Name

    // Sandbox-friendly: Try bundle resources first, fallback to system path
    private var resourcePath: String {
        // First try: Bundle resources (sandbox-friendly for App Store)
        if let bundleResourcePath = Bundle.main.resourcePath?.appending("/Resources"),
           FileManager.default.fileExists(atPath: bundleResourcePath + "/entries.json") {
            print("Using bundled resources (sandbox mode)")
            return bundleResourcePath
        }
        // Fallback: System path (for development/local installations)
        print("Using system resources (development mode)")
        return systemSearchPath
    }

    init() {
        loadMetadata()
    }

    func invalidateCache() {
        cachedVideos = nil
    }

    private func loadMetadata() {
        // 1. Load video names from video_names.json (extracted from entries.json)
        let videoNamesURL = URL(fileURLWithPath: resourcePath).appendingPathComponent("video_names.json")
        if let data = try? Data(contentsOf: videoNamesURL),
           let names = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            videoNames = names
            print("Loaded \(names.count) video names")
        }

        // 2. Load category names from category_names.json
        let categoryNamesURL = URL(fileURLWithPath: resourcePath).appendingPathComponent("category_names.json")
        if let data = try? Data(contentsOf: categoryNamesURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {

            for (id, info) in json {
                let name = info["name"] ?? id
                categoryNames[id] = name
                categories.append(Category(id: id, name: name, localizedNameKey: name))
            }
            print("Loaded \(categories.count) categories")
        }
    }

    func getAllVideos() -> [VideoAsset] {
        // Return cached videos if available
        if let cached = cachedVideos {
            return cached
        }

        var videos: [VideoAsset] = []

        // First, try to load from entries.json for streaming URLs
        let entriesURL = URL(fileURLWithPath: resourcePath).appendingPathComponent("entries.json")
        if let data = try? Data(contentsOf: entriesURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let assets = json["assets"] as? [[String: Any]] {

            for asset in assets {
                // Get the asset ID and name
                guard let id = asset["id"] as? String else { continue }
                let name = videoNames[id] ?? (asset["accessibilityLabel"] as? String) ?? id

                // Try different quality URLs in order of preference
                let urlKeys = ["url-4K-SDR-240FPS", "url-4K-SDR", "url-1080-SDR"]
                var videoURL: URL?

                for urlKey in urlKeys {
                    if let urlString = asset[urlKey] as? String,
                       let url = URL(string: urlString) {
                        videoURL = url
                        break
                    }
                }

                // Get preview image URL
                var previewURL: URL? = nil
                if let previewString = asset["previewImage"] as? String {
                    previewURL = URL(string: previewString)
                }

                // Get categories
                let assetCategories = asset["categories"] as? [String] ?? []

                if let url = videoURL {
                    videos.append(VideoAsset(
                        url: url,
                        name: name,
                        isStreaming: true,
                        previewImageURL: previewURL,
                        categories: assetCategories,
                        assetID: id
                    ))
                }
            }
        }

        // If no streaming videos found, fallback to local files (backwards compatibility)
        if videos.isEmpty {
            let fileManager = FileManager.default
            let url = URL(fileURLWithPath: resourcePath)

            if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == "mov" {
                        // Check file size - skip files smaller than 1MB (likely incomplete)
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                           let size = attrs[.size] as? Int64,
                           size > 1_000_000 {
                            // Extract UUID from filename (remove extension)
                            let uuid = fileURL.deletingPathExtension().lastPathComponent
                            let name = videoNames[uuid] ?? uuid // Fallback to UUID if no name found
                            videos.append(VideoAsset(
                                url: fileURL,
                                name: name,
                                isStreaming: false,
                                previewImageURL: nil,
                                categories: [],
                                assetID: uuid
                            ))
                        }
                    }
                }
            }
        }

        // Sort by name for better menu
        let sortedVideos = videos.sorted { $0.name < $1.name }
        cachedVideos = sortedVideos
        print("Loaded \(sortedVideos.count) videos (\(sortedVideos.filter { $0.isStreaming }.count) streaming)")
        return sortedVideos
    }

    func getRandomVideo() -> VideoAsset? {
        return getAllVideos().randomElement()
    }

    func getCategories() -> [Category] {
        return categories
    }

    func getVideos(forCategory categoryID: String) -> [VideoAsset] {
        return getAllVideos().filter { $0.categories.contains(categoryID) }
    }

    // MARK: - Persistence

    private let lastPlayedVideoKey = "LastPlayedVideoURL"

    func saveLastPlayedVideo(_ video: VideoAsset) {
        UserDefaults.standard.set(video.url.path, forKey: lastPlayedVideoKey)
    }

    func getLastPlayedVideo() -> VideoAsset? {
        guard let path = UserDefaults.standard.string(forKey: lastPlayedVideoKey) else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        let videos = getAllVideos()

        // Find the video asset that matches the saved URL
        return videos.first { $0.url.path == url.path }
    }
}

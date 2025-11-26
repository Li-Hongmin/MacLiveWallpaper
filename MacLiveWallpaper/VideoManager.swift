import Foundation

struct VideoAsset {
    let url: URL
    let name: String
}

class VideoManager {
    static let shared = VideoManager()

    private let baseSearchPath = "/Library/Application Support/com.apple.idleassetsd/Customer"
    private var videoNames: [String: String] = [:]
    private var cachedVideos: [VideoAsset]?

    init() {
        loadMetadata()
    }

    func invalidateCache() {
        cachedVideos = nil
    }

    private func loadMetadata() {
        // 1. Load entries.json to map UUID -> Localization Key
        let entriesURL = URL(fileURLWithPath: baseSearchPath).appendingPathComponent("entries.json")
        guard let data = try? Data(contentsOf: entriesURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            print("Failed to load entries.json")
            return
        }

        var uuidToKey: [String: String] = [:]
        for asset in assets {
            if let id = asset["id"] as? String,
               let key = asset["localizedNameKey"] as? String {
                uuidToKey[id] = key
            }
        }

        // 2. Load TVIdleScreenStrings.bundle
        let bundlePath = URL(fileURLWithPath: baseSearchPath).appendingPathComponent("TVIdleScreenStrings.bundle")
        guard let bundle = Bundle(url: bundlePath) else {
            print("Failed to load bundle at \(bundlePath.path)")
            return
        }

        // 3. Determine the best matching language
        // We explicitly check preferredLanguages against the bundle's available localizations
        let bestLanguage = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages).first

        // If we found a match, try to load that specific localization
        var localizedBundle = bundle
        if let language = bestLanguage,
           let path = bundle.path(forResource: language, ofType: "lproj"),
           let specificBundle = Bundle(path: path) {
            localizedBundle = specificBundle
        }

        // 4. Map UUID -> Real Name
        for (uuid, key) in uuidToKey {
            // Now we use the specific localized bundle
            let name = localizedBundle.localizedString(forKey: key, value: nil, table: "Localizable.nocache")
            videoNames[uuid] = name
        }
    }

    func getAllVideos() -> [VideoAsset] {
        // Return cached videos if available
        if let cached = cachedVideos {
            return cached
        }

        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: baseSearchPath)
        var videos: [VideoAsset] = []

        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "mov" {
                // Check file size - skip files smaller than 1MB (likely incomplete)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let size = attrs[.size] as? Int64,
                   size > 1_000_000 {
                    // Extract UUID from filename (remove extension)
                    let uuid = fileURL.deletingPathExtension().lastPathComponent
                    let name = videoNames[uuid] ?? uuid // Fallback to UUID if no name found
                    videos.append(VideoAsset(url: fileURL, name: name))
                }
            }
        }

        // Sort by name for better menu
        let sortedVideos = videos.sorted { $0.name < $1.name }
        cachedVideos = sortedVideos
        return sortedVideos
    }

    func getRandomVideo() -> VideoAsset? {
        return getAllVideos().randomElement()
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

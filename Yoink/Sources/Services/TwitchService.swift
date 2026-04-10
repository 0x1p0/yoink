import Foundation
import AppKit

// MARK: - Twitch-specific models

struct TwitchVODInfo {
    let id: String
    let title: String
    let streamer: String
    let durationSeconds: Int
    let thumbnailURL: String
    let viewCount: Int
    let recordedAt: String
    let game: String

    var durationHHMMSS: String { durationSeconds.toHHMMSS }
    var durationH: String { String(format: "%02d", durationSeconds / 3600) }
    var durationM: String { String(format: "%02d", (durationSeconds % 3600) / 60) }
    var durationS: String { String(format: "%02d", durationSeconds % 60) }
}

struct TwitchClipInfo {
    let slug: String
    let title: String
    let streamer: String
    let durationSeconds: Int
    let thumbnailURL: String
    let viewCount: Int
    let createdAt: String
    let game: String
}

struct TwitchQuality: Identifiable, Hashable {
    let id: String          // e.g. "1080p60", "Source", "720p30"
    let resolution: String  // e.g. "1920x1080"
    let frameRate: Double
    let bandwidth: Int

    var displayName: String {
        if id == "Source" || id == "chunked" { return "Source (best)" }
        return id
    }

    // The format string to pass to yt-dlp -f
    var ytdlpFormat: String {
        if id == "Source" || id == "chunked" {
            return "bestvideo+bestaudio/best"
        }
        // yt-dlp names Twitch HLS formats like "hls-1080p60"
        return "hls-\(id)+bestaudio/bestvideo+bestaudio/best"
    }
}

// MARK: - Twitch Service

final class TwitchService {
    static let shared = TwitchService()
    private init() {}

    private let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    private let gqlURL   = URL(string: "https://gql.twitch.tv/gql")!

    // MARK: - URL parsing

    /// Returns VOD ID from bare number or full URL. Returns nil if not a VOD URL.
    func parseVODId(from input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // bare numeric id
        if s.allSatisfy({ $0.isNumber }), s.count >= 5 { return s }
        // twitch.tv/videos/1234567890
        if let m = s.range(of: #"twitch\.tv/videos?/(\d+)"#, options: .regularExpression) {
            return String(s[m]).components(separatedBy: "/").last?.filter(\.isNumber)
        }
        return nil
    }

    /// Returns clip slug from URL or bare slug.
    func parseClipSlug(from input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // clips.twitch.tv/SlugHere
        if let m = s.range(of: #"clips\.twitch\.tv/([A-Za-z0-9_\-]+)"#, options: .regularExpression) {
            return String(s[m]).components(separatedBy: "/").last
        }
        // twitch.tv/streamer/clip/SlugHere
        if let m = s.range(of: #"/clip/([A-Za-z0-9_\-]+)"#, options: .regularExpression) {
            return String(s[m]).components(separatedBy: "/").last
        }
        // bare slug (letters, numbers, hyphens, no slashes, min 5 chars)
        if !s.contains("/"), s.count >= 5,
           s.range(of: #"^[A-Za-z][A-Za-z0-9_\-]+$"#, options: .regularExpression) != nil {
            return s
        }
        return nil
    }

    /// Returns true if the URL is a Twitch VOD or clip
    func isTwitchURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("twitch.tv") || lower.contains("clips.twitch.tv")
    }

    // MARK: - VOD metadata

    func fetchVODInfo(id: String) async throws -> TwitchVODInfo {
        let body: [String: Any] = ["query": """
            query {
                video(id: "\(id)") {
                    id title lengthSeconds publishedAt viewCount
                    thumbnailURLs(width: 640, height: 360)
                    owner { displayName }
                    game { name }
                }
            }
            """]
        let data = try await gqlRequest(body)
        guard
            let video = (data["data"] as? [String: Any])?["video"] as? [String: Any],
            let title = video["title"] as? String,
            let secs  = video["lengthSeconds"] as? Int,
            let owner = (video["owner"] as? [String: Any])?["displayName"] as? String
        else { throw TwitchError.notFound("VOD \(id) not found or is subscriber-only") }

        let thumb = (video["thumbnailURLs"] as? [String])?.first ?? ""
        let game  = (video["game"] as? [String: Any])?["name"] as? String ?? ""

        return TwitchVODInfo(
            id: id, title: title, streamer: owner,
            durationSeconds: secs, thumbnailURL: thumb,
            viewCount: video["viewCount"] as? Int ?? 0,
            recordedAt: video["publishedAt"] as? String ?? "",
            game: game
        )
    }

    // MARK: - Clip metadata

    func fetchClipInfo(slug: String) async throws -> TwitchClipInfo {
        let body: [String: Any] = ["query": """
            query {
                clip(slug: "\(slug)") {
                    id slug title createdAt viewCount thumbnailURL
                    durationSeconds
                    broadcaster { displayName }
                    game { name }
                }
            }
            """]
        let data = try await gqlRequest(body)
        guard
            let clip  = (data["data"] as? [String: Any])?["clip"] as? [String: Any],
            let title = clip["title"] as? String,
            let bc    = (clip["broadcaster"] as? [String: Any])?["displayName"] as? String
        else { throw TwitchError.notFound("Clip '\(slug)' not found") }

        let rawDur = clip["durationSeconds"]
        let dur: Int
        if let d = rawDur as? Int         { dur = d }
        else if let d = rawDur as? Double { dur = Int(d) }
        else                               { dur = 0 }

        return TwitchClipInfo(
            slug: slug, title: title, streamer: bc,
            durationSeconds: dur,
            thumbnailURL: clip["thumbnailURL"] as? String ?? "",
            viewCount: clip["viewCount"] as? Int ?? 0,
            createdAt: clip["createdAt"] as? String ?? "",
            game: (clip["game"] as? [String: Any])?["name"] as? String ?? ""
        )
    }

    // MARK: - Real quality list (from the actual M3U8 playlist)

    /// Fetches available qualities for a VOD by getting an access token then parsing the M3U8.
    /// Returns real quality names like "1080p60", "720p30", "Source" - not yt-dlp's internal IDs.
    /// Result of a VOD quality fetch - carries auth state alongside the quality list.
    enum VODQualityResult {
        case ok([TwitchQuality])
        case requiresAuth          // token came back but source is login-gated
    }

    func fetchVODQualities(id: String) async -> [TwitchQuality] {
        switch await fetchVODQualitiesWithAuthCheck(id: id) {
        case .ok(let q):    return q
        case .requiresAuth: return TwitchQuality.defaults
        }
    }

    /// Like fetchVODQualities but surfaces auth failures so callers can show the banner.
    func fetchVODQualitiesWithAuthCheck(id: String) async -> VODQualityResult {
        // Step 1: Get signed access token from GQL
        let tokenBody: [String: Any] = ["query": """
            query {
                videoPlaybackAccessToken(
                    id: "\(id)",
                    params: {
                        platform: "web"
                        playerBackend: "mediaplayer"
                        playerType: "site"
                    }
                ) { value signature }
            }
            """]

        guard
            let tokenData = try? await gqlRequest(tokenBody),
            let token = ((tokenData["data"] as? [String: Any])?["videoPlaybackAccessToken"]) as? [String: Any],
            let sig   = token["signature"] as? String,
            let value = token["value"] as? String,
            let encValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return .ok(TwitchQuality.defaults) }

        if let tokenValueData = value.data(using: .utf8),
           let tokenJSON = try? JSONSerialization.jsonObject(with: tokenValueData) as? [String: Any],
           let chansub = tokenJSON["chansub"] as? [String: Any],
           let restricted = chansub["restricted_bitrates"] as? [String],
           restricted.contains("chunked") || restricted.contains("audio_only") && restricted.count > 1 {
            return .requiresAuth
        }

        // Step 3: Fetch master M3U8 from Twitch's Usher CDN
        let usherStr = "https://usher.twitchapps.com/vod/\(id)?sig=\(sig)&token=\(encValue)&allow_source=true&allow_spectre=true"
        guard let usherURL = URL(string: usherStr),
              let (data, _) = try? await URLSession.shared.data(from: usherURL),
              let m3u8 = String(data: data, encoding: .utf8)
        else { return .ok(TwitchQuality.defaults) }

        return .ok(parseM3U8Qualities(m3u8))
    }

    func fetchFragmentCount(id: String, quality: TwitchQuality) async -> Int? {
        // Get access token
        let tokenBody: [String: Any] = ["query": """
            query {
                videoPlaybackAccessToken(
                    id: "\(id)",
                    params: { platform: "web" playerBackend: "mediaplayer" playerType: "site" }
                ) { value signature }
            }
            """]
        guard
            let tokenData = try? await gqlRequest(tokenBody),
            let token = ((tokenData["data"] as? [String: Any])?["videoPlaybackAccessToken"]) as? [String: Any],
            let sig   = token["signature"] as? String,
            let value = token["value"] as? String,
            let encValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }

        let usherStr = "https://usher.twitchapps.com/vod/\(id)?sig=\(sig)&token=\(encValue)&allow_source=true"
        guard let usherURL = URL(string: usherStr),
              let (data, _) = try? await URLSession.shared.data(from: usherURL),
              let masterM3u8 = String(data: data, encoding: .utf8)
        else { return nil }

        // Find the stream URL for the chosen quality
        let lines = masterM3u8.components(separatedBy: "\n")
        var targetStreamURL: String? = nil
        for (i, line) in lines.enumerated() {
            if line.contains("NAME=\"\(quality.id)\"") || line.contains("NAME=\"chunked\"") && quality.id == "Source" {
                for j in (i+1)..<lines.count {
                    let l = lines[j].trimmingCharacters(in: .whitespaces)
                    if !l.isEmpty && !l.hasPrefix("#") {
                        targetStreamURL = l
                        break
                    }
                }
                if targetStreamURL != nil { break }
            }
        }

        guard let streamURL = targetStreamURL, let url = URL(string: streamURL),
              let (streamData, _) = try? await URLSession.shared.data(from: url),
              let streamM3u8 = String(data: streamData, encoding: .utf8)
        else { return nil }

        // Count #EXTINF entries = number of segments/fragments
        let count = streamM3u8.components(separatedBy: "\n").filter { $0.hasPrefix("#EXTINF") }.count
        return count > 0 ? count : nil
    }

    // MARK: - Thumbnail

    func fetchThumbnail(url: String) async -> NSImage? {
        guard !url.isEmpty, let u = URL(string: url),
              let (data, _) = try? await URLSession.shared.data(from: u)
        else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Private: M3U8 parser

    private func parseM3U8Qualities(_ m3u8: String) -> [TwitchQuality] {
        var qualities: [TwitchQuality] = []
        let lines = m3u8.components(separatedBy: "\n")

        for (i, line) in lines.enumerated() {
            guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }

            // Parse bandwidth
            let bandwidth = extractInt(from: line, key: "BANDWIDTH") ?? 0

            // Parse resolution e.g. RESOLUTION=1920x1080
            let resolution = extractValue(from: line, key: "RESOLUTION") ?? ""

            // Parse frame rate
            let fps = extractDouble(from: line, key: "FRAME-RATE") ?? 30.0

            // Find the associated #EXT-X-MEDIA line to get the NAME
            // The NAME attribute is on the #EXT-X-MEDIA line with the same GROUP-ID
            let groupId = extractValue(from: line, key: "VIDEO") ?? extractValue(from: line, key: "AUDIO") ?? ""

            // Try to find name from a preceding #EXT-X-MEDIA
            var name = ""
            for mediaLine in lines where mediaLine.hasPrefix("#EXT-X-MEDIA") {
                if mediaLine.contains("GROUP-ID=\"\(groupId)\"") || mediaLine.contains("GROUP-ID=\(groupId)") {
                    name = extractValue(from: mediaLine, key: "NAME") ?? ""
                    break
                }
            }

            // If we still don't have a name, derive from resolution
            if name.isEmpty || name == "chunked" {
                name = name == "chunked" ? "Source" : deriveQualityName(resolution: resolution, fps: fps)
            }

            // Skip duplicate "chunked" entries - they're just Source
            let displayId = name == "chunked" ? "Source" : name
            guard !qualities.contains(where: { $0.id == displayId }) else { continue }

            qualities.append(TwitchQuality(
                id: displayId,
                resolution: resolution,
                frameRate: fps,
                bandwidth: bandwidth
            ))
        }

        // Sort: Source first, then by resolution descending
        qualities.sort { a, b in
            if a.id == "Source" { return true }
            if b.id == "Source" { return false }
            let aH = a.resolution.components(separatedBy: "x").last.flatMap(Int.init) ?? 0
            let bH = b.resolution.components(separatedBy: "x").last.flatMap(Int.init) ?? 0
            if aH != bH { return aH > bH }
            return a.frameRate > b.frameRate
        }

        return qualities.isEmpty ? TwitchQuality.defaults : qualities
    }

    private func extractValue(from line: String, key: String) -> String? {
        let pattern = "\(key)=\"([^\"]+)\""
        if let m = line.range(of: pattern, options: .regularExpression) {
            return String(line[m])
                .replacingOccurrences(of: "\(key)=\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
        }
        // Without quotes
        let pattern2 = "\(key)=([^,\\s\"]+)"
        if let m = line.range(of: pattern2, options: .regularExpression) {
            return String(line[m]).replacingOccurrences(of: "\(key)=", with: "")
        }
        return nil
    }

    private func extractInt(from line: String, key: String) -> Int? {
        extractValue(from: line, key: key).flatMap(Int.init)
    }

    private func extractDouble(from line: String, key: String) -> Double? {
        extractValue(from: line, key: key).flatMap(Double.init)
    }

    private func deriveQualityName(resolution: String, fps: Double) -> String {
        let height = resolution.components(separatedBy: "x").last.flatMap(Int.init) ?? 0
        if height == 0 { return "Unknown" }
        let fpsInt = Int(fps.rounded())
        return fpsInt > 30 ? "\(height)p\(fpsInt)" : "\(height)p"
    }

    // MARK: - Private: GQL

    private func gqlRequest(_ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: gqlURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(clientID, forHTTPHeaderField: "Client-ID")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw TwitchError.httpError }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw TwitchError.parseError }
        return json
    }
}

// MARK: - Defaults + Error

extension TwitchQuality {
    static let defaults: [TwitchQuality] = [
        TwitchQuality(id: "Source",  resolution: "",          frameRate: 60, bandwidth: 0),
        TwitchQuality(id: "1080p60", resolution: "1920x1080", frameRate: 60, bandwidth: 0),
        TwitchQuality(id: "720p60",  resolution: "1280x720",  frameRate: 60, bandwidth: 0),
        TwitchQuality(id: "720p30",  resolution: "1280x720",  frameRate: 30, bandwidth: 0),
        TwitchQuality(id: "480p30",  resolution: "852x480",   frameRate: 30, bandwidth: 0),
        TwitchQuality(id: "360p30",  resolution: "640x360",   frameRate: 30, bandwidth: 0),
        TwitchQuality(id: "160p30",  resolution: "284x160",   frameRate: 30, bandwidth: 0),
    ]
}

enum TwitchError: LocalizedError {
    case notFound(String), httpError, parseError
    var errorDescription: String? {
        switch self {
        case .notFound(let m): return m
        case .httpError:       return "Twitch API returned an error"
        case .parseError:      return "Failed to parse Twitch response"
        }
    }
}

// MARK: - Int duration helper

extension Int {
    var toHHMMSS: String {
        String(format: "%02d:%02d:%02d", self / 3600, (self % 3600) / 60, self % 60)
    }
}

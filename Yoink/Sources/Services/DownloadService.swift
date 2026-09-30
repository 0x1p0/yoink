import Foundation
import SwiftUI
import UserNotifications

// MARK: - Download Service

@MainActor
final class DownloadService: ObservableObject {
    static let shared = DownloadService()
    private init() {}

    // MARK: - URL Support Pre-check

    /// Cache of supported yt-dlp extractor host patterns, loaded once on first call.
    private var supportedExtractorPatterns: Set<String> = []
    private var extractorPatternsLoaded = false

    /// Call once at app launch to load extractor patterns in background before first paste.
    func preWarmExtractorPatterns() async {
        guard !extractorPatternsLoaded else { return }
        await loadExtractorPatterns()
    }

    /// Quick check: is this URL likely supported by yt-dlp?
    /// Uses a cached list of extractor URL patterns; falls back to true (optimistic) if cache is empty.
    func isSupportedURL(_ urlString: String) async -> Bool {
        guard let host = URLComponents(string: urlString)?.host?.lowercased() else { return false }
        if !extractorPatternsLoaded { await loadExtractorPatterns() }
        if supportedExtractorPatterns.isEmpty { return true }
        let normalizedHost = host == "youtu.be" ? "youtube" : host
        return supportedExtractorPatterns.contains(where: { normalizedHost.contains($0) })
    }

    /// Returns true for soop.tv / afreecatv.com VOD URLs.
    /// These are multi-part single VODs — yt-dlp outputs one JSON per part,
    /// making n_entries > 1, but they are NOT user-selectable playlists.
    static func isSoopOrAfreecaURL(_ urlString: String) -> Bool {
        guard let host = URLComponents(string: urlString)?.host?.lowercased() else { return false }
        return host.contains("sooptv.com") || host.contains("afreecatv.com")
    }

    private func loadExtractorPatterns() async {
        extractorPatternsLoaded = true
        guard let path = await DependencyService.shared.resolvePath(for: "yt-dlp") else { return }
        let patterns: Set<String> = await Task.detached(priority: .background) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["--list-extractors"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError  = Pipe()
            guard (try? proc.run()) != nil else { return [] }
            proc.waitUntilExit()
            guard let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return [] }
            return Set(
                text.components(separatedBy: .newlines)
                    .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("_") }
                    .map { $0.components(separatedBy: ":").first ?? $0 }
            )
        }.value
        self.supportedExtractorPatterns = patterns
    }

    // MARK: Metadata fetch (title + thumbnail + duration + subs)

    /// Public wrapper - fetches metadata for an arbitrary URL and returns the result.
    func fetchMeta(url: String, authArgs: [String]) async -> Result<VideoMeta, Error> {
        guard let ytdlpPath = await DependencyService.shared.resolvePath(for: "yt-dlp") else {
            return .failure(NSError(domain: "yoink", code: 1, userInfo: [NSLocalizedDescriptionKey: "yt-dlp not found"]))
        }
        return await runMetadataFetch(url: url, ytdlpPath: ytdlpPath, authArgs: authArgs)
    }

    func fetchMetadata(for job: DownloadJob) {
        guard job.hasURL else { return }

        job.metaFetchTask?.cancel()
        job.metaState = .fetching
        job.meta = nil
        job.thumbnailLoaded = false
        job.endH = ""; job.endM = ""; job.endS = ""

        let url        = job.url
        let hasCookies = job.hasCookies
        let authArgs   = cookieArgs(for: job)

        // ── Twitch fast-path: hit GQL directly instead of yt-dlp --dump-json ──
        let twitch = TwitchService.shared
        if twitch.isTwitchURL(url) {
            job.isTwitchURL = true
            let task = Task.detached(priority: .userInitiated) {
                if let vodId = twitch.parseVODId(from: url) {
                    await self.fetchTwitchVODMeta(job: job, vodId: vodId)
                } else if let slug = twitch.parseClipSlug(from: url) {
                    await self.fetchTwitchClipMeta(job: job, slug: slug)
                } else {
                    // Twitch channel or unknown - fall through to yt-dlp
                    await MainActor.run { job.isTwitchURL = false }
                    await self.fetchMetadataViaYtdlp(job: job, url: url, hasCookies: hasCookies, authArgs: authArgs)
                }
            }
            job.metaFetchTask = task
            return
        }

        // ── Non-Twitch: normal yt-dlp path ────────────────────────────────────
        job.isTwitchURL = false
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.fetchMetadataViaYtdlp(job: job, url: url, hasCookies: hasCookies, authArgs: authArgs)
        }
        job.metaFetchTask = task
    }

    // MARK: Twitch VOD meta (GQL)

    @MainActor
    private func fetchTwitchVODMeta(job: DownloadJob, vodId: String) async {
        let twitch = TwitchService.shared
        do {
            let info = try await twitch.fetchVODInfo(id: vodId)
            job.twitchVODInfo = info

            // Populate the VideoMeta so the rest of the UI works unchanged
            job.meta = VideoMeta(
                title: info.title, thumbnail: info.thumbnailURL,
                duration: info.durationHHMMSS,
                durationH: info.durationH, durationM: info.durationM, durationS: info.durationS,
                hasSubs: false, chapters: [], availableSubLangs: [],
                videoFormats: [], audioFormats: [], nEntries: 1
            )
            job.endH = info.durationH
            job.endM = info.durationM
            job.endS = info.durationS
            job.metaState = .done

            // Load thumbnail
            if !info.thumbnailURL.isEmpty {
                ThumbnailCache.shared.load(info.thumbnailURL)
            }

            // Fetch real quality list from M3U8 (async, non-blocking).
            // Also checks the token for restricted_bitrates - if source is locked,
            // flip the job to .needsAuth before the user tries to download.
            Task.detached(priority: .background) {
                let result = await twitch.fetchVODQualitiesWithAuthCheck(id: vodId)
                await MainActor.run {
                    switch result {
                    case .requiresAuth:
                        // Token says subscriber-only - show auth banner immediately
                        job.metaState = job.hasCookies ? .needsAuthRetry : .needsAuth
                    case .ok(let quals):
                        job.twitchQualities = quals
                        if job.selectedTwitchQuality == nil {
                            job.selectedTwitchQuality = quals.first
                        }
                    }
                }
                // Pre-fetch fragment count for the selected quality to enable accurate progress
                if case .ok(let quals) = result, let q = quals.first {
                    let count = await twitch.fetchFragmentCount(id: vodId, quality: q)
                    await MainActor.run {
                        if let c = count { job.twitchTotalFragments = c }
                    }
                }
            }
        } catch {
            job.metaState = .idle
        }
    }

    // MARK: Twitch Clip meta (GQL)

    @MainActor
    private func fetchTwitchClipMeta(job: DownloadJob, slug: String) async {
        let twitch = TwitchService.shared
        do {
            let info = try await twitch.fetchClipInfo(slug: slug)
            job.twitchClipInfo = info

            job.meta = VideoMeta(
                title: info.title, thumbnail: info.thumbnailURL,
                duration: info.durationSeconds.toHHMMSS,
                durationH: String(format: "%02d", info.durationSeconds / 3600),
                durationM: String(format: "%02d", (info.durationSeconds % 3600) / 60),
                durationS: String(format: "%02d", info.durationSeconds % 60),
                hasSubs: false, chapters: [], availableSubLangs: [],
                videoFormats: [], audioFormats: [], nEntries: 1
            )
            job.endH = String(format: "%02d", info.durationSeconds / 3600)
            job.endM = String(format: "%02d", (info.durationSeconds % 3600) / 60)
            job.endS = String(format: "%02d", info.durationSeconds % 60)
            job.metaState = .done

            if !info.thumbnailURL.isEmpty { ThumbnailCache.shared.load(info.thumbnailURL) }
        } catch {
            job.metaState = .idle
        }
    }

    // MARK: yt-dlp metadata (non-Twitch or Twitch fallback)

    private func fetchMetadataViaYtdlp(job: DownloadJob, url: String, hasCookies: Bool, authArgs: [String]) async {
        guard !Task.isCancelled else { return }
        guard let ytdlpPath = await DependencyService.shared.resolvePath(for: "yt-dlp") else {
            await MainActor.run { job.metaState = .idle }
            return
        }
        guard !Task.isCancelled else { return }
        let result = await runMetadataFetch(url: url, ytdlpPath: ytdlpPath, authArgs: authArgs)
        cleanupMetaCookies(for: job)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            switch result {
            case .success(let meta):
                if meta.nEntries > 1 && !DownloadService.isSoopOrAfreecaURL(job.url) && meta.isRealPlaylist {
                    job.meta = meta; job.metaState = .done
                    NotificationCenter.default.post(name: .playlistURLDetected, object: job)
                    return
                }
                job.meta = meta
                job.endH = meta.durationH; job.endM = meta.durationM; job.endS = meta.durationS
                job.metaState = .done
            case .failure(let err):
                let msg = err.localizedDescription.lowercased()
                let isAuthError = msg.contains("this video requires")
                               || msg.contains("sign in to confirm")
                               || msg.contains("please sign in")
                               || msg.contains("login required")
                               || msg.contains("members only")
                               || msg.contains("private video")
                               || msg.contains("age-restricted")
                               || msg.contains("age restricted")
                               || msg.contains("requires authentication")
                               || msg.contains("subscriber")
                               || msg.contains("subscription")
                               || msg.contains("must be logged in")
                               || msg.contains("logged into an account")
                               || msg.contains("account that has access")
                               || msg.contains("premium")
                               || msg.contains("patreon")
                               || (msg.contains("http error 403") && !msg.contains("http error 4030"))
                if isAuthError {
                    job.metaState = hasCookies ? .needsAuthRetry : .needsAuth
                } else {
                    job.metaState = .idle
                }
            }
        }
    }
    /// Public entry for fetching metadata for a single video (used by playlist lazy-load)
    nonisolated func fetchSingleVideoMeta(url: String, ytdlpPath: String, authArgs: [String]) async -> Result<VideoMeta, Error> {
        await runMetadataFetch(url: url, ytdlpPath: ytdlpPath, authArgs: authArgs)
    }

    nonisolated private func runMetadataFetch(url: String, ytdlpPath: String, authArgs: [String]) async -> Result<VideoMeta, Error> {
        // Inline the afreecatv/soop check here (pure URL string logic) to avoid
        // a call to the @MainActor-isolated isSoopOrAfreecaURL from nonisolated context.
        // For these VODs we must NOT pass --no-playlist so yt-dlp enumerates all parts
        // and n_entries is populated correctly. We still only read the first JSON line.
        let isSoopOrAfreeca: Bool = {
            guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
            return host.contains("sooptv.com") || host.contains("afreecatv.com")
        }()
        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytdlpPath)
            let noPlaylistArgs: [String] = isSoopOrAfreeca ? [] : ["--no-playlist"]
            let args = authArgs + noPlaylistArgs + [
                "--dump-json", "--no-warnings",
                "--no-check-formats",
                "--socket-timeout", "15",
                "--retries", "1", "--fragment-retries", "1",
                url
            ]
            proc.arguments = args

            let outPipe = Pipe(); let errPipe = Pipe()
            proc.standardOutput = outPipe; proc.standardError = errPipe

            final class Box: @unchecked Sendable { var data = Data() }
            final class ErrBox: @unchecked Sendable { var data = Data() }
            let box = Box(); let lock = NSLock()
            let errBox = ErrBox(); let errLock = NSLock()
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData; guard !chunk.isEmpty else { return }
                lock.lock(); box.data.append(chunk); lock.unlock()
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData; guard !chunk.isEmpty else { return }
                errLock.lock(); errBox.data.append(chunk); errLock.unlock()
            }

            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                box.data.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                let data = box.data; lock.unlock()
                errLock.lock()
                errBox.data.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let errText = String(data: errBox.data, encoding: .utf8) ?? ""
                errLock.unlock()

                // yt-dlp may output multiple JSON objects (one per part) for sites like soop.
                // Take only the first line - it represents the first/main video entry.
                let firstLine = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first.map { Data($0) } ?? data
                guard p.terminationStatus == 0, !firstLine.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any]
                else {
                    cont.resume(returning: .failure(NSError(domain: "yoink", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: errText.isEmpty
                            ? "yt-dlp failed or returned no data"
                            : errText])))
                    return
                }

                let title          = json["title"]           as? String ?? "Unknown"
                let thumbnail      = json["thumbnail"]       as? String ?? ""
                let durationString = json["duration_string"] as? String ?? "0:00"
                let durSecs        = json["duration"]        as? Double ?? 0
                let nEntries       = json["n_entries"]       as? Int ?? 1
                let ytdlpType      = json["_type"]           as? String ?? "video"
                let isRealPlaylist = (ytdlpType == "playlist")
                let dh = String(format: "%02d", Int(durSecs) / 3600)
                let dm = String(format: "%02d", (Int(durSecs) % 3600) / 60)
                let ds = String(format: "%02d", Int(durSecs) % 60)

                var chapters: [VideoChapter] = []
                if let arr = json["chapters"] as? [[String: Any]] {
                    for ch in arr {
                        guard let t = ch["title"]      as? String,
                              let s = ch["start_time"] as? Double,
                              let e = ch["end_time"]   as? Double else { continue }
                        chapters.append(VideoChapter(title: t, startTime: Int(s), endTime: Int(e)))
                    }
                }

                var videoFormats: [VideoFormatInfo] = []
                var audioFormats: [AudioFormatInfo] = []
                var seen = Set<String>()   // deduplicate by (height, ext, codec family)

                if let fmts = json["formats"] as? [[String: Any]] {

                    for fmt in fmts.reversed() {
                        guard let fid  = fmt["format_id"] as? String else { continue }
                        let ext        = fmt["ext"]    as? String ?? ""
                        let vcodec     = fmt["vcodec"] as? String ?? "none"
                        let acodec     = fmt["acodec"] as? String ?? "none"

                        guard ext != "mhtml" else { continue }
                        let hasVideo = vcodec != "none" && !vcodec.isEmpty
                        let hasAudio = acodec != "none" && !acodec.isEmpty
                        guard hasVideo || hasAudio else { continue }

                        let height   = fmt["height"]   as? Int
                        let fps      = fmt["fps"]      as? Double
                        let abr      = fmt["abr"]      as? Double
                        let tbr      = fmt["tbr"]      as? Double
                        let filesize = (fmt["filesize"] as? Int64) ?? (fmt["filesize_approx"] as? Int64)

                        if hasVideo {
                            let codecFamily: String
                            if vcodec.hasPrefix("avc") { codecFamily = "h264" }
                            else if vcodec.hasPrefix("vp9") || vcodec.hasPrefix("vp0") { codecFamily = "vp9" }
                            else if vcodec.hasPrefix("av0") { codecFamily = "av1" }
                            else { codecFamily = vcodec }

                            let dedupeKey = "\(height ?? 0)-\(codecFamily)-\(ext)"
                            guard !seen.contains(dedupeKey) else { continue }
                            seen.insert(dedupeKey)

                            videoFormats.append(VideoFormatInfo(
                                id: fid, ext: ext, height: height,
                                fps: fps, vcodec: vcodec, filesize: filesize, tbr: tbr))
                        } else if hasAudio && !hasVideo {
                            let dedupeKey = "audio-\(acodec)-\(ext)"
                            guard !seen.contains(dedupeKey) else { continue }
                            seen.insert(dedupeKey)

                            audioFormats.append(AudioFormatInfo(
                                id: fid, ext: ext, acodec: acodec,
                                abr: abr, filesize: filesize))
                        }
                    }
                }
                videoFormats.sort {
                    if ($0.height ?? 0) != ($1.height ?? 0) { return ($0.height ?? 0) > ($1.height ?? 0) }
                    return ($0.tbr ?? 0) > ($1.tbr ?? 0)
                }
                audioFormats.sort { ($0.abr ?? 0) > ($1.abr ?? 0) }

                // ── Subtitles ───────────────────────────────────────────────────

                func langKeys(_ dict: [String: Any]?) -> [String] {
                    guard let d = dict else { return [] }
                    return d.keys.filter { k in
                        k.count >= 2 && k.count <= 10 && k != "live_chat"
                        && k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
                    }.sorted()
                }
                let manualLangs = langKeys(json["subtitles"]          as? [String: Any])
                let autoLangs   = langKeys(json["automatic_captions"] as? [String: Any])
                let origLangs   = autoLangs.filter { $0.hasSuffix("-orig") }

                let subLangs: [String]
                if !manualLangs.isEmpty       { subLangs = manualLangs }
                else if !origLangs.isEmpty    { subLangs = origLangs   }
                else                          { subLangs = autoLangs   }

                cont.resume(returning: .success(VideoMeta(
                    title: title, thumbnail: thumbnail,
                    duration: durationString, durationH: dh, durationM: dm, durationS: ds,
                    hasSubs: !subLangs.isEmpty, chapters: chapters,
                    availableSubLangs: subLangs,
                    videoFormats: videoFormats, audioFormats: audioFormats,
                    nEntries: nEntries, isRealPlaylist: isRealPlaylist)))
            }
            do { try proc.run() } catch { cont.resume(returning: .failure(error)) }
        }
    }

    
            // MARK: - Playlist fetch

    func fetchPlaylist(url: String, authArgs: [String] = []) async -> Result<[PlaylistItem], Error> {
        guard let ytdlpPath = await DependencyService.shared.resolvePath(for: "yt-dlp") else {
            return .failure(NSError(domain: "yoink", code: 1, userInfo: [NSLocalizedDescriptionKey: "yt-dlp not found"]))
        }

        // afreecatv / soop VODs are multi-part single broadcasts, not real playlists.
        // --flat-playlist returns nothing useful on them; --dump-json emits one JSON
        // object per part, which we parse directly.
        if DownloadService.isSoopOrAfreecaURL(url) {
            return await fetchAfreecatvParts(url: url, ytdlpPath: ytdlpPath, authArgs: authArgs)
        }

        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytdlpPath)

            proc.arguments = authArgs + [
                "--flat-playlist",
                "--print", "%(playlist_index)s",
                "--print", "%(id)s",
                "--print", "%(title)s",
                "--print", "%(duration)s",
                "--print", "%(thumbnail)s",
                "--print", "---YOINK---",
                "--no-warnings",
                url
            ]
            let outPipe3 = Pipe(); let errPipe3 = Pipe()
            proc.standardOutput = outPipe3; proc.standardError = errPipe3
            final class PlBox: @unchecked Sendable { var data = Data() }
            let plBox = PlBox(); let plLock = NSLock()
            outPipe3.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; guard !d.isEmpty else { return }
                plLock.lock(); plBox.data.append(d); plLock.unlock()
            }
            errPipe3.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
            proc.terminationHandler = { _ in
                outPipe3.fileHandleForReading.readabilityHandler = nil
                errPipe3.fileHandleForReading.readabilityHandler = nil
                plLock.lock()
                plBox.data.append(outPipe3.fileHandleForReading.readDataToEndOfFile())
                let raw = String(data: plBox.data, encoding: .utf8) ?? ""
                plLock.unlock()
                var items: [PlaylistItem] = []
                let lines = raw.components(separatedBy: "\n")
                var i = 0
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "---YOINK---" {
                        i += 1; continue
                    }
                    guard i + 5 < lines.count else { i += 1; continue }
                    let idxStr  = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    let vid     = lines[i+1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let ttl     = lines[i+2].trimmingCharacters(in: .whitespacesAndNewlines)
                    let durStr  = lines[i+3].trimmingCharacters(in: .whitespacesAndNewlines)
                    let thumb   = lines[i+4].trimmingCharacters(in: .whitespacesAndNewlines)
                    let sep     = lines[i+5].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard sep == "---YOINK---" else { i += 1; continue }
                    guard !vid.isEmpty, vid != "NA" else { i += 6; continue }
                    let idx = Int(idxStr) ?? items.count + 1
                    let title = (ttl.isEmpty || ttl == "NA") ? "(No title)" : ttl
                    let durSecs = Int(Double(durStr) ?? 0)
                    let dh = durSecs / 3600; let dm = (durSecs % 3600) / 60; let ds = durSecs % 60
                    let dur: String
                    if durSecs == 0 || durStr == "NA" || durStr.isEmpty {
                        dur = "" // unknown - hide rather than show 0:00
                    } else if dh > 0 {
                        dur = String(format: "%d:%02d:%02d", dh, dm, ds)
                    } else {
                        dur = String(format: "%d:%02d", dm, ds)
                    }
                    let thumbnail = (thumb == "NA" || thumb.isEmpty) ? "" : thumb
                    let item = PlaylistItem(index: idx, videoID: vid, title: title, duration: dur)
                    item.thumbnail = thumbnail
                    items.append(item)
                    i += 6
                }
                if items.isEmpty {
                    cont.resume(returning: .failure(NSError(domain: "yoink", code: 2, userInfo: [NSLocalizedDescriptionKey: "No playlist items found. Check the URL or try again."])))
                } else {
                    cont.resume(returning: .success(items))
                }
            }
            do { try proc.run() } catch { cont.resume(returning: .failure(error)) }
        }
    }

    // MARK: - afreecatv / soop multi-part VOD fetcher
    // yt-dlp --dump-json on a vod.afreecatv.com URL emits one JSON object per part,
    // one per line. We parse each line to build the PlaylistItem list, preserving
    // playlist_index as the part number for use with --playlist-items N on download.
    nonisolated private func fetchAfreecatvParts(url: String, ytdlpPath: String, authArgs: [String]) async -> Result<[PlaylistItem], Error> {
        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytdlpPath)
            // Do NOT pass --no-playlist: we want all parts.
            // --no-check-formats keeps it fast (no format probing).
            proc.arguments = authArgs + [
                "--dump-json",
                "--no-check-formats",
                "--no-warnings",
                "--socket-timeout", "15",
                "--retries", "1",
                url
            ]
            let outPipe = Pipe(); let errPipe = Pipe()
            proc.standardOutput = outPipe; proc.standardError = errPipe
            final class Box: @unchecked Sendable { var data = Data() }
            final class EBox: @unchecked Sendable { var data = Data() }
            let box = Box(); let lock = NSLock()
            let eBox = EBox(); let eLock = NSLock()
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; guard !d.isEmpty else { return }
                lock.lock(); box.data.append(d); lock.unlock()
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; guard !d.isEmpty else { return }
                eLock.lock(); eBox.data.append(d); eLock.unlock()
            }
            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                box.data.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                let raw = String(data: box.data, encoding: .utf8) ?? ""
                lock.unlock()
                eLock.lock()
                eBox.data.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let errText = String(data: eBox.data, encoding: .utf8) ?? ""
                eLock.unlock()

                var items: [PlaylistItem] = []
                // Each line is a separate JSON object (one per VOD part).
                let jsonLines = raw.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                for (lineIdx, line) in jsonLines.enumerated() {
                    guard let data = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }

                    // playlist_index is 1-based part number; fall back to line position
                    let idx        = (json["playlist_index"] as? Int) ?? (lineIdx + 1)
                    let title      = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Part \(idx)"
                    let thumbnail  = json["thumbnail"] as? String ?? ""
                    let vid        = json["id"] as? String ?? ""
                    let durSecs    = Int(json["duration"] as? Double ?? 0)
                    let dh = durSecs / 3600; let dm = (durSecs % 3600) / 60; let ds = durSecs % 60
                    let dur: String
                    if durSecs == 0 {
                        dur = ""
                    } else if dh > 0 {
                        dur = String(format: "%d:%02d:%02d", dh, dm, ds)
                    } else {
                        dur = String(format: "%d:%02d", dm, ds)
                    }

                    let item = PlaylistItem(index: idx, videoID: vid, title: title, duration: dur)
                    item.thumbnail = thumbnail
                    items.append(item)
                }

                if items.isEmpty {
                    let reason = errText.isEmpty ? "No parts found. Check the URL or try again." : errText
                    cont.resume(returning: .failure(NSError(domain: "yoink", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: reason])))
                } else {
                    // Sort by part index in case yt-dlp emits them out of order
                    cont.resume(returning: .success(items.sorted { $0.index < $1.index }))
                }
            }
            do { try proc.run() } catch { cont.resume(returning: .failure(error)) }
        }
    }

    // MARK: - Advanced mode: start individual playlist item download

    func startPlaylistItem(_ item: PlaylistItem, baseURL: String, outputDir: URL, authArgs: [String] = []) {
        Task {
            guard let path = await DependencyService.shared.resolvePath(for: "yt-dlp"),
                  let ffPath = await DependencyService.shared.resolvePath(for: "ffmpeg") else { return }
            await launchPlaylistItem(item, baseURL: baseURL, outputDir: outputDir,
                                     ytdlpPath: path, ffmpegPath: ffPath, authArgs: authArgs)
        }
    }

    @MainActor
    private func launchPlaylistItem(_ item: PlaylistItem, baseURL: String, outputDir: URL,
                                     ytdlpPath: String, ffmpegPath: String, authArgs: [String]) async {
        var args: [String] = []
        if !item.selectedVideoFormatId.isEmpty && item.selectedVideoFormatId != "audio" {
            let audioId = item.selectedAudioFormatId.isEmpty
                ? (item.audioFormats.first?.id ?? "bestaudio")
                : item.selectedAudioFormatId
            args += ["-f", "\(item.selectedVideoFormatId)+\(audioId)"]
            args += ["--merge-output-format", "mp4"]
        } else if item.selectedVideoFormatId == "audio" {
            let audioId = item.selectedAudioFormatId.isEmpty ? "bestaudio" : item.selectedAudioFormatId
            args += ["-f", audioId]
        } else {
            args += ["-f", item.format.rawValue]
            if !item.format.isAudio { args += ["--merge-output-format", "mp4"] }
        }
        args += ["--ffmpeg-location", ffmpegPath]
        if item.downloadSubs && !item.subLang.isEmpty {
            args += ["--write-subs", "--write-auto-subs", "--sub-lang", item.subLang, "--sub-format", "srt/vtt/best"]
        }
        if item.sponsorBlock {
            args += ["--sponsorblock-remove", "sponsor,selfpromo,interaction"]
            args += ["--write-info-json"]
            args += ["--remux-video", "mp4"]
        }

        let hasStart = !item.startH.isEmpty || !item.startM.isEmpty || !item.startS.isEmpty
        let hasEnd   = item.endH != "00" || item.endM != "00" || item.endS != "00"
        if hasStart || hasEnd {
            let sH = Int(item.startH) ?? 0
            let sM = Int(item.startM) ?? 0
            let sS = Int(item.startS) ?? 0
            let eH = Int(item.endH)   ?? 0
            let eM = Int(item.endM)   ?? 0
            let eS = Int(item.endS)   ?? 0
            let s  = sH * 3600 + sM * 60 + sS
            let e  = eH * 3600 + eM * 60 + eS
            if e > s { args += ["--download-sections", "*\(s)-\(e)", "--force-keyframes-at-cuts"] }
        }

        args += authArgs
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yoink-frags", isDirectory: true)
        args += ["--paths", "home:\(outputDir.path)", "--paths", "temp:\(tempDir.path)", "--no-keep-fragments"]
        args += ["-o", "%(title)s.%(ext)s", "--newline",
                 "--progress-template", "%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.fragment_index)s|%(progress.fragment_count)s"]

        let videoURL: String
        if baseURL.contains("youtube.com") || baseURL.contains("youtu.be") {
            videoURL = "https://www.youtube.com/watch?v=\(item.videoID)"
        } else {
            videoURL = baseURL  // other platforms use the base URL with --playlist-items
            args += ["--playlist-items", String(item.index)]
        }
        args.append(videoURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ytdlpPath)
        proc.arguments = args

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = outPipe

        proc.terminationHandler = { p in
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async {
                item.downloadStatus = ok ? .done : .failed
                if ok {
                    Haptics.success()
                    let doneFile = primaryMediaFile(in: outputDir) ?? outputDir
                    HistoryStore.shared.add(HistoryEntry(
                        id: UUID(),
                        title: item.title,
                        thumbnail: item.thumbnail,
                        url: baseURL,
                        outputPath: doneFile.path,
                        date: Date(),
                        format: item.selectedVideoFormatId.isEmpty
                            ? item.format.displayName
                            : "\(item.selectedVideoFormatId)+\(item.selectedAudioFormatId)",
                        fileSize: {
                            let sz = (try? doneFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                            return Int64(sz)
                        }()))
                    sendCompletionNotification(outputDir: outputDir, title: item.title,
                                               exactFilePath: doneFile.path)
                } else {
                    Haptics.error()
                }
            }
        }
        do    { try proc.run() }
        catch { DispatchQueue.main.async { item.downloadStatus = .failed } }
        item.downloadStatus = .downloading
    }

    // Re-fetch after cookies change
    func refetchMetadata(for job: DownloadJob) {
        guard job.hasURL else { return }
        fetchMetadata(for: job)
    }

    // MARK: Download

    func start(job: DownloadJob, outputDir: URL) {
        guard job.hasURL else { return }
        // Apply per-site format override if the user hasn't picked a specific format for this job
        let sm = SettingsManager.shared
        if job.format == sm.defaultFormat && job.selectedVideoFormatId.isEmpty && job.selectedAudioFormatId.isEmpty {
            if let siteOverride = sm.siteFormat(for: job.url) {
                job.format = siteOverride
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let ytdlpPath = await DependencyService.shared.resolvePath(for: "yt-dlp") else {
                await MainActor.run { job.status = .failed("yt-dlp not found") }
                return
            }
            let ffmpegPath = await DependencyService.shared.resolvePath(for: "ffmpeg")
            await self.run(job: job, ytdlpPath: ytdlpPath, ffmpegPath: ffmpegPath, outputDir: outputDir)
        }
    }

    private func run(job: DownloadJob, ytdlpPath: String, ffmpegPath: String?, outputDir: URL) async {
        job.status         = .fetching
        job.log            = []
        job.downloadedBytes = 0
        job.totalBytes      = 0
        Haptics.start()
        let args   = job.buildArguments(outputDir: outputDir, ffmpegPath: ffmpegPath)
        job.appendLog("$ yt-dlp " + args.joined(separator: " "), kind: .command)

        // Subtitle keep-ranges for segment/chapter selection.
        let subtitleKeepRanges: [(startMs: Int, endMs: Int)] = {
            guard job.useSegment && job.downloadSubs else { return [] }
            switch job.segmentMode {
            case .manual:
                let sH = Int(job.startH) ?? 0; let sM = Int(job.startM) ?? 0; let sS = Int(job.startS) ?? 0
                let eH = Int(job.endH)   ?? 0; let eM = Int(job.endM)   ?? 0; let eS = Int(job.endS)   ?? 0
                let startMs = (sH * 3600 + sM * 60 + sS) * 1000
                let endMs   = (eH * 3600 + eM * 60 + eS) * 1000
                guard endMs > startMs else { return [] }
                return [(startMs: startMs, endMs: endMs)]
            case .chapters:
                guard let chapters = job.meta?.chapters else { return [] }
                return chapters
                    .filter { job.selectedChapters.contains($0.id) }
                    .map { (startMs: $0.startTime * 1000, endMs: $0.endTime * 1000) }
            }
        }()

        // Capture SponsorBlock removed segments for subtitle retiming.
        final class SegBox: @unchecked Sendable { var segs: [(startMs: Int, endMs: Int)] = [] }
        let segBox = SegBox(); let segLock = NSLock()

        // Capture the exact output file path from yt-dlp's "[download] Destination:" log line.
        // This is more reliable than scanning the folder - it's the filename yt-dlp chose.
        // We also watch for "[Merger] Merging formats into" for merged (video+audio) outputs.
        final class FileBox: @unchecked Sendable { var path: String = "" }
        let fileBox = FileBox(); let fileLock = NSLock()

        // Snapshot Twitch fragment count once (MainActor property - can't read from Sendable closure)
        final class FragBox: @unchecked Sendable { var count: Int = 0 }
        let fragBox = FragBox()
        fragBox.count = job.twitchTotalFragments

        // Snapshot segment duration (seconds) for ffmpeg progress % computation.
        // When yt-dlp runs ffmpeg directly (--download-sections), we get time= not fragment_index.
        let segStartSecs: Double = {
            let h = Double(job.startH) ?? 0
            let m = Double(job.startM) ?? 0
            let s = Double(job.startS) ?? 0
            return h * 3600 + m * 60 + s
        }()
        let segEndSecs: Double = {
            let h = Double(job.endH) ?? 0
            let m = Double(job.endM) ?? 0
            let s = Double(job.endS) ?? 0
            return h * 3600 + m * 60 + s
        }()
        // If no segment set, fall back to full video duration
        let segDurationSecs: Double = {
            let d = segEndSecs - segStartSecs
            if d > 0 { return d }
            // full duration from meta
            let h = Double(job.meta?.durationH ?? "0") ?? 0
            let m = Double(job.meta?.durationM ?? "0") ?? 0
            let s = Double(job.meta?.durationS ?? "0") ?? 0
            return h * 3600 + m * 60 + s
        }()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Create a unique temp working directory for this download.
            // yt-dlp writes all fragment/temp files relative to its working directory.
            // By isolating each download here, fragments never appear in the output folder.
            // The temp dir is deleted after the process exits.
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("yoink-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytdlpPath)
            proc.arguments     = args
            proc.currentDirectoryURL = workDir
            let stdout = Pipe(), stderr = Pipe()
            proc.standardOutput = stdout; proc.standardError = stderr
            job.process = proc

            job.downloadedBytes = 0
            job.totalBytes      = 0

            proc.qualityOfService = SettingsManager.shared.processPriority.qualityOfService

            stdout.fileHandleForReading.readabilityHandler = { [weak job] handle in
                guard let job else { return }
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                struct Update {
                    var status: JobStatus?
                    var dlBytes: Int64?
                    var totBytes: Int64?
                    var logLine: (String, LogLine.Kind)?
                    var speedKBps: Double?   // for sparkline
                }
                var update = Update()
                for raw in text.components(separatedBy: "\n") {
                    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    let parts = line.components(separatedBy: "|")
                    if parts.count >= 4 {
                        let pctStr    = parts[0].trimmingCharacters(in: .whitespaces)
                        let speedStr  = parts[1].trimmingCharacters(in: .whitespaces)
                        let etaStr    = parts[2].trimmingCharacters(in: .whitespaces)
                        let statusStr = parts[3].trimmingCharacters(in: .whitespaces)
                        let dlBytes   = parts.indices.contains(4) ? Int64(parts[4].trimmingCharacters(in: .whitespaces)) : nil
                        let totBytes  = parts.indices.contains(5) ? Int64(parts[5].trimmingCharacters(in: .whitespaces)) : nil
                        let estBytes  = parts.indices.contains(6) ? Int64(parts[6].trimmingCharacters(in: .whitespaces)) : nil
                        let fragIdx   = parts.indices.contains(7) ? Int(parts[7].trimmingCharacters(in: .whitespaces)) : nil
                        let fragCount = parts.indices.contains(8) ? Int(parts[8].trimmingCharacters(in: .whitespaces)) : nil
                        if let dl  = dlBytes,  dl  > 0 { update.dlBytes  = dl }
                        if let tot = totBytes, tot > 0 { update.totBytes  = tot }
                        else if let est = estBytes, est > 0 { update.totBytes = est }
                        // Parse speed string for sparkline (e.g. "2.34MiB/s", "512.00KiB/s")
                        if speedStr != "N/A" && !speedStr.isEmpty {
                            let s = speedStr.lowercased()
                            if let v = Double(s.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "/"))).first ?? "") {
                                if s.contains("mib") || s.contains("mb") { update.speedKBps = v * 1024 }
                                else if s.contains("gib") || s.contains("gb") { update.speedKBps = v * 1024 * 1024 }
                                else { update.speedKBps = v }   // already KiB/s
                            }
                        }
                        if statusStr.contains("merg") || statusStr.contains("finish") {
                            let speed = speedStr == "N/A" ? "" : "  \(speedStr)"
                            update.status  = .merging
                            update.logLine = ("Merging…\(speed)", .progress)
                        } else if let pct = Double(pctStr.replacingOccurrences(of: "%", with: "")) {
                            var label = "\(Int(pct))%"
                            if speedStr != "N/A" && !speedStr.isEmpty { label += "  \(speedStr)" }
                            if etaStr   != "N/A" && !etaStr.isEmpty   { label += "  ETA \(etaStr)" }
                            update.status  = .downloading(min(pct / 100.0, 1.0))
                            update.logLine = (label, .progress)
                        } else if let fi = fragIdx, let fc = fragCount, fc > 0 {
                            // Known fragment count (e.g. from yt-dlp output)
                            let pct = Double(fi) / Double(fc)
                            var label = "\(Int(pct * 100))%  frag \(fi)/\(fc)"
                            if speedStr != "N/A" && !speedStr.isEmpty { label += "  \(speedStr)" }
                            update.status  = .downloading(min(pct, 1.0))
                            update.logLine = (label, .progress)
                        } else if let fi = fragIdx, fi > 0,
                                  fragBox.count > 0 {
                            // Twitch VOD: use pre-fetched fragment count from M3U8 for real %
                            let totalFrags = fragBox.count
                            let pct = min(Double(fi) / Double(totalFrags), 1.0)
                            var label = "\(Int(pct * 100))%  frag \(fi)/\(totalFrags)"
                            if speedStr != "N/A" && !speedStr.isEmpty { label += "  \(speedStr)" }
                            if etaStr   != "N/A" && !etaStr.isEmpty   { label += "  ETA \(etaStr)" }
                            update.status  = .downloading(pct)
                            update.logLine = (label, .progress)
                        } else if let fi = fragIdx, fi > 0,
                                  let dl = dlBytes, let tot = totBytes ?? estBytes, tot > 0 {
                            // Twitch live/HLS: no total fragment count, but we have byte counts
                            let pct = min(Double(dl) / Double(tot), 1.0)
                            var label = "\(Int(pct * 100))%  frag \(fi)"
                            if speedStr != "N/A" && !speedStr.isEmpty { label += "  \(speedStr)" }
                            update.status  = .downloading(pct)
                            update.logLine = (label, .progress)
                        } else if let fi = fragIdx, fi > 0 {
                            // Twitch live: only fragment index known, no total - show frag counter
                            var label = "frag \(fi)"
                            if speedStr != "N/A" && !speedStr.isEmpty { label += "  \(speedStr)" }
                            update.status  = .downloading(0)
                            update.logLine = (label, .progress)
                        } else if !pctStr.isEmpty && pctStr != "N/A" {
                            update.logLine = (pctStr, .progress)
                        }
                    } else {
                        if line.lowercased().contains("[merger]") || line.lowercased().contains("[ffmpeg]") {
                            update.status = .merging
                        }
                        // Capture the final output path from yt-dlp's own log lines.
                        // "[download] Destination: /path/file.mp4"  - intermediate or final file
                        // "[Merger] Merging formats into "/path/file.mp4""  - merged output (most reliable)
                        // "[MoveFiles] Moving file ..." can also appear - use Merger/MoveFiles as authoritative
                        let lower = line.lowercased()
                        if lower.hasPrefix("[merger] merging formats into") || lower.hasPrefix("[movefiles] moving file") {
                            // Extract path from quoted string if present, otherwise after last space
                            var captured = ""
                            if let q1 = line.firstIndex(of: Character("\"")), let q2 = line.lastIndex(of: Character("\"")), q1 != q2 {
                                captured = String(line[line.index(after: q1)..<q2])
                            } else if let space = line.lastIndex(of: " ") {
                                captured = String(line[line.index(after: space)...])
                            }
                            if !captured.isEmpty {
                                fileLock.lock(); fileBox.path = captured; fileLock.unlock()
                            }
                        } else if lower.hasPrefix("[download] destination:") {
                            let dest = line.dropFirst("[download] Destination:".count).trimmingCharacters(in: .whitespaces)
                            // Only store media files, not .part/.ytdl temp files
                            let ext = (dest as NSString).pathExtension.lowercased()
                            let tempExts: Set<String> = ["part", "ytdl", "tmp"]
                            if !dest.isEmpty && !tempExts.contains(ext) {
                                fileLock.lock()
                                // Prefer to keep the last Destination line - it's usually the merged output
                                fileBox.path = dest
                                fileLock.unlock()
                            }
                        }
                        update.logLine = (line, .info)
                    }
                }
                DispatchQueue.main.async {
                    if let dl  = update.dlBytes  { job.downloadedBytes = dl }
                    if let tot = update.totBytes  { job.totalBytes = tot }
                    if let s   = update.status    { job.status = s }
                    if let (msg, kind) = update.logLine { job.appendLog(msg, kind: kind) }
                    if let spd = update.speedKBps {
                        job.speedHistory.append(spd)
                        if job.speedHistory.count > 40 { job.speedHistory.removeFirst() }
                    }
                }
            }

            stderr.fileHandleForReading.readabilityHandler = { [weak job] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                var isMerging = false
                var progressMsg: String? = nil
                var otherMsg: String? = nil
                var otherKind: LogLine.Kind = .info
                for raw in text.components(separatedBy: "\n") {
                    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }

                    if line.hasPrefix("[SponsorBlock]"), line.contains("Skipping") {
                        let parts = line.components(separatedBy: " ")
                        if let dashIdx = parts.firstIndex(of: "-"), dashIdx > 0, dashIdx + 1 < parts.count {
                            let startMs = subTimeToMs(parts[dashIdx - 1])
                            let endMs   = subTimeToMs(parts[dashIdx + 1])
                            if endMs > startMs {
                                segLock.lock()
                                segBox.segs.append((startMs: startMs, endMs: endMs))
                                segLock.unlock()
                            }
                        }
                    }

                    if line.hasPrefix("frame=") {
                        // frame= lines come from ffmpeg during segment cutting or post-processing.
                        // Do NOT set status to .merging here - that's misleading when the video is
                        // still being downloaded/cut. Only set .merging when yt-dlp itself reports
                        // a merge (handled via stdout statusStr check above).
                        if let timeRange  = line.range(of: "time="),
                           let speedRange = line.range(of: "speed=") {
                            let timeStr  = String(line[timeRange.upperBound...].prefix(11)).trimmingCharacters(in: .whitespaces)
                            let speedStr = String(line[speedRange.upperBound...].prefix(8)).trimmingCharacters(in: .whitespaces)

                            // Parse HH:MM:SS.ss → seconds
                            let timeParts = timeStr.components(separatedBy: ":")
                            var currentSecs: Double = 0
                            if timeParts.count == 3 {
                                currentSecs = (Double(timeParts[0]) ?? 0) * 3600
                                           + (Double(timeParts[1]) ?? 0) * 60
                                           + (Double(timeParts[2]) ?? 0)
                            }

                            let pct: Double
                            if segDurationSecs > 0 {
                                pct = min(currentSecs / segDurationSecs, 1.0)
                            } else {
                                pct = 0
                            }

                            let pctStr = segDurationSecs > 0 ? "\(Int(pct * 100))%" : timeStr
                            let label = "Processing… \(pctStr)  \(speedStr)"
                            progressMsg = label

                            // Push a real downloading status so the progress bar fills
                            DispatchQueue.main.async {
                                guard let job else { return }
                                job.status = .downloading(pct)
                                if let idx = job.log.indices.last(where: { job.log[$0].kind == .progress }) {
                                    job.log[idx] = LogLine(text: label, kind: .progress)
                                } else {
                                    job.appendLog(label, kind: .progress)
                                }
                            }
                            progressMsg = nil  // handled above directly, skip deferred update
                        }
                    } else if !line.hasPrefix("[https @") && !line.hasPrefix("[hls @") && !line.hasPrefix("[mp4 @") {
                        let up = line.uppercased()
                        otherKind = up.hasPrefix("WARNING:") ? .warning : up.hasPrefix("ERROR:") ? .error : .info
                        otherMsg = line
                    }
                }
                DispatchQueue.main.async {
                    // isMerging is only true if set explicitly (currently unused path - kept for future use)
                    if isMerging { job?.status = .merging }
                    if let msg = progressMsg {
                        if let idx = job?.log.indices.last(where: { job?.log[$0].kind == .progress }) {
                            job?.log[idx] = LogLine(text: msg, kind: .progress)
                        } else {
                            job?.appendLog(msg, kind: .progress)
                        }
                    } else if let msg = otherMsg {
                        job?.appendLog(msg, kind: otherKind)
                    }
                }
            }

            proc.terminationHandler = { [weak job] p in
                DispatchQueue.main.async {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    guard let job else { return }

                    // Move the finished file(s) from workDir into outputDir,
                    // then delete workDir entirely — all fragments go with it.
                    func moveOutputAndClean(capturedPath: String) -> String {
                        let fm = FileManager.default
                        var finalPath = capturedPath
                        // Move every media file yt-dlp wrote to workDir into outputDir
                        let mediaExts = Set(["mp4","mkv","webm","mov","m4a","mp3","opus","flac","ogg","wav","aac","srt","vtt"])
                        if let items = try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil, options: []) {
                            try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
                            for item in items where mediaExts.contains(item.pathExtension.lowercased()) {
                                let dest = outputDir.appendingPathComponent(item.lastPathComponent)
                                try? fm.moveItem(at: item, to: dest)
                                // Track the primary media file path
                                if item.path == capturedPath || finalPath.isEmpty {
                                    finalPath = dest.path
                                } else if !["srt","vtt"].contains(item.pathExtension.lowercased()) {
                                    finalPath = dest.path
                                }
                            }
                        }
                        // Wipe workDir — takes all fragments with it
                        try? fm.removeItem(at: workDir)
                        return finalPath
                    }

                    switch p.terminationStatus {
                    case 0:
                        segLock.lock(); let segs0 = segBox.segs; segLock.unlock()
                        fileLock.lock(); let path0 = fileBox.path; fileLock.unlock()
                        let movedPath0 = moveOutputAndClean(capturedPath: path0)
                        let job0 = job
                        Task { @MainActor in
                            await self.finishDownload(job: job0, capturedPath: movedPath0, outputDir: outputDir,
                                           sponsorSegs: segs0, subtitleKeepRanges: subtitleKeepRanges)
                        }
                        Haptics.success()
                    case 1:
                        let logText = job.log.map(\.text).joined(separator: "\n")
                        let hasRealError = logText.contains("ERROR:") &&
                                          !logText.contains("ERROR: unable to download video subtitles")
                        if hasRealError {
                            job.status = .failed("Download failed - check log for details")
                            job.appendLog("✗ Failed (code 1)", kind: .error)
                            Haptics.error()
                            try? FileManager.default.removeItem(at: workDir)
                        } else {
                            segLock.lock(); let segs1 = segBox.segs; segLock.unlock()
                            fileLock.lock(); let path1 = fileBox.path; fileLock.unlock()
                            let movedPath1 = moveOutputAndClean(capturedPath: path1)
                            let job1 = job
                            Task { @MainActor in
                                await self.finishDownload(job: job1, capturedPath: movedPath1, outputDir: outputDir,
                                               sponsorSegs: segs1, subtitleKeepRanges: subtitleKeepRanges)
                            }
                            Haptics.success()
                        }
                    case 15:   // SIGTERM (user cancel)
                        try? FileManager.default.removeItem(at: workDir)
                    default:
                        job.status = .failed("Exited with code \(p.terminationStatus)")
                        job.appendLog("✗ Failed (code \(p.terminationStatus))", kind: .error)
                        Haptics.error()
                        try? FileManager.default.removeItem(at: workDir)
                    }
                    if let cookieURL = job.cookieTempURL {
                        try? FileManager.default.removeItem(at: cookieURL)
                    }
                    cont.resume()
                }
            }
            do    { try proc.run() }
            catch { DispatchQueue.main.async { job.status = .failed(error.localizedDescription); cont.resume() } }
        }
    }

    // MARK: - Shared download-completion handler

    private func finishDownload(job: DownloadJob?,
                                 capturedPath: String,
                                 outputDir: URL,
                                 sponsorSegs: [(startMs: Int, endMs: Int)],
                                 subtitleKeepRanges: [(startMs: Int, endMs: Int)]) async {
        cleanSubtitles(in: outputDir, sponsorSegments: sponsorSegs.sorted { $0.startMs < $1.startMs },
                       keepRanges: subtitleKeepRanges)
        var rawDoneFile: URL = {
            if !capturedPath.isEmpty && FileManager.default.fileExists(atPath: capturedPath) {
                return URL(fileURLWithPath: capturedPath)
            }
            return primaryMediaFile(in: outputDir) ?? outputDir
        }()

        let sm = SettingsManager.shared
        if sm.autoOrganizeBySite, let jobURL = job?.url,
           let host = URLComponents(string: jobURL)?.host?.lowercased() {
            let siteName = Self.siteFolderName(from: host)
            let siteDir = outputDir.appendingPathComponent(siteName)
            try? FileManager.default.createDirectory(at: siteDir, withIntermediateDirectories: true)
            let dest = siteDir.appendingPathComponent(rawDoneFile.lastPathComponent)
            if rawDoneFile != dest, (try? FileManager.default.moveItem(at: rawDoneFile, to: dest)) != nil {
                rawDoneFile = dest
            }
        }

        let doneFile = rawDoneFile
        job?.status = .done(doneFile)
        job?.appendLog("✓ Download complete", kind: .success)

        let convertAction = sm.postConvert
        if convertAction != .none, let ffmpegPath = await DependencyService.shared.resolvePath(for: "ffmpeg") {
            let inputExt  = doneFile.pathExtension
            let outputExt = convertAction.outputExt(inputExt: inputExt)
            let outputFile = doneFile.deletingPathExtension().appendingPathExtension(outputExt)
            if let ffArgs = convertAction.ffmpegArgs(inputExt: inputExt) {
                job?.appendLog("⚙ Converting: \(convertAction.label)…", kind: .info)
                let args = ["-i", doneFile.path] + ffArgs + ["-y", outputFile.path]
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ffmpegPath)
                proc.arguments = args
                proc.standardOutput = Pipe(); proc.standardError = Pipe()
                if (try? proc.run()) != nil {
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 {
                        try? FileManager.default.removeItem(at: doneFile)
                        job?.status = .done(outputFile)
                        job?.appendLog("✓ Converted to \(outputExt.uppercased())", kind: .success)
                        finishWithFile(outputFile, job: job, sm: sm, outputDir: outputDir)
                    } else {
                        job?.appendLog("⚠ Conversion failed - keeping original", kind: .warning)
                        finishWithFile(doneFile, job: job, sm: sm, outputDir: outputDir)
                    }
                    return
                }
            }
        }

        finishWithFile(doneFile, job: job, sm: sm, outputDir: outputDir)
    }

    /// Removes all yt-dlp/ffmpeg fragment and temp files from outputDir recursively.
    /// Does NOT use .skipsHiddenFiles — yt-dlp names frag files with a leading dot
    /// (e.g. .fhls-1342.mp4.part-Frag1) which would be silently skipped otherwise.
    nonisolated static func cleanFragmentFiles(in outputDir: URL) {
        let accessing = outputDir.startAccessingSecurityScopedResource()
        defer { if accessing { outputDir.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: outputDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []   // no .skipsHiddenFiles — frag files start with a dot
        ) else { return }

        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let name = file.lastPathComponent
            let ext  = file.pathExtension.lowercased()
            if name.contains(".part-Frag")
                || ext == "part"
                || ext == "ytdl"
                || ext == "aria2"
                || ext == "lock"
                || name.contains(".fhls-")
                || name.contains(".temp.")
                || name.contains(".tmp.")
            {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func finishWithFile(_ doneFile: URL, job: DownloadJob?, sm: SettingsManager, outputDir: URL) {
        guard let j = job else { return }
        HistoryStore.shared.add(HistoryEntry(
            id: UUID(),
            title: j.meta?.title ?? j.url,
            thumbnail: j.meta?.thumbnail ?? "",
            url: j.url,
            outputPath: doneFile.path,
            date: Date(),
            format: j.selectedVideoFormatId.isEmpty
                ? j.format.displayName
                : "\(j.selectedVideoFormatId)+\(j.selectedAudioFormatId)",
            fileSize: {
                let sz = (try? doneFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return Int64(sz)
            }()))
        let action = sm.postDownload
        let videoTitle = j.meta?.title ?? j.url
        let exactPath = doneFile.path
        let thumbURL = j.meta?.thumbnail
        let shortcutName = sm.shortcutOnComplete.trimmingCharacters(in: .whitespaces)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Per-file notification - suppressed when queue-complete mode is on
            if !sm.notifyOnQueueComplete {
                sendCompletionNotification(outputDir: outputDir, title: videoTitle, exactFilePath: exactPath, thumbnailURL: thumbURL)
            }
            if action != .notify {
                executePostDownloadAction(action, outputDir: outputDir, title: videoTitle)
            }
            if !shortcutName.isEmpty {
                Self.runShortcut(named: shortcutName, filePath: exactPath, title: videoTitle)
            }
            // Queue-complete notification: fire once when all jobs have finished
            if sm.notifyOnQueueComplete, let queue = DownloadQueue.shared {
                let allDone = queue.jobs.allSatisfy { $0.status.isTerminal }
                let doneCount = queue.jobs.filter { $0.status.isDone }.count
                if allDone && doneCount > 0 {
                    let title = doneCount == 1
                        ? "Download complete"
                        : "\(doneCount) downloads complete"
                    sendQueueCompleteNotification(title: title, count: doneCount, outputDir: outputDir)
                }
            }
        }
    }

    private static func siteFolderName(from host: String) -> String {
        if host.contains("youtube") || host.contains("youtu.be") { return "YouTube" }
        if host.contains("twitch")     { return "Twitch" }
        if host.contains("twitter") || host.contains("x.com") { return "Twitter" }
        if host.contains("instagram")  { return "Instagram" }
        if host.contains("tiktok")     { return "TikTok" }
        if host.contains("vimeo")      { return "Vimeo" }
        if host.contains("soundcloud") { return "SoundCloud" }
        if host.contains("reddit")     { return "Reddit" }
        if host.contains("rumble")     { return "Rumble" }
        if host.contains("kick")       { return "Kick" }
        if host.contains("bilibili")   { return "Bilibili" }
        // Generic: use second-level domain
        let parts = host.components(separatedBy: ".")
        return parts.dropLast().last?.capitalized ?? host
    }

    private static func runShortcut(named name: String, filePath: String, title: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        proc.arguments = ["run", name, "--input-path", filePath]
        try? proc.run()
    }

    // MARK: Helpers

    func cookieArgs(for job: DownloadJob) -> [String] {
        guard !job.manualCookies.isEmpty else { return [] }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yoink_cookies_meta_\(job.id.uuidString).txt")
        try? job.manualCookies.write(to: tmp, atomically: true, encoding: .utf8)
        return ["--cookies", tmp.path]
    }

    /// Deletes the metadata-fetch cookie temp file written by cookieArgs(for:).
    private func cleanupMetaCookies(for job: DownloadJob) {
        guard !job.manualCookies.isEmpty else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yoink_cookies_meta_\(job.id.uuidString).txt")
        try? FileManager.default.removeItem(at: tmp)
    }
}


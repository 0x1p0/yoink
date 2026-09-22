import Foundation
import SwiftUI
import UserNotifications

/// Returns the largest media file in the directory.
private let mediaExtensions = Set(["mkv","mp4","webm","mov","m4a","mp3","opus","flac","ogg","wav","aac"])

func primaryMediaFile(in directory: URL) -> URL? {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
    let items = (try? fm.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys,
        options: .skipsHiddenFiles)) ?? []
    let mediaFiles = items.filter { mediaExtensions.contains($0.pathExtension.lowercased()) }
    // Primary sort: newest by creation date (most likely to be the file just downloaded).
    // Fallback sort: largest by size (old behaviour) for files with identical timestamps.
    return mediaFiles.max {
        let aVals = try? $0.resourceValues(forKeys: Set(keys))
        let bVals = try? $1.resourceValues(forKeys: Set(keys))
        let aDate = aVals?.creationDate ?? .distantPast
        let bDate = bVals?.creationDate ?? .distantPast
        if aDate != bDate { return aDate < bDate }
        let aSize = aVals?.fileSize ?? 0
        let bSize = bVals?.fileSize ?? 0
        return aSize < bSize
    }
}

func cleanSubtitles(in directory: URL, sponsorSegments: [(startMs: Int, endMs: Int)] = [], keepRanges: [(startMs: Int, endMs: Int)] = []) {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
    ) else { return }

    // Delete stray .info.json files
    for file in files where file.pathExtension == "json" && file.lastPathComponent.hasSuffix(".info.json") {
        try? FileManager.default.removeItem(at: file)
    }

    for file in files {
        let ext = file.pathExtension.lowercased()
        guard ext == "srt" || ext == "vtt" else { continue }
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }

        let cleaned = cleanYouTubeSubtitles(raw, removedSegments: sponsorSegments, keepRanges: keepRanges)

        let srtURL = file.deletingPathExtension().appendingPathExtension("srt")
        try? cleaned.write(to: srtURL, atomically: true, encoding: .utf8)

        if ext == "vtt" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Cleans YouTube subtitles: deduplicates rolling-window cues, strips VTT tags, retimes for SponsorBlock cuts.
private func cleanYouTubeSubtitles(_ input: String,
                                    removedSegments: [(startMs: Int, endMs: Int)] = [],
                                    keepRanges: [(startMs: Int, endMs: Int)] = []) -> String {
    struct Cue { var startMs: Int; var endMs: Int; var text: String }

    var cues: [Cue] = []
    var prevLast: String = ""

    for block in input.components(separatedBy: "\n\n") {
        let lines = block.components(separatedBy: "\n")

        // Find the timestamp line (contains -->)
        guard let tsIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }

        // Parse start/end - take only the time token (ignore VTT positioning metadata)
        let tsParts = lines[tsIdx].components(separatedBy: " --> ")
        guard tsParts.count == 2 else { continue }
        let startMs = subTimeToMs(tsParts[0].components(separatedBy: " ").first ?? tsParts[0])
        let endMs   = subTimeToMs(tsParts[1].components(separatedBy: " ").first ?? tsParts[1])

        // Skip micro transition cues (≤ 100 ms) - they are just carry-over display frames
        guard endMs - startMs > 100 else { continue }

        // Collect text lines after the timestamp, stripping VTT inline timing/karaoke tags
        var textLines: [String] = []
        for line in lines[(tsIdx + 1)...] {
            let stripped = stripSubtitleTags(line).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty, stripped != "\u{00a0}" else { continue }
            textLines.append(stripped)
        }
        guard !textLines.isEmpty else { continue }

        // De-duplicate rolling-window: YouTube repeats previous cue's last line.
        if !prevLast.isEmpty,
           textLines[0].trimmingCharacters(in: .whitespaces) == prevLast.trimmingCharacters(in: .whitespaces) {
            textLines.removeFirst()
        }
        guard !textLines.isEmpty else { continue }

        prevLast = textLines.last ?? ""
        cues.append(Cue(startMs: startMs, endMs: endMs, text: textLines.joined(separator: "\n")))
    }

    // SponsorBlock retiming: drop/clip cues in removed segments, shift timestamps.

    if !removedSegments.isEmpty {
        var retimed: [Cue] = []

        for cue in cues {
            let cueStart = cue.startMs
            var cueEnd   = cue.endMs
            var skip     = false

            // Compute how many ms have been cut out before this cue's start
            var offset = 0
            for seg in removedSegments {
                if seg.endMs <= cueStart {
                    // Segment is entirely before this cue - count it fully
                    offset += seg.endMs - seg.startMs
                } else if seg.startMs < cueEnd {
                    if seg.startMs <= cueStart {
                        skip = true
                        break
                    } else {
                        cueEnd = seg.startMs
                    }
                }

                if seg.startMs >= cueEnd { break }
            }

            if skip || cueEnd <= cueStart { continue }

            retimed.append(Cue(
                startMs: cueStart - offset,
                endMs:   cueEnd   - offset,
                text:    cue.text))
        }
        cues = retimed
    }

    // Filter to keep-ranges (segment/chapter selection), shift to 0-based.
    if !keepRanges.isEmpty {
        let sorted = keepRanges.sorted { $0.startMs < $1.startMs }
        var kept: [Cue] = []
        for cue in cues {
            for range in sorted {
                // Keep cue if it overlaps the range at all
                if cue.startMs < range.endMs && cue.endMs > range.startMs {
                    // Clip to range boundaries
                    let clippedStart = max(cue.startMs, range.startMs)
                    let clippedEnd   = min(cue.endMs,   range.endMs)
                    if clippedEnd > clippedStart {
                        kept.append(Cue(startMs: clippedStart, endMs: clippedEnd, text: cue.text))
                    }
                    break
                }
            }
        }
        // Shift to 0-based relative to the earliest keep-range.
        let shift = sorted.first?.startMs ?? 0
        cues = kept.map { Cue(startMs: $0.startMs - shift, endMs: $0.endMs - shift, text: $0.text) }
    }

    return cues.enumerated().map { (i, cue) in
        "\(i + 1)\n\(msToSrtTime(cue.startMs)) --> \(msToSrtTime(cue.endMs))\n\(cue.text)"
    }.joined(separator: "\n\n") + "\n"
}

/// Strips VTT inline word-timing tags like <00:00:01.280>, <c>, </c>, and any other HTML tags.
private func stripSubtitleTags(_ text: String) -> String {
    // Remove VTT timestamp tags: <00:00:01.280>
    var out = ""
    var i = text.startIndex
    while i < text.endIndex {
        if text[i] == "<" {
            if let close = text[i...].firstIndex(of: ">") {
                i = text.index(after: close)
                continue
            }
        }
        out.append(text[i])
        i = text.index(after: i)
    }
    return out
}

/// Converts VTT (MM:SS.mmm or HH:MM:SS.mmm) or SRT (HH:MM:SS,mmm) timestamps to milliseconds.
func subTimeToMs(_ raw: String) -> Int {
    let s = raw.trimmingCharacters(in: .whitespaces)
               .replacingOccurrences(of: ",", with: ".")  // SRT uses comma
    let parts = s.components(separatedBy: ":")
    let muls  = [3600_000, 60_000, 1_000]
    let offset = 3 - parts.count   // handle MM:SS.mmm (2 parts) vs HH:MM:SS.mmm (3 parts)
    var ms = 0
    for (i, part) in parts.enumerated() {
        let sub = part.components(separatedBy: ".")
        ms += (Int(sub[0]) ?? 0) * muls[max(0, offset + i)]
        if i == parts.count - 1, sub.count > 1 {
            ms += Int((sub[1] + "000").prefix(3)) ?? 0
        }
    }
    return ms
}

private func msToSrtTime(_ ms: Int) -> String {
    String(format: "%02d:%02d:%02d,%03d",
           ms / 3_600_000, (ms % 3_600_000) / 60_000,
           (ms % 60_000) / 1_000, ms % 1_000)
}


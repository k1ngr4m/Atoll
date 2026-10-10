#!/usr/bin/env python3
"""Run offline Swift checks; add --live to verify QQ Music over URLSession."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
manager = (root / "DynamicIsland/managers/MusicManager.swift").read_text()
line_type = manager[manager.index("struct LyricLine:"):manager.index("struct LyricsLookupKey:")]
checks = r'''
@main struct Check {
    static func main() async throws {
        let search = Data(#"{"code":0,"data":{"song":{"itemlist":[{"mid":"original","name":"晴天","singer":"周杰伦"},{"mid":"cover","name":"晴天","singer":"Other"},{"mid":"remix","name":"晴天 (Remix)","singer":"周杰伦"},{"name":"晴天","singer":"周杰伦"}]}}}"#.utf8)
        let songs = try QQMusicLyrics.parseSearchResponse(search, title: "晴天", artist: "周杰伦")
        precondition(songs.map(\.mid) == ["original"])
        let empty = try QQMusicLyrics.parseSearchResponse(Data(#"{"code":0,"data":{"song":{"itemlist":[]}}}"#.utf8), title: "晴天", artist: "周杰伦")
        precondition(empty.isEmpty)
        for bad in ["not json", #"{"code":1}"#, #"{"code":0,"data":{}}"#] {
            do {
                _ = try QQMusicLyrics.parseSearchResponse(Data(bad.utf8), title: "晴天", artist: "周杰伦")
                fatalError("Invalid search response accepted")
            } catch {}
        }
        let timed = try QQMusicLyrics.parseResolution(Data(#"{"code":0,"retcode":0,"lyric":"[00:01.50]测试歌词\n[00:03.00]下一行"}"#.utf8))
        precondition(timed.availability == .timed && timed.lines.count == 2)
        precondition(timed.lines[0].timestamp == 1.5 && timed.lines[0].text == "测试歌词")
        let plain = try QQMusicLyrics.parseResolution(Data(#"{"code":0,"lyric":"one\ntwo"}"#.utf8))
        precondition(plain.availability == .untimed && plain.lines.count == 2)
        let unavailable = try QQMusicLyrics.parseResolution(Data(#"{"code":0,"lyric":""}"#.utf8))
        precondition(unavailable.availability == .unavailable)
        do {
            _ = try QQMusicLyrics.parseResolution(Data(#"{"code":0,"retcode":-1,"lyric":"error"}"#.utf8))
            fatalError("API error accepted as lyrics")
        } catch {}
        let request = QQMusicLyrics.request(path: "splcloud/fcgi-bin/smartbox_new.fcg", query: ["key": "A+B & C/D?#"])
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.first { $0.name == "key" }?.value == "A+B & C/D?#")
        precondition(request.url!.absoluteString.contains("%2B"))
        precondition(request.value(forHTTPHeaderField: "Referer") == "https://y.qq.com/")
        let unknown = try await QQMusicLyrics.candidates(title: "Track 1", artist: "Unknown Artist")
        precondition(unknown.isEmpty)
        var fallbackUsed = false
        let fallback = await LyricsProviderFallback.resolve(
            primary: { try await QQMusicLyrics.fetch(title: "Track 1", artist: "Unknown Artist") },
            fallback: { fallbackUsed = true; return timed }
        )
        precondition(fallbackUsed && fallback.availability == .timed)
        let preferred = try QQMusicLyrics.parseResolution(Data(#"{"code":0,"lyric":"[00:01]QQ lyrics"}"#.utf8), songMID: "preferred")
        fallbackUsed = false
        let selected = await LyricsProviderFallback.resolve(
            primary: { preferred }, fallback: { fallbackUsed = true; return timed }
        )
        precondition(!fallbackUsed && selected.candidateID == "qqmusic-preferred")
        print("PASS: matching, malformed responses, timed/plain lyrics, request encoding, QQ priority and fallback")
        if CommandLine.arguments.contains("--live") {
            for (title, artist) in [("晴天", "周杰伦"), ("深呼吸", "范晓萱"), ("Hello", "Adele")] {
                let candidates = try await QQMusicLyrics.candidates(title: title, artist: artist)
                precondition(!candidates.isEmpty && candidates.contains { $0.resolution.availability == .timed })
                precondition(candidates.allSatisfy { $0.id.hasPrefix("qqmusic-") && $0.resolution.candidateID == $0.id })
                print("PASS live: \(title) / \(artist), \(candidates.count) candidates")
            }
        }
    }
}
'''
with tempfile.TemporaryDirectory(prefix="atoll-qqmusic-") as directory:
    source = Path(directory) / "Check.swift"
    source.write_text("import Foundation\n" + line_type + checks)
    binary = Path(directory) / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source),
                    *[str(root / "DynamicIsland/managers" / name) for name in
                      ["LRCParser.swift", "LyricsMetadata.swift", "QQMusicLyrics.swift"]],
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary), *sys.argv[1:]], check=True)

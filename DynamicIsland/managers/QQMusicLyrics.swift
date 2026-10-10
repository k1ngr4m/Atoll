import Foundation

enum QQMusicLyrics {
    struct Song {
        let mid: String
        let name: String
        let singer: String
    }

    static func fetch(title: String, artist: String, session: URLSession = .shared) async throws -> LyricsResolution {
        let matches = try await candidates(title: title, artist: artist, session: session)
        return matches.first(where: { $0.resolution.availability == .timed })?.resolution
            ?? matches.first?.resolution ?? LyricsResolution()
    }

    static func candidates(title: String, artist: String, session: URLSession = .shared) async throws -> [LyricsCandidate] {
        guard !LyricsMetadata.namesNoParticularTrack(title: title, artist: artist) else { return [] }
        let query = "\(title) \(artist.replacingOccurrences(of: "/", with: " "))"
        let data = try await load(path: "splcloud/fcgi-bin/smartbox_new.fcg", query: ["key": query], session: session)
        let songs = try parseSearchResponse(data, title: title, artist: artist)
        var candidates: [LyricsCandidate] = []
        for song in songs {
            try Task.checkCancellation()
            let data = try await load(path: "lyric/fcgi-bin/fcg_query_lyric_new.fcg",
                                      query: ["songmid": song.mid, "nobase64": "1"], session: session)
            let resolution = try parseResolution(data, songMID: song.mid)
            guard resolution.availability == .timed || resolution.availability == .untimed else { continue }
            candidates.append(LyricsCandidate(id: "qqmusic-\(song.mid)",
                label: "QQ 音乐 · \(song.name) · \(song.singer) · #\(song.mid)", resolution: resolution))
        }
        return candidates
    }

    static func request(path: String, query: [String: String]) -> URLRequest {
        var url = URLComponents(string: "https://c.y.qq.com/\(path)")!
        url.queryItems = (["format": "json"].merging(query) { _, value in value })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // Query endpoints interpret a literal plus as a space.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: url.url!, timeoutInterval: 15)
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func load(path: String, query: [String: String], session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request(path: path, query: query))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    static func parseSearchResponse(_ data: Data, title: String, artist: String) throws -> [Song] {
        let json = try response(data)
        guard let result = json["data"] as? [String: Any],
              let song = result["song"] as? [String: Any],
              let items = song["itemlist"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        // ponytail: smartbox returns up to four songs without duration; matching uses title and artist.
        // Use full search with durations if alternate recordings cause timing mismatches.
        return items.compactMap { item in
            guard let mid = item["mid"] as? String, !mid.isEmpty,
                  let name = item["name"] as? String, let singer = item["singer"] as? String,
                  LyricsSearchResults.agreesOnTitleAndArtist(["trackName": name, "artistName": singer],
                    artist: LyricsSearchResults.normalizedForMatching(artist),
                    title: LyricsSearchResults.normalizedForMatching(title)) else { return nil }
            return Song(mid: mid, name: name, singer: singer)
        }
    }

    static func parseResolution(_ data: Data, songMID: String? = nil) throws -> LyricsResolution {
        let json = try response(data)
        let lyric = (json["lyric"] as? String) ?? ""
        let lines = LRCParser.parse(lyric)
        return LyricsResolution(lines: lines.isEmpty ? LyricLine.untimedLines(from: lyric) : lines,
                                candidateID: songMID.map { "qqmusic-\($0)" })
    }

    private static func response(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["code"] as? Int == 0,
              (json["retcode"] as? Int ?? 0) == 0,
              (json["subcode"] as? Int ?? 0) == 0 else { throw URLError(.badServerResponse) }
        return json
    }
}

import Foundation

/// The pictures Spicy Lyrics can put behind the lyrics besides the cover: the artist's photo and
/// the song's Canvas (the short looping video Spotify shows on Now Playing).
extension SpotifyAPI {
    /// The first artist's largest photo, from the Web API. Nil when the artist has none.
    func artistImageURL(trackID: String) async throws -> URL? {
        struct Track: Decodable {
            struct Artist: Decodable { let id: String? }
            let artists: [Artist]?
        }
        struct Artist: Decodable {
            struct Image: Decodable { let url: String; let width: Int? }
            let images: [Image]?
        }
        let (trackData, trackStatus) = try await get("/tracks/\(trackID)")
        guard (200..<300).contains(trackStatus),
              let artistID = try JSONDecoder().decode(Track.self, from: trackData).artists?.first?.id
        else { return nil }
        let (artistData, artistStatus) = try await get("/artists/\(artistID)")
        guard (200..<300).contains(artistStatus) else { return nil }
        let images = try JSONDecoder().decode(Artist.self, from: artistData).images ?? []
        return images.max { ($0.width ?? 0) < ($1.width ?? 0) }.flatMap { URL(string: $0.url) }
    }

    /// The song's Canvas video (an .mp4 loop), from Spotify's own `canvaz-cache` service, the one
    /// its apps use. Nil when the song has none or Spotify doesn't take this app's sign-in there.
    func canvasURL(trackURI: String) async throws -> URL? {
        var request = URLRequest(url: URL(string: "https://spclient.wg.spotify.com/canvaz-cache/v0/canvases")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        request.httpBody = CanvasProtobuf.request(trackURI: trackURI)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            SyncLog.log("canvas", "HTTP \(status)")
            return nil
        }
        return CanvasProtobuf.canvasURL(in: data, trackURI: trackURI)
    }
}

/// Just enough protobuf for `canvaz-cache`: `EntityCanvazRequest { repeated Entity entities = 1;
/// Entity { string entity_uri = 1; } }` out, `EntityCanvazResponse { repeated Canvaz canvases = 1;
/// Canvaz { string id = 1; string url = 2; ...; string entity_uri = 5; } }` back.
enum CanvasProtobuf {
    static func request(trackURI: String) -> Data {
        let entity = field(1, Data(trackURI.utf8))
        return field(1, entity)
    }

    static func canvasURL(in data: Data, trackURI: String) -> URL? {
        var fallback: URL?
        for (number, value) in fields(of: data) where number == 1 {
            var url: String?
            var uri: String?
            for (inner, innerValue) in fields(of: value) {
                if inner == 2 { url = String(data: innerValue, encoding: .utf8) }
                if inner == 5 { uri = String(data: innerValue, encoding: .utf8) }
            }
            guard let url, let parsed = URL(string: url), url.hasSuffix(".mp4") || url.contains(".mp4") else { continue }
            if uri == trackURI { return parsed }
            fallback = fallback ?? parsed
        }
        return fallback
    }

    /// A length-delimited field.
    private static func field(_ number: Int, _ payload: Data) -> Data {
        var out = varint(UInt64(number << 3 | 2))
        out.append(varint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    /// The length-delimited fields of a message, in order; other wire types are skipped.
    private static func fields(of data: Data) -> [(Int, Data)] {
        let bytes = [UInt8](data)
        var result: [(Int, Data)] = []
        var index = 0
        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = readVarint() else { break }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard readVarint() != nil else { return result }
            case 1:
                index += 8
            case 2:
                guard let length = readVarint(), index + Int(length) <= bytes.count else { return result }
                result.append((number, Data(bytes[index..<index + Int(length)])))
                index += Int(length)
            case 5:
                index += 4
            default:
                return result
            }
        }
        return result
    }
}

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

    /// Spicy Lyrics' Canvas service, also used by the Android app. No Spotify OAuth required.
    func canvasURL(trackURI: String) async throws -> URL? {
        guard trackURI.hasPrefix("spotify:track:") else { return nil }
        return try await SpotifyCanvasService.shared.find(trackID: String(trackURI.dropFirst("spotify:track:".count)))
    }
}

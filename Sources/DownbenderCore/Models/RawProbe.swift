struct RawFormat: Decodable {
    let formatID: String
    let height: Int?
    let vcodec: String?
    let acodec: String?
    let ext: String?
    let tbr: Double?
    let filesize: Int64?
    let filesizeApprox: Int64?
    let proto: String?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case height, vcodec, acodec, ext, tbr, filesize
        case filesizeApprox = "filesize_approx"
        case proto = "protocol"
    }
}

/// Decodes ANYTHING and keeps nothing: for dictionaries where only the keys matter
/// and the value shape varies across sites.
struct RawIgnoredValue: Decodable {
    init(from decoder: Decoder) throws {}
}

struct RawProbe: Decodable {
    let id: String
    let title: String
    let thumbnail: String?
    let duration: Double?
    let formats: [RawFormat]
    /// Creator-uploaded tracks only; `automatic_captions` is deliberately NOT decoded.
    let subtitles: [String: RawIgnoredValue]?
}

/// Only sniffs `_type` to route parsing; yt-dlp omits it on plain videos.
struct RawTypeProbe: Decodable {
    let type: String?

    enum CodingKeys: String, CodingKey {
        case type = "_type"
    }
}

struct RawThumbnail: Decodable {
    let url: String?
}

struct RawPlaylistEntry: Decodable {
    let id: String?
    let url: String?
    let title: String?
    let ieKey: String?
    let thumbnails: [RawThumbnail]?

    enum CodingKeys: String, CodingKey {
        case id, url, title, thumbnails
        case ieKey = "ie_key"
    }
}

struct RawPlaylist: Decodable {
    let title: String?
    let entries: [RawPlaylistEntry]?
}

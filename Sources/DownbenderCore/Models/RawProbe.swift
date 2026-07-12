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

struct RawProbe: Decodable {
    let id: String
    let title: String
    let thumbnail: String?
    let duration: Double?
    let formats: [RawFormat]
}

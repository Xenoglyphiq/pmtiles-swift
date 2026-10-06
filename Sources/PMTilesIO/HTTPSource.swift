// HTTP range-request source. Uses Foundation's URLSession (FoundationNetworking on Linux).

#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking
#else
import Foundation
#endif

/// Reads byte ranges from a URL with HTTP `Range` requests.
public struct HTTPSource: ByteSource {
    public let url: URL
    private let session: URLSession

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func read(offset: UInt64, length: UInt64) async throws(PMTilesError) -> [UInt8] {
        if length == 0 { return [] }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        // Ask for the bytes as stored. Some servers otherwise apply the range to a
        // gzip-encoded representation of the file (different length, different bytes),
        // and URLSession silently decodes that, so the result is neither range.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PMTilesError(.io, "pmtiles.source_failed")
        }
        guard let http = response as? HTTPURLResponse else { throw PMTilesError(.io, "pmtiles.source_failed") }
        switch http.statusCode {
        case 206:
            return [UInt8](data)
        case 200:
            // The server ignored Range and sent the whole file: take the slice.
            let start = Int(min(offset, UInt64(data.count)))
            let end = Int(min(offset + length, UInt64(data.count)))
            return [UInt8](data[start..<end])
        default:
            throw PMTilesError(.io, "pmtiles.source_failed")
        }
    }
}

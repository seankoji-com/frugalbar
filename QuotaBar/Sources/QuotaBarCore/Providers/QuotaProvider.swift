import Foundation

// MARK: - Provider adapter protocol

public protocol QuotaProvider: Sendable {
    var vendorId: VendorIdentifier { get }
    var displayName: String { get }
    var category: MetricCategory { get }
    func fetchSnapshot() async throws -> QuotaSnapshot
}

// MARK: - Shared HTTP utilities

enum QuotaHTTP {

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4.0
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    static func get(url: String, headers: [String: String] = [:], key: String?) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        if let key {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

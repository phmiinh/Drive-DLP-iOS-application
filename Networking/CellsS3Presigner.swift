import CryptoKit
import Foundation

struct CellsS3Request {
    let url: URL
    let headers: [String: String]
}

final class CellsS3Presigner {
    private let region = "us-east-1"
    private let service = "s3"
    private let gatewaySecret = "gatewaysecret"
    private let tokenQueryKey = "pydio_jwt"

    func presign(
        serverURL: URL,
        bucket: String,
        key: String,
        method: String,
        accessToken: String,
        expiresIn: Int = 900,
        contentType: String? = nil,
        extraQueryItems: [URLQueryItem] = []
    ) throws -> CellsS3Request {
        let now = Date()
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = Self.dateStampFormatter.string(from: now)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"

        let canonicalURI = canonicalURI(
            serverPath: serverURL.path,
            bucket: bucket,
            key: key
        )
        let host = hostHeader(from: serverURL)

        var headers: [String: String] = ["host": host]
        if let contentType, !contentType.isEmpty {
            headers["content-type"] = contentType
        }

        let signedHeaders = headers.keys.sorted().joined(separator: ";")
        let canonicalHeaders = headers.keys.sorted().map {
            "\($0):\(headers[$0] ?? "")\n"
        }.joined()

        var queryItems = extraQueryItems
        queryItems.append(URLQueryItem(name: tokenQueryKey, value: accessToken))
        queryItems.append(URLQueryItem(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"))
        queryItems.append(URLQueryItem(name: "X-Amz-Credential", value: "\(accessToken)/\(scope)"))
        queryItems.append(URLQueryItem(name: "X-Amz-Date", value: amzDate))
        queryItems.append(URLQueryItem(name: "X-Amz-Expires", value: String(expiresIn)))
        queryItems.append(URLQueryItem(name: "X-Amz-SignedHeaders", value: signedHeaders))

        let canonicalQuery = queryItems
            .map { (Self.rfc3986Encode($0.name), Self.rfc3986Encode($0.value ?? "")) }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 {
                    return lhs.0 < rhs.0
                }
                return lhs.1 < rhs.1
            }
            .map { "\($0)=\($1)" }
            .joined(separator: "&")

        let canonicalRequest = [
            method.uppercased(),
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(canonicalRequest)
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(
            secret: gatewaySecret,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: signingKey)
        )
        let signatureHex = Data(signature).map { String(format: "%02x", $0) }.joined()

        var urlComponents = URLComponents()
        urlComponents.scheme = serverURL.scheme
        urlComponents.host = serverURL.host
        urlComponents.port = serverURL.port
        urlComponents.percentEncodedPath = canonicalURI
        urlComponents.percentEncodedQuery = canonicalQuery + "&X-Amz-Signature=" + signatureHex

        guard let url = urlComponents.url else {
            throw AppError.unexpected("Could not build the Cells S3 request URL.")
        }

        var requestHeaders: [String: String] = [:]
        if let contentType, !contentType.isEmpty {
            requestHeaders["Content-Type"] = contentType
        }
        return CellsS3Request(url: url, headers: requestHeaders)
    }

    private func canonicalURI(serverPath: String, bucket: String, key: String) -> String {
        let serverComponents = serverPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let keyComponents = key
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let all = serverComponents + [bucket] + keyComponents
        return "/" + all.map(Self.rfc3986Encode).joined(separator: "/")
    }

    private func hostHeader(from url: URL) -> String {
        if let port = url.port, let host = url.host {
            return "\(host):\(port)"
        }
        return url.host ?? url.absoluteString
    }

    private static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static func signingKey(
        secret: String,
        dateStamp: String,
        region: String,
        service: String
    ) -> Data {
        let kDate = hmac(data: Data(dateStamp.utf8), key: Data(("AWS4" + secret).utf8))
        let kRegion = hmac(data: Data(region.utf8), key: kDate)
        let kService = hmac(data: Data(service.utf8), key: kRegion)
        return hmac(data: Data("aws4_request".utf8), key: kService)
    }

    private static func hmac(data: Data, key: Data) -> Data {
        let key = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(signature)
    }

    private static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func rfc3986Encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

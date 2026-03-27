import Foundation

private final class TransferInsecureSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

final class TransferSessionFactory {
    private let secureSession: URLSession
    private let insecureSession: URLSession
    private let insecureDelegate = TransferInsecureSessionDelegate()

    init() {
        let secureConfiguration = URLSessionConfiguration.default
        secureConfiguration.waitsForConnectivity = true
        secureConfiguration.timeoutIntervalForRequest = 60
        secureConfiguration.timeoutIntervalForResource = 3600
        secureSession = URLSession(configuration: secureConfiguration)

        let insecureConfiguration = URLSessionConfiguration.default
        insecureConfiguration.waitsForConnectivity = true
        insecureConfiguration.timeoutIntervalForRequest = 60
        insecureConfiguration.timeoutIntervalForResource = 3600
        insecureSession = URLSession(
            configuration: insecureConfiguration,
            delegate: insecureDelegate,
            delegateQueue: nil
        )
    }

    func session(skipTLSVerification: Bool) -> URLSession {
        skipTLSVerification ? insecureSession : secureSession
    }
}

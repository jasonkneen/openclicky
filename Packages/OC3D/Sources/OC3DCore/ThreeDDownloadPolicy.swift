// ThreeDDownloadPolicy.swift
// Provider-neutral safety check for URLs a generation provider is about to
// download from. Providers hand back model/thumbnail URLs from a remote API,
// so those URLs are untrusted input: this refuses anything that is not plain
// HTTPS, carries credentials, or points at loopback, link-local or private
// network space (SSRF).

import Foundation

public enum ThreeDDownloadPolicy {
    /// HTTPS, no userinfo, and a host that is not loopback / link-local /
    /// private / raw IPv6.
    public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              !isBlockedDownloadHost(host) else {
            return false
        }
        return true
    }

    public static func isBlockedDownloadHost(_ host: String) -> Bool {
        let stripped = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if stripped == "localhost" || stripped == "::1" || stripped.hasSuffix(".local") {
            return true
        }
        // Any colon means an IPv6 literal; block the whole family rather than
        // trying to enumerate its private ranges.
        if stripped.contains(":") {
            return true
        }

        let octets = stripped.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch octets[0] {
        case 0, 10, 127:
            return true
        case 169 where octets[1] == 254:
            return true
        case 172 where (16...31).contains(octets[1]):
            return true
        case 192 where octets[1] == 168:
            return true
        default:
            return false
        }
    }
}

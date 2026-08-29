import Foundation

public enum PhishingScorer {
    public static let blockThreshold = 55

    public static let suspiciousTLDs = [
        "zip", "mov", "tk", "ml", "ga", "cf", "gq", "top", "xyz", "icu", "click",
        "country",
    ]

    public static let brandKeywords = [
        "paypal", "apple", "microsoft", "google", "amazon", "facebook", "instagram",
        "netflix", "bank", "chase", "wellsfargo", "icloud", "outlook", "office365",
        "binance", "coinbase", "alipay", "taobao", "wechat",
    ]

    public static func scoreURL(
        _ urlString: String,
        allowlist: [String] = []
    ) -> PhishAssessment {
        guard let parsed = parse(urlString) else {
            return PhishAssessment(
                score: 100,
                severity: .critical,
                reasons: [PhishReason(code: "invalid_url", weight: 100, detail: urlString)],
                shouldBlock: true,
                url: urlString
            )
        }

        let host = parsed.host
        if allowlist.contains(where: { entry in
            let candidate = entry.lowercased()
            return host == candidate || host.hasSuffix(".\(candidate)")
        }) {
            return PhishAssessment(
                score: 0,
                severity: .low,
                reasons: [PhishReason(code: "allowlisted", weight: 0)],
                shouldBlock: false,
                url: urlString
            )
        }

        var score = 0
        var reasons: [PhishReason] = []

        if parsed.scheme == "http" {
            score += 12
            reasons.append(PhishReason(code: "insecure_http", weight: 12))
        }
        if looksLikeIPAddress(host) {
            score += 35
            reasons.append(PhishReason(code: "ip_hostname", weight: 35, detail: host))
        }
        if host.contains("xn--") {
            score += 25
            reasons.append(PhishReason(code: "punycode_host", weight: 25, detail: host))
        }
        if host.split(separator: ".", omittingEmptySubsequences: false).count >= 5 {
            score += 15
            reasons.append(PhishReason(code: "deep_subdomain", weight: 15, detail: host))
        }

        let tld = host.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if suspiciousTLDs.contains(tld) {
            score += 18
            reasons.append(PhishReason(code: "suspicious_tld", weight: 18, detail: tld))
        }

        let spoof = brandSpoof(in: host)
        if let spoof {
            let weight = spoof.reason == "brand_lookalike_host" ? 40 : 30
            score += weight
            reasons.append(PhishReason(code: spoof.reason, weight: weight, detail: spoof.brand))
        }

        if let brand = brandInPath(parsed.path, host: host) {
            score += 15
            reasons.append(PhishReason(code: "brand_in_path", weight: 15, detail: brand))
        }

        let pathTokens = safelyDecoded(parsed.path).lowercased().split { !$0.isASCII || !$0.isLetter && !$0.isNumber }
        if let credentialWord = credentialPathWords.first(where: { pathTokens.contains(Substring($0)) }) {
            score += 10
            reasons.append(PhishReason(code: "credential_path", weight: 10, detail: credentialWord))
        }

        if shortenerHosts.contains(host) {
            score += 15
            reasons.append(PhishReason(code: "shortened_url", weight: 15, detail: host))
        }
        if !parsed.username.isEmpty || urlString.contains("@") {
            score += 20
            reasons.append(PhishReason(code: "at_symbol_trick", weight: 20))
        }

        return finish(url: urlString, score: score, reasons: reasons)
    }

    public static func assess(
        _ snapshot: PolicyPageSnapshot,
        allowlist: [String] = []
    ) -> PhishAssessment {
        let urlOnly = scoreURL(snapshot.url, allowlist: allowlist)
        if urlOnly.reasons.first?.code == "allowlisted" || urlOnly.reasons.first?.code == "invalid_url" {
            return urlOnly
        }

        var score = urlOnly.score
        var reasons = urlOnly.reasons
        let spoofBrand = reasons.first(where: {
            $0.code == "brand_spoof_host" || $0.code == "brand_lookalike_host"
        })?.detail
        let isIP = reasons.contains { $0.code == "ip_hostname" }
        let isPunycode = reasons.contains { $0.code == "punycode_host" }
        let isHTTP = parse(snapshot.url)?.scheme == "http"

        let text = "\(snapshot.title)\n\(snapshot.textSample)".lowercased()
        if let phrase = urgencyPhrases.first(where: { text.contains($0.lowercased()) }) {
            score += 10
            reasons.append(PhishReason(code: "urgency_language", weight: 10, detail: phrase))
        }

        if snapshot.passwordFields > 0, snapshot.crossSiteFormActions > 0 {
            score += 45
            reasons.append(
                PhishReason(
                    code: "cross_site_credential_submit",
                    weight: 45,
                    detail: "crossSiteForms=\(snapshot.crossSiteFormActions)"
                )
            )
        } else if snapshot.passwordFields > 0,
                  spoofBrand != nil || isIP || isHTTP || isPunycode {
            let weight = isPunycode ? 30 : 25
            score += weight
            reasons.append(
                PhishReason(
                    code: "password_on_risky_origin",
                    weight: weight,
                    detail: "passwordFields=\(snapshot.passwordFields)"
                )
            )
        } else if snapshot.passwordFields > 0, snapshot.forms > 0, score >= 20 {
            score += 12
            reasons.append(PhishReason(code: "credential_form", weight: 12))
        }

        if snapshot.passwordFields > 0,
           let pageBrand = brandKeywords.first(where: { text.contains($0) }),
           spoofBrand == nil {
            score += 15
            reasons.append(
                PhishReason(code: "brand_credential_page", weight: 15, detail: pageBrand)
            )
        }

        return finish(url: snapshot.url, score: score, reasons: reasons)
    }

    public static func applyLocalFeedback(
        _ assessment: PhishAssessment,
        feedbackHosts: [String: PhishFeedback]
    ) -> PhishAssessment {
        guard let host = parse(assessment.url)?.host,
              let vote = feedbackHosts[host] else {
            return assessment
        }

        switch vote {
        case .safe:
            let score = max(0, assessment.score - 40)
            return PhishAssessment(
                score: score,
                severity: severity(for: score),
                reasons: assessment.reasons + [
                    PhishReason(code: "local_feedback_safe", weight: -40),
                ],
                shouldBlock: score >= blockThreshold,
                url: assessment.url
            )
        case .phish:
            let score = min(100, assessment.score + 40)
            return PhishAssessment(
                score: score,
                severity: severity(for: score),
                reasons: assessment.reasons + [
                    PhishReason(code: "local_feedback_phish", weight: 40),
                ],
                shouldBlock: true,
                url: assessment.url
            )
        }
    }

    private struct ParsedURL {
        let scheme: String
        let host: String
        let path: String
        let username: String
    }

    private static let commonSecondLevelSuffixes: Set<String> = [
        "co.uk", "com.au", "com.br", "com.cn", "com.hk", "co.jp", "co.kr",
    ]

    private static let shortenerHosts: Set<String> = [
        "bit.ly", "buff.ly", "cutt.ly", "is.gd", "ow.ly", "rb.gy", "rebrand.ly",
        "shorturl.at", "t.co", "tinyurl.com",
    ]

    private static let credentialPathWords = [
        "account", "auth", "confirm", "login", "password", "secure", "signin", "verify",
        "wallet",
    ]

    private static let urgencyPhrases = [
        "verify your account", "confirm your identity", "suspend", "unusual activity", "act now",
        "password expired", "login immediately", "账户异常", "立即验证", "密码过期", "異常登入",
        "立即驗證",
    ]

    private static func parse(_ rawURL: String) -> ParsedURL? {
        guard let components = URLComponents(string: rawURL),
              let rawScheme = components.scheme,
              !rawScheme.isEmpty else {
            return nil
        }
        let scheme = rawScheme.lowercased()
        if (scheme == "http" || scheme == "https"), components.host == nil {
            return nil
        }
        return ParsedURL(
            scheme: scheme,
            host: (components.url?.host ?? components.host ?? "").lowercased(),
            path: components.percentEncodedPath,
            username: components.user ?? ""
        )
    }

    private static func looksLikeIPAddress(_ host: String) -> Bool {
        let ipv4 = host.range(
            of: #"^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$"#,
            options: .regularExpression
        ) != nil
        return ipv4 || host.contains(":")
    }

    private static func registrableLabel(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        let suffix = labels.suffix(2).joined(separator: ".")
        let index = commonSecondLevelSuffixes.contains(suffix) ? labels.count - 3 : labels.count - 2
        guard !labels.isEmpty else { return "" }
        return String(labels[max(0, index)])
    }

    private static func normalizeLookalike(_ label: String) -> String {
        label
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "i")
            .replacingOccurrences(of: "3", with: "e")
            .replacingOccurrences(of: "4", with: "a")
            .replacingOccurrences(of: "5", with: "s")
            .replacingOccurrences(of: "7", with: "t")
    }

    private static func isEditDistanceAtMostOne(_ left: String, _ right: String) -> Bool {
        let lhs = Array(left)
        let rhs = Array(right)
        guard abs(lhs.count - rhs.count) <= 1 else { return false }
        if lhs == rhs { return true }

        var leftIndex = 0
        var rightIndex = 0
        var edits = 0
        while leftIndex < lhs.count, rightIndex < rhs.count {
            if lhs[leftIndex] == rhs[rightIndex] {
                leftIndex += 1
                rightIndex += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if lhs.count > rhs.count {
                leftIndex += 1
            } else if rhs.count > lhs.count {
                rightIndex += 1
            } else {
                leftIndex += 1
                rightIndex += 1
            }
        }
        if leftIndex < lhs.count || rightIndex < rhs.count {
            edits += 1
        }
        return edits <= 1
    }

    private static func brandSpoof(in host: String) -> (brand: String, reason: String)? {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        let secondLevel = registrableLabel(host)
        for brand in brandKeywords {
            if secondLevel == brand { continue }
            let embedded = labels.contains { label in
                label == brand
                    || label.hasPrefix("\(brand)-")
                    || label.hasSuffix("-\(brand)")
                    || label.contains("-\(brand)-")
            }
            if embedded { return (brand, "brand_spoof_host") }
            if brand.count < 5 { continue }
            let lookalike = labels.contains { label in
                guard label.count >= 5, label != brand else { return false }
                let normalized = normalizeLookalike(label)
                return normalized == brand || isEditDistanceAtMostOne(normalized, brand)
            }
            if lookalike { return (brand, "brand_lookalike_host") }
        }
        return nil
    }

    private static func brandInPath(_ path: String, host: String) -> String? {
        let secondLevel = registrableLabel(host)
        let tokens = safelyDecoded(path).lowercased().split {
            !$0.isASCII || (!$0.isLetter && !$0.isNumber)
        }
        return brandKeywords.first { brand in
            brand != secondLevel && tokens.contains(Substring(brand))
        }
    }

    private static func safelyDecoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func finish(
        url: String,
        score: Int,
        reasons: [PhishReason]
    ) -> PhishAssessment {
        let clamped = min(100, score)
        return PhishAssessment(
            score: clamped,
            severity: severity(for: clamped),
            reasons: reasons,
            shouldBlock: clamped >= blockThreshold,
            url: url
        )
    }

    private static func severity(for score: Int) -> PhishSeverity {
        if score >= 80 { return .critical }
        if score >= 55 { return .high }
        if score >= 30 { return .medium }
        return .low
    }
}

public enum PhishFeedback: String, Codable, Equatable, Sendable {
    case safe
    case phish
}

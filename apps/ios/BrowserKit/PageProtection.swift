import AegisPolicyKit
import Foundation
import WebKit

public struct PageProtectionIncident: Equatable, Sendable {
    public let url: URL
    public let reasons: [String]
    public let score: Int
    public let fromPage: Bool
    public var explanations: [String] {
        let mappings: [(String, String)] = [
            ("known_phishing_host", String(localized: "命中本地已知钓鱼主机规则。")),
            ("cross_site_credential_submit", String(localized: "密码表单将提交到不同网站。")),
            ("brand_spoof_host", String(localized: "网址包含与注册域不符的品牌名称。")),
            ("brand_lookalike_host", String(localized: "网址疑似使用品牌近似拼写。")),
            ("password_on_risky_origin", String(localized: "登录表单所在来源存在额外风险。")),
            ("insecure_http", String(localized: "此网址使用未加密的 HTTP。")),
            ("ip_hostname", String(localized: "此网址以 IP 地址代替域名。"))
        ]
        return Array(mappings.filter { reasons.contains($0.0) }.prefix(4).map(\.1))
    }
}

enum PageProtection {
    /// 在隔离世界运行。只提取结构，绝不读取 value、文本正文或表单序列化结果。
    static let structureScript = """
    const passwords = [...document.querySelectorAll('input[type=password]')].slice(0, 32);
    const forms = [...new Set(passwords.map(input => input.form).filter(Boolean))];
    return {url: location.href, title: document.title.slice(0, 256), passwords: passwords.length,
      forms: forms.length, actions: forms.map(form => {try {return new URL(form.action || location.href, location.href).origin;} catch {return '';}}),
      frames: [...document.querySelectorAll('iframe')].slice(0, 16).map(frame => {try {return new URL(frame.src, location.href).origin;} catch {return '';}})};
    """

    static func assessment(_ raw: [String: Any], url: URL) -> PhishAssessment? {
        guard raw["url"] as? String == url.absoluteString,
              let passwords = raw["passwords"] as? Int, (0...32).contains(passwords),
              let forms = raw["forms"] as? Int, (0...32).contains(forms),
              let actions = raw["actions"] as? [String], actions.count <= 32,
              let title = raw["title"] as? String, title.count <= 256 else { return nil }
        let domain = url.host.flatMap(RegisteredDomain.of)
        let crossSite = actions.filter { action in
            guard let target = URL(string: action), let host = target.host else { return true }
            if target.scheme != url.scheme { return true }
            if let domain { return RegisteredDomain.of(host) != domain }
            return target.host != url.host
        }.count
        return PhishingScorer.assess(PolicyPageSnapshot(url: url.absoluteString, title: title, textSample: "",
            forms: forms, passwordFields: passwords, crossSiteFormActions: crossSite))
    }

    static func shouldUnload(_ assessment: PhishAssessment) -> Bool {
        let reasons = Set(assessment.reasons.map(\.code))
        // 正常跨站身份认证、HTTP 测试页和单个国际化域名信号不足以卸载页面。
        return assessment.score >= 80 && (!reasons.isDisjoint(with: ["brand_spoof_host", "brand_lookalike_host"])
            || reasons.contains("cross_site_credential_submit"))
    }

    /// 页面世界附加限制：不伪造输出；Worker、OffscreenCanvas 及页面恢复原函数仍可能绕过。
    static let fingerprintScript = """
    (() => {
      if (globalThis.__aegisFingerprintInstalled) return;
      Object.defineProperty(globalThis, '__aegisFingerprintInstalled', {value:true});
      const counts = {canvas:0, webgl:0, audio:0, worker:0, wasm:0};
      const strict = __STRICT__;
      const wrap = (proto, name, category, blocked, special) => {
        if (!proto || typeof proto[name] !== 'function') return;
        const original = proto[name];
        try { Object.defineProperty(proto, name, {configurable:true, writable:true, value:function(...args) {
          counts[category] = Math.min(1000, counts[category] + 1);
          if (strict && blocked && (!special || special(args))) throw new DOMException('Aegis strict protection', 'SecurityError');
          return Reflect.apply(original, this, args);
        }}); } catch {}
      };
      wrap(globalThis.HTMLCanvasElement?.prototype, 'toDataURL', 'canvas', true);
      wrap(globalThis.HTMLCanvasElement?.prototype, 'toBlob', 'canvas', true);
      wrap(globalThis.CanvasRenderingContext2D?.prototype, 'getImageData', 'canvas', true);
      for (const proto of [globalThis.WebGLRenderingContext?.prototype, globalThis.WebGL2RenderingContext?.prototype]) {
        wrap(proto, 'readPixels', 'webgl', true);
        wrap(proto, 'getParameter', 'webgl', true, args => [37445,37446].includes(args[0]));
      }
      wrap(globalThis.AudioBuffer?.prototype, 'getChannelData', 'audio', true);
      wrap(globalThis.AudioBuffer?.prototype, 'copyFromChannel', 'audio', true);
      wrap(globalThis.AnalyserNode?.prototype, 'getFloatFrequencyData', 'audio', true);
      wrap(globalThis.AnalyserNode?.prototype, 'getByteFrequencyData', 'audio', true);
      wrap(globalThis.AnalyserNode?.prototype, 'getFloatTimeDomainData', 'audio', true);
      wrap(globalThis.AnalyserNode?.prototype, 'getByteTimeDomainData', 'audio', true);
      if (globalThis.Worker) {const Original = Worker; globalThis.Worker = new Proxy(Original, {construct(target,args,newTarget) {counts.worker = Math.min(1000,counts.worker+1);return Reflect.construct(target,args,newTarget);}});}
      wrap(globalThis.WebAssembly, 'instantiate', 'wasm', false);
      wrap(globalThis.WebAssembly, 'instantiateStreaming', 'wasm', false);
      Object.defineProperty(globalThis, '__aegisProtectionCounts', {get:() => ({...counts})});
    })();
    """

    @MainActor static func applySystem(_ configuration: WKWebViewConfiguration, hardened: Bool) {
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.upgradeKnownHostsToHTTPS = true
        applySystem(configuration.defaultWebpagePreferences, hardened: hardened)
    }
    @MainActor static func applySystem(_ preferences: WKWebpagePreferences, hardened: Bool) {
        preferences.preferredHTTPSNavigationPolicy = .userMediatedFallbackToHTTP
        // 从不将系统的 Lockdown 偏好设为 false。
        if #available(iOS 26.5, *), !preferences.isLockdownModeEnabled, preferences.securityRestrictionMode != .lockdown {
            preferences.securityRestrictionMode = hardened ? .maximizeCompatibility : .none
        }
    }
}

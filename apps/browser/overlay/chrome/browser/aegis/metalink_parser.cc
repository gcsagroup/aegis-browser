// Copyright 2026 GCSA

#include "chrome/browser/aegis/metalink_parser.h"

#include <algorithm>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "net/base/ip_address.h"
#include "net/base/url_util.h"
#include "services/data_decoder/public/cpp/data_decoder.h"
#include "services/data_decoder/public/cpp/safe_xml_parser.h"
#include "services/data_decoder/public/mojom/xml_parser.mojom.h"

namespace aegis {
namespace {

constexpr size_t kMaxMetalinkBytes = 1024 * 1024;
constexpr size_t kMaxMirrors = 16;
constexpr int64_t kMaxDeclaredFileBytes = 2LL * 1024 * 1024 * 1024 * 1024;
constexpr char kMetalinkNamespace[] = "urn:ietf:params:xml:ns:metalink";

std::string Qualified(const std::string& prefix, const char* name) {
  return data_decoder::GetXmlQualifiedName(prefix, name);
}

bool IsSafeFileName(const std::string& name) {
  return !name.empty() && name.size() <= 255 && name != "." && name != ".." &&
         name.find('/') == std::string::npos &&
         name.find('\\') == std::string::npos &&
         name.find('\0') == std::string::npos;
}

bool IsAllowedMirrorUrl(const GURL& url) {
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || url.has_username() ||
      url.has_password() || url.has_ref() || url.host().empty() ||
      net::HostStringIsLocalhost(url.host())) {
    return false;
  }
  if (std::optional<net::IPAddress> literal =
          net::IPAddress::FromIPLiteral(url.HostNoBrackets())) {
    return literal->IsPubliclyRoutable();
  }
  return true;
}

std::optional<std::string> ReadElementText(const base::Value& parent,
                                           const std::string& tag) {
  const base::Value* element =
      data_decoder::GetXmlElementChildWithTag(parent, tag);
  std::string text;
  if (!element || !data_decoder::GetXmlElementText(*element, &text)) {
    return std::nullopt;
  }
  base::TrimWhitespaceASCII(text, base::TRIM_ALL, &text);
  return text;
}

MetalinkParseResult ParseMetalinkValue(const base::Value& root) {
  MetalinkParseResult result;
  std::string prefix;
  if (!data_decoder::GetXmlElementNamespacePrefix(root, kMetalinkNamespace,
                                                  &prefix) ||
      !data_decoder::IsXmlElementNamed(root, Qualified(prefix, "metalink"))) {
    result.error = "不是 RFC 5854 Metalink 文档";
    return result;
  }

  std::vector<const base::Value*> files;
  data_decoder::GetAllXmlElementChildrenWithTag(root, Qualified(prefix, "file"),
                                                &files);
  if (files.size() != 1) {
    result.error = "第一版只接受恰好一个 file";
    return result;
  }
  const base::Value& file = *files.front();
  result.file_name = data_decoder::GetXmlElementAttribute(file, "name");
  if (!IsSafeFileName(result.file_name)) {
    result.error = "文件名不安全";
    return result;
  }

  if (std::optional<std::string> size_text =
          ReadElementText(file, Qualified(prefix, "size"))) {
    if (!base::StringToInt64(*size_text, &result.file_size) ||
        result.file_size < 0 || result.file_size > kMaxDeclaredFileBytes) {
      result.error = "文件大小无效或超过 2 TiB";
      return result;
    }
  }

  std::vector<const base::Value*> hashes;
  data_decoder::GetAllXmlElementChildrenWithTag(file, Qualified(prefix, "hash"),
                                                &hashes);
  for (const base::Value* hash : hashes) {
    std::string type =
        base::ToLowerASCII(data_decoder::GetXmlElementAttribute(*hash, "type"));
    base::RemoveChars(type, "-", &type);
    const size_t expected_length = type == "sha512"   ? 128
                                   : type == "sha256" ? 64
                                                      : 0;
    std::string hash_hex;
    if (expected_length && data_decoder::GetXmlElementText(*hash, &hash_hex)) {
      base::TrimWhitespaceASCII(hash_hex, base::TRIM_ALL, &hash_hex);
      std::vector<uint8_t> decoded;
      if (hash_hex.size() == expected_length &&
          base::HexStringToBytes(hash_hex, &decoded)) {
        result.hash_algorithm = type == "sha512" ? "sha-512" : "sha-256";
        result.hash_hex = base::ToLowerASCII(hash_hex);
        break;
      }
    }
  }
  if (result.hash_hex.empty()) {
    result.error = "缺少有效的 SHA-256 或 SHA-512";
    return result;
  }

  std::vector<const base::Value*> urls;
  data_decoder::GetAllXmlElementChildrenWithTag(file, Qualified(prefix, "url"),
                                                &urls);
  for (const base::Value* element : urls) {
    if (result.mirrors.size() >= kMaxMirrors) {
      break;
    }
    std::string url_text;
    if (!data_decoder::GetXmlElementText(*element, &url_text)) {
      continue;
    }
    base::TrimWhitespaceASCII(url_text, base::TRIM_ALL, &url_text);
    GURL url(url_text);
    if (!IsAllowedMirrorUrl(url)) {
      continue;
    }
    int priority = 999999;
    const std::string priority_text =
        data_decoder::GetXmlElementAttribute(*element, "priority");
    if (!priority_text.empty() &&
        (!base::StringToInt(priority_text, &priority) || priority < 1)) {
      continue;
    }
    if (std::ranges::any_of(result.mirrors, [&url](const MetalinkMirror& item) {
          return item.url == url;
        })) {
      continue;
    }
    result.mirrors.push_back({std::move(url), priority});
  }
  std::ranges::stable_sort(
      result.mirrors, {},
      [](const MetalinkMirror& mirror) { return mirror.priority; });
  if (result.mirrors.empty()) {
    result.error = "没有可用的公开 HTTP(S) 镜像";
    return result;
  }
  result.ok = true;
  return result;
}

void OnXmlParsed(MetalinkParseCallback callback,
                 data_decoder::DataDecoder::ValueOrError parsed) {
  if (!parsed.has_value()) {
    MetalinkParseResult result;
    result.error = "Metalink XML 解析失败";
    std::move(callback).Run(std::move(result));
    return;
  }
  std::move(callback).Run(ParseMetalinkValue(*parsed));
}

}  // namespace

void ParseMetalink(std::string xml, MetalinkParseCallback callback) {
  if (xml.empty() || xml.size() > kMaxMetalinkBytes) {
    MetalinkParseResult result;
    result.error = "Metalink 文档为空或超过 1 MiB";
    std::move(callback).Run(std::move(result));
    return;
  }
  data_decoder::DataDecoder::ParseXmlIsolated(
      xml, data_decoder::mojom::XmlParser::WhitespaceBehavior::kIgnore,
      base::BindOnce(&OnXmlParsed, std::move(callback)));
}

MetalinkParseResult ParseMetalinkValueForTesting(const base::Value& root) {
  return ParseMetalinkValue(root);
}

}  // namespace aegis

// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_CORE_LOG_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_CORE_LOG_H_

#include <algorithm>
#include <array>
#include <deque>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace aegis::access {
inline constexpr std::array<std::string_view, 5> kCoreLogLevels = {
    "debug", "info", "warning", "error", "none"};
inline int CoreLogRank(std::string_view value) {
  auto it = std::find(kCoreLogLevels.begin(), kCoreLogLevels.end(), value);
  return it == kCoreLogLevels.end()
             ? 2
             : static_cast<int>(it - kCoreLogLevels.begin());
}

// Xray's text protocol is not an escaping boundary: messages may include
// request URLs, auth, node configuration, local paths, or remote error text.
// Reconstruct only recognized grammar; never put an arbitrary suffix on screen.
class AccessCoreLog {
 public:
  AccessCoreLog();
  ~AccessCoreLog();
  void SetLevel(std::string_view level) {
    rank_ = CoreLogRank(level);
    std::erase_if(lines_, [this](const Entry& e) { return e.rank < rank_; });
  }
  std::string_view level() const { return kCoreLogLevels[rank_]; }
  void Clear() { lines_.clear(); }
  std::string Snapshot() const {
    std::string result;
    for (const auto& entry : lines_) {
      if (!result.empty())
        result += '\n';
      result += entry.text;
    }
    return result;
  }
  bool Add(std::string_view line,
           const std::vector<std::string>& protected_values = {}) {
    if (rank_ == 4)
      return false;
    // Go's stdlib timestamp, with optional microseconds.
    constexpr std::string_view mask = "dddd/dd/dd dd:dd:dd";
    if (line.size() < mask.size() + 1)
      return false;
    for (size_t i = 0; i < mask.size(); ++i) {
      if (mask[i] == 'd' ? !Digit(line[i]) : line[i] != mask[i])
        return false;
    }
    size_t pos = mask.size();
    if (line[pos] == '.') {
      if (line.size() < pos + 8)
        return false;
      for (size_t i = 1; i <= 6; ++i)
        if (!Digit(line[pos + i]))
          return false;
      pos += 7;
    }
    if (line[pos++] != ' ')
      return false;
    std::string safe(line.substr(0, pos));
    line.remove_prefix(pos);
    int severity = 1;
    if (line.starts_with("from ")) {
      // Access records are a separate Xray stream; show only at info/debug.
      const size_t separator = line.find(' ', 5);
      if (separator == line.npos)
        return false;
      line.remove_prefix(separator + 1);
      if (line.starts_with("accepted ")) {
        safe += "from [redacted] accepted ";
        line.remove_prefix(9);
      } else if (line.starts_with("rejected ")) {
        safe += "from [redacted] rejected ";
        line.remove_prefix(9);
      } else
        return false;
      auto target = line.substr(0, line.find(' '));
      // Xray HTTP emits request.URL (including path/query); CONNECT can
      // arrive as an authority without a scheme. Keep only the authority.
      std::string normalized;
      if (target.starts_with("http://") || target.starts_with("https://") ||
          target.starts_with("//")) {
        const bool https = target.starts_with("https://");
        target.remove_prefix(target.starts_with("//") ? 2 : (https ? 8 : 7));
        target = target.substr(0, target.find_first_of("/?#"));
        normalized = std::string(target);
        if (!target.empty() &&
            (target.find(':') == target.npos || target.ends_with("]")))
          normalized += https ? ":443" : ":80";
        target = normalized;
      }
      safe += SafeTarget(target, protected_values) ? target : "[redacted]";
    } else {
      constexpr std::string_view tags[] = {"[Debug] ", "[Info] ", "[Warning] ",
                                           "[Error] "};
      for (severity = 0; severity < 4 && !line.starts_with(tags[severity]);
           ++severity) {
      }
      if (severity == 4 || severity < rank_)
        return false;
      safe += tags[severity];
      line.remove_prefix(tags[severity].size());
      if (line.starts_with("[")) {
        size_t end = line.find("] ");
        if (end >= 2 && end <= 11 && Digits(line.substr(1, end - 1))) {
          safe += line.substr(0, end + 2);
          line.remove_prefix(end + 2);
        }
      }
      constexpr std::string_view modules[] = {"core",
                                              "app/log",
                                              "infra/conf/serial",
                                              "transport/internet",
                                              "transport/internet/tcp",
                                              "proxy/http",
                                              "proxy/vless/outbound",
                                              "app/dispatcher",
                                              "app/proxyman/inbound",
                                              "app/proxyman/outbound"};
      const size_t colon = line.find(": ");
      auto module = line.substr(0, colon);
      if (colon != line.npos &&
          std::find(std::begin(modules), std::end(modules), module) !=
              std::end(modules)) {
        safe += module;
        safe += ": ";
        line.remove_prefix(colon + 2);
        if (module == "core" && line.starts_with("Xray ") &&
            line.ends_with(" started") && line.size() > 13 &&
            line.size() <= 30 &&
            line.substr(5, line.size() - 13).find_first_not_of("0123456789.") ==
                line.npos) {
          safe += line;
        } else if (module == "app/log" && line == "Logger started") {
          safe += "Logger started";
        } else {
          constexpr std::string_view prefixes[] = {
              "Reading config:",
              "listening TCP on",
              "listening on",
              "dialing TCP to",
              "dialing to",
              "taking detour",
              "default route for",
              "received request for",
              "tunneling request to",
              "request to Method",
              "connection ends",
              "failed to read response from",
              "failed to process outbound traffic",
              "failed to pick route for"};
          for (auto prefix : prefixes) {
            if (line == prefix ||
                (line.starts_with(prefix) && line.size() > prefix.size() &&
                 line[prefix.size()] == ' ')) {
              safe += prefix;
              safe += ' ';
              break;
            }
          }
          safe += "[redacted]";
        }
      } else {
        safe += "[redacted]";
      }
    }
    if (severity < rank_)
      return false;
    if (lines_.size() == 128)
      lines_.pop_front();
    lines_.push_back({severity, std::move(safe)});
    return true;
  }

 private:
  // Only expose a narrow host:port token. No URL/userinfo, paths, queries,
  // HTTP headers, access email, tags or node parameters can pass this grammar.
  static bool SafeTarget(std::string_view target,
                         const std::vector<std::string>& secrets) {
    auto endpoint = target;
    if (endpoint.starts_with("tcp:") || endpoint.starts_with("udp:"))
      endpoint.remove_prefix(4);
    const auto colon = endpoint.rfind(':');
    if (colon == endpoint.npos || endpoint.size() > 265 || colon == 0)
      return false;
    auto host = endpoint.substr(0, colon);
    auto port = endpoint.substr(colon + 1);
    if (port.empty() || port.size() > 5 || !Digits(port))
      return false;
    int n = 0;
    for (char c : port)
      n = n * 10 + c - '0';
    if (n == 0 || n > 65535)
      return false;
    auto ascii_lower = [](char c) {
      return static_cast<char>(c >= 'A' && c <= 'Z' ? c + 32 : c);
    };
    if (host.front() == '[' && host.back() == ']') {
      host = host.substr(1, host.size() - 2);
      if (host.find(':') == host.npos ||
          host.find_first_not_of("0123456789ABCDEFabcdef:.") != host.npos)
        return false;
    } else {
      if (host.front() == '.' || host.back() == '.' ||
          host.find("..") != host.npos ||
          host.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRS"
                                 "TUVWXYZ0123456789-.") != host.npos)
        return false;
    }
    std::string normalized(endpoint);
    std::transform(normalized.begin(), normalized.end(), normalized.begin(),
                   ascii_lower);
    for (const auto& secret : secrets) {
      if (normalized.find(secret) != normalized.npos)
        return false;
    }
    return true;
  }
  static bool Digit(char c) { return c >= '0' && c <= '9'; }
  static bool Digits(std::string_view s) {
    return !s.empty() && std::all_of(s.begin(), s.end(), Digit);
  }
  struct Entry {
    int rank;
    std::string text;
  };
  int rank_ = 2;
  std::deque<Entry> lines_;
};

// Never interpret the tail of a truncated or split record as a fresh message.
class CoreLogFramer {
 public:
  template <typename Sink>
  void Feed(std::string_view bytes, Sink sink) {
    for (char c : bytes) {
      if (c == '\n') {
        if (!dropping_)
          sink(line_);
        line_.clear();
        dropping_ = false;
      } else if (!dropping_) {
        if (line_.size() == 4096) {
          line_.clear();
          dropping_ = true;
        } else
          line_ += c;
      }
    }
  }

 private:
  std::string line_;
  bool dropping_ = false;
};
}  // namespace aegis::access
#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_CORE_LOG_H_

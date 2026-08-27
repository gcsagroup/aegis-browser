// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_METALINK_PARSER_H_
#define CHROME_BROWSER_AEGIS_METALINK_PARSER_H_

#include <cstdint>
#include <string>
#include <vector>

#include "base/functional/callback_forward.h"
#include "base/values.h"
#include "url/gurl.h"

namespace aegis {

struct MetalinkMirror {
  GURL url;
  int priority = 999999;
};

struct MetalinkParseResult {
  bool ok = false;
  std::string error;
  std::string file_name;
  int64_t file_size = -1;
  std::string hash_algorithm;
  std::string hash_hex;
  std::vector<MetalinkMirror> mirrors;
};

using MetalinkParseCallback = base::OnceCallback<void(MetalinkParseResult)>;

// Parses untrusted RFC 5854 XML in the isolated Data Decoder service.
void ParseMetalink(std::string xml, MetalinkParseCallback callback);

// Exposed for deterministic unit tests after safe XML decoding.
MetalinkParseResult ParseMetalinkValueForTesting(const base::Value& root);

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_METALINK_PARSER_H_

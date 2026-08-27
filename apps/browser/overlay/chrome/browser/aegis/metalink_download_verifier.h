// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_METALINK_DOWNLOAD_VERIFIER_H_
#define CHROME_BROWSER_AEGIS_METALINK_DOWNLOAD_VERIFIER_H_

#include "chrome/browser/aegis/metalink_parser.h"

class Profile;

namespace download {
class DownloadItem;
}

namespace aegis {

enum class MetalinkVerificationStatus {
  kNone,
  kPending,
  kVerifying,
  kVerified,
  kFailed,
};

MetalinkVerificationStatus GetMetalinkVerificationStatus(
    const download::DownloadItem& item);
void SetMetalinkVerificationStatus(download::DownloadItem& item,
                                   MetalinkVerificationStatus status);

// Starts a Browser-native, credential-free mirror download. The verifier owns
// itself until the file hash matches or all mirrors fail.
void StartVerifiedMetalinkDownload(Profile* profile,
                                   MetalinkParseResult result);

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_METALINK_DOWNLOAD_VERIFIER_H_

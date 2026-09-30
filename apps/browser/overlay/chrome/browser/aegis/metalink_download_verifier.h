// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_METALINK_DOWNLOAD_VERIFIER_H_
#define CHROME_BROWSER_AEGIS_METALINK_DOWNLOAD_VERIFIER_H_

#include "base/functional/callback_forward.h"
#include "chrome/browser/aegis/metalink_parser.h"

class Profile;

namespace content {
class WebContents;
}

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
// 状态立即可读；观察者在当前回调结束后收到通知，销毁时撤销通知。
void SetMetalinkVerificationStatus(download::DownloadItem& item,
                                   MetalinkVerificationStatus status);

// 以发起页面关联原生匿名下载，供系统显示目录、重名及安全确认。
// 校验器持有自身，直到文件哈希匹配或镜像全部失败。
// 仅在下载管理器实际创建任务后返回成功；地址校验失败必须回传错误。
void StartVerifiedMetalinkDownload(
    Profile* profile,
    content::WebContents* source,
    MetalinkParseResult result,
    base::OnceCallback<void(bool, std::string)> started_callback);

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_METALINK_DOWNLOAD_VERIFIER_H_

// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_WEBPAGE_CAPTURE_H_
#define CHROME_BROWSER_AEGIS_WEBPAGE_CAPTURE_H_

#include <string>

namespace content {
class RenderFrameHost;
class WebContents;
}

namespace aegis {

inline constexpr char kCapturePageHost[] = "aegis-capture";
inline constexpr char kCapturePageUrl[] = "chrome://aegis-capture/";

struct CapturedWebpage {
  std::string png;
  bool ocr = false;
  bool too_large = false;
};

bool CanCaptureWebpage(content::WebContents* contents);
void CaptureFullWebpage(content::WebContents* contents);
void CaptureContextImage(content::RenderFrameHost* frame);
int BeginExternalPageCapture(content::WebContents* contents);
void FinishExternalPageCapture(content::WebContents* contents,
                               int operation,
                               std::string png);
CapturedWebpage TakeCapturedWebpage(content::WebContents* contents);

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_WEBPAGE_CAPTURE_H_

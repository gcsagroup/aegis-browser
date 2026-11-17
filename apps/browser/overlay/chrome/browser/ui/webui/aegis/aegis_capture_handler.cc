// Copyright 2026 GCSA
#include "chrome/browser/ui/webui/aegis/aegis_capture_handler.h"

#include <utility>

#include "base/base64.h"
#include "base/command_line.h"
#include "base/environment.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/strings/string_util.h"
#include "base/task/thread_pool.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/aegis/webpage_capture.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/aegis/pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "net/base/load_flags.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis {

#if BUILDFLAG(IS_MAC)
std::string RecognizeCaptureWithVision(std::string png);
#endif

namespace {

constexpr size_t kMaxUpload = 8 * 1024 * 1024;

GURL ValidateEndpoint(std::string_view input, bool allow_loopback = false) {
  if (input.size() > 2048) {
    return GURL();
  }
  const GURL url(base::TrimWhitespaceASCII(input, base::TRIM_ALL));
  if (!url.is_valid() || !url.has_host() || url.path() != "/v1/ocr" ||
      url.has_query() || url.has_ref() || url.has_username() ||
      url.has_password()) {
    return GURL();
  }
  return url.SchemeIs("https") ||
                 (allow_loopback && url.SchemeIs("http") &&
                  url.host() == "127.0.0.1")
             ? url
             : GURL();
}

GURL OfficialEndpoint() {
  const auto* command = base::CommandLine::ForCurrentProcess();
  if (command->HasSwitch("aegis-image-ocr-endpoint")) {
    return ValidateEndpoint(
        command->GetSwitchValueASCII("aegis-image-ocr-endpoint"),
        command->HasSwitch("aegis-image-ocr-loopback-test"));
  }
  return ValidateEndpoint(AEGIS_OCR_SERVICE_URL);
}

std::string Destination(const GURL& endpoint) {
  return endpoint.is_valid() ? url::Origin::Create(endpoint).Serialize() : "";
}

GURL CurrentEndpoint(content::WebUI* web_ui) {
  const auto* profile = Profile::FromWebUI(web_ui);
  if (!profile) {
    return GURL();
  }
  const auto& settings = profile->GetPrefs()->GetDict(prefs::kImageOcrSettings);
  const std::string* mode = settings.FindString("mode");
  if (!mode || *mode == "official") {
    return OfficialEndpoint();
  }
  const std::string* endpoint = settings.FindString("endpoint");
  return *mode == "custom" && endpoint ? ValidateEndpoint(*endpoint) : GURL();
}

bool IsBoundedPNG(std::string_view data) {
  const auto header = base::as_byte_span(data);
  if (header.size() < 24 ||
      !data.starts_with("\x89PNG\r\n\x1a\n") ||
      data.substr(12, 4) != "IHDR") {
    return false;
  }
  const auto read_size = [&header](size_t start) {
    return (static_cast<uint32_t>(header[start]) << 24) |
           (static_cast<uint32_t>(header[start + 1]) << 16) |
           (static_cast<uint32_t>(header[start + 2]) << 8) |
           header[start + 3];
  };
  const uint32_t width = read_size(16);
  const uint32_t height = read_size(20);
  return width && height && width <= 8192 && height <= 8192 &&
         width * height <= 12'000'000;
}

}  // namespace

base::DictValue ReadImageOcrSettings(const PrefService& profile_prefs) {
  auto settings = profile_prefs.GetDict(prefs::kImageOcrSettings).Clone();
  if (!settings.FindString("mode")) {
    settings.Set("mode", "official");
  }
  settings.Set("officialDestination", Destination(OfficialEndpoint()));
  return settings;
}

bool SaveImageOcrSettings(PrefService& profile_prefs,
                          const std::string& mode,
                          const std::string& endpoint) {
  const GURL url = ValidateEndpoint(endpoint);
  if ((mode != "official" && mode != "custom" && mode != "local") ||
      (mode == "custom" && !url.is_valid())) {
    return false;
  }
  auto settings = profile_prefs.GetDict(prefs::kImageOcrSettings).Clone();
  settings.Set("mode", mode);
  if (mode == "custom") {
    settings.Set("endpoint", url.spec());
  }
  profile_prefs.SetDict(prefs::kImageOcrSettings, std::move(settings));
  return true;
}

CaptureHandler::CaptureHandler() = default;
CaptureHandler::~CaptureHandler() = default;

void CaptureHandler::RegisterMessages() {
  web_ui()->RegisterMessageCallback(
      "aegisCaptureTakeImage",
      base::BindRepeating(&CaptureHandler::TakeImage, base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "aegisCaptureLocalOCR",
      base::BindRepeating(&CaptureHandler::RecognizeLocally, base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "aegisCaptureGetRemoteDestination",
      base::BindRepeating(&CaptureHandler::GetRemoteDestination,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "aegisCapturePrepareRemoteRequest",
      base::BindRepeating(&CaptureHandler::PrepareRemoteRequest,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "aegisCaptureRemoteOCRRequiringGesture",
      base::BindRepeating(&CaptureHandler::RecognizeRemotely, base::Unretained(this)));
}

void CaptureHandler::OnJavascriptDisallowed() {
  weak_.InvalidateWeakPtrs();
  request_.reset();
  prepared_endpoint_.clear();
  ocr_ = false;
  local_started_ = false;
}

bool CaptureHandler::IsCapturePage() {
  return web_ui()->GetWebContents()->GetLastCommittedURL() ==
         GURL(kCapturePageUrl);
}

void CaptureHandler::TakeImage(const base::ListValue& args) {
  if (!IsCapturePage() || args.size() != 1 || !args.front().is_string()) {
    return;
  }
  AllowJavascript();
  CapturedWebpage capture = TakeCapturedWebpage(web_ui()->GetWebContents());
  ocr_ = capture.ocr && !capture.png.empty();
  base::DictValue result;
  result.Set("image", std::move(capture.png));
  result.Set("ocr", capture.ocr);
  result.Set("large", capture.too_large);
  ResolveJavascriptCallback(args.front(), result);
}

void CaptureHandler::GetRemoteDestination(const base::ListValue& args) {
  if (IsJavascriptAllowed() && IsCapturePage() && ocr_ && args.size() == 1 &&
      args.front().is_string()) {
    ResolveJavascriptCallback(
        args.front(), base::Value(Destination(CurrentEndpoint(web_ui()))));
  }
}

void CaptureHandler::PrepareRemoteRequest(const base::ListValue& args) {
  if (IsJavascriptAllowed() && IsCapturePage() && ocr_ && args.size() == 1 &&
      args.front().is_string()) {
    const GURL endpoint = CurrentEndpoint(web_ui());
    prepared_endpoint_ = endpoint.is_valid() ? endpoint.spec() : "";
    ResolveJavascriptCallback(args.front(), base::Value(Destination(endpoint)));
  }
}

void CaptureHandler::RecognizeLocally(const base::ListValue& args) {
  if (!IsJavascriptAllowed() || !IsCapturePage() || !ocr_ ||
      args.size() != 2 || !args[0].is_string() || !args[1].is_string()) {
    return;
  }
#if BUILDFLAG(IS_MAC)
  const auto& encoded = args[1].GetString();
  std::string png;
  if (!local_started_ && encoded.size() <= ((kMaxUpload + 2) / 3) * 4 &&
      base::Base64Decode(encoded, &png) && png.size() <= kMaxUpload && IsBoundedPNG(png)) {
    local_started_ = true;
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, {base::TaskPriority::USER_VISIBLE, base::MayBlock()},
        base::BindOnce(&RecognizeCaptureWithVision, std::move(png)),
        base::BindOnce(&CaptureHandler::LocalReply, weak_.GetWeakPtr(),
                       args.front().GetString()));
    return;
  }
#endif
  base::DictValue result;
  result.Set("available", false);
  ResolveJavascriptCallback(args.front(), result);
}

void CaptureHandler::LocalReply(std::string callback, std::string text) {
  base::DictValue result;
  result.Set("available", true);
  result.Set("text", std::move(text));
  ResolveJavascriptCallback(base::Value(callback), result);
}

void CaptureHandler::RecognizeRemotely(const base::ListValue& args) {
  if (!IsJavascriptAllowed() || !IsCapturePage() || !ocr_ || args.size() != 2 ||
      !args[0].is_string() || !args[1].is_string()) {
    return;
  }
  const auto& callback = args[0];
  const auto& encoded = args[1].GetString();
  const GURL endpoint = CurrentEndpoint(web_ui());
  const std::string prepared = std::exchange(prepared_endpoint_, {});
  if (!endpoint.is_valid() || endpoint.spec() != prepared) {
    ResolveJavascriptCallback(
        callback, base::DictValue().Set("ok", false).Set("settingsChanged", true));
    return;
  }
  auto* contents = web_ui()->GetWebContents();
  std::string png;
  if (request_ ||
      !contents->GetPrimaryMainFrame()->HasTransientUserActivation() ||
      encoded.size() > ((kMaxUpload + 2) / 3) * 4 ||
      !base::Base64Decode(encoded, &png) || png.size() > kMaxUpload ||
      !IsBoundedPNG(png)) {
    ResolveJavascriptCallback(callback, base::DictValue().Set("ok", false));
    return;
  }
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = endpoint;
  request->method = "POST";
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  request->redirect_mode = network::mojom::RedirectMode::kError;
  request->load_flags = net::LOAD_DISABLE_CACHE;
  if (endpoint.SchemeIs("http")) {
    const auto token = base::Environment::Create()->GetVar("AEGIS_OCR_TEST_TOKEN");
    if (token && !token->empty()) {
      request->headers.SetHeader("Authorization", "Bearer " + *token);
    }
  }
  constexpr auto annotation = net::DefineNetworkTrafficAnnotation(
      "aegis_webpage_image_ocr",
      R"(
        semantics {
          sender: "Aegis image text recognition"
          description: "Recognizes text in a single user-selected image."
          trigger: "The user confirms the exact image in the browser's OCR dialog."
          data: "PNG pixels of the previewed image or crop."
          destination: OTHER
        }
        policy {
          cookies_allowed: NO
          setting: "Available only when an Aegis OCR endpoint is configured."
          policy_exception_justification: "Each upload requires explicit confirmation."
        })");
  request_ = network::SimpleURLLoader::Create(std::move(request), annotation);
  request_->SetTimeoutDuration(base::Seconds(15));
  request_->AttachStringForUpload(std::move(png), "image/png");
  request_->DownloadToString(
      contents->GetBrowserContext()->GetDefaultStoragePartition()
          ->GetURLLoaderFactoryForBrowserProcess()
          .get(),
      base::BindOnce(&CaptureHandler::RemoteReply, weak_.GetWeakPtr(),
                     callback.GetString()),
      128 * 1024);
}

void CaptureHandler::RemoteReply(std::string callback,
                                 std::optional<std::string> body) {
  request_.reset();
  base::DictValue result;
  const auto reply = body ? base::JSONReader::ReadDict(*body, base::JSON_PARSE_RFC)
                          : std::nullopt;
  const std::string* text = reply ? reply->FindString("text") : nullptr;
  result.Set("ok", text != nullptr);
  if (text) {
    result.Set("text", *text);
  }
  ResolveJavascriptCallback(base::Value(callback), result);
}

}  // namespace aegis

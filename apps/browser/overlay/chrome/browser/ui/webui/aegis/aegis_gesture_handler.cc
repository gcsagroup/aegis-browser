// Copyright 2026 GCSA
#include "chrome/browser/ui/webui/aegis/aegis_gesture_handler.h"

#include <array>
#include <cmath>
#include <memory>
#include <utility>

#include "base/functional/bind.h"
#include "chrome/browser/aegis/gestures/gesture_settings.h"
#include "chrome/browser/profiles/profile.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "url/gurl.h"

AegisGestureHandler::AegisGestureHandler() = default;
AegisGestureHandler::~AegisGestureHandler() = default;

void AegisGestureHandler::RegisterMessages() {
  web_ui()->RegisterMessageCallback(
      "aegisGetGestureSettings",
      base::BindRepeating(&AegisGestureHandler::GetSettings,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "aegisSaveGestureSettings",
      base::BindRepeating(&AegisGestureHandler::SaveSettings,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "aegisResetGestureSettings",
      base::BindRepeating(&AegisGestureHandler::ResetSettings,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "aegisGesturePracticeRegion",
      base::BindRepeating(&AegisGestureHandler::SetPracticeRegion,
                          base::Unretained(this)));
}

bool AegisGestureHandler::IsGesturePage() {
  // 手势配置不向普通网页、PDF 或其他 WebUI 暴露。
  return web_ui()->GetWebContents()->GetLastCommittedURL() ==
         GURL("chrome://aegis/gestures.html");
}

base::DictValue AegisGestureHandler::Snapshot() {
  const auto& raw = Profile::FromWebUI(web_ui())->GetPrefs()->GetDict(
      aegis::kMouseGesturesPref);
  auto settings = aegis::GestureSettings::Parse(raw).value_or(
      aegis::GestureSettings::Defaults());
  base::ListValue actions;
  for (const auto& action : aegis::GestureActions()) {
    actions.Append(base::DictValue()
                       .Set("id", action.id)
                       .Set("label", action.label)
                       .Set("pdfOnly", action.pdf_only));
  }
  return base::DictValue()
      .Set("settings", settings.ToValue())
      .Set("actions", std::move(actions));
}

void AegisGestureHandler::GetSettings(const base::ListValue& args) {
  if (!IsGesturePage() || args.size() != 1 || !args[0].is_string()) {
    return;
  }
  AllowJavascript();
  ResolveJavascriptCallback(args[0], Snapshot());
}

void AegisGestureHandler::SaveSettings(const base::ListValue& args) {
  if (!IsGesturePage() || args.size() != 2 || !args[0].is_string()) {
    return;
  }
  AllowJavascript();
  auto settings = args[1].is_dict()
                      ? aegis::GestureSettings::Parse(args[1].GetDict())
                      : std::nullopt;
  if (!settings) {
    RejectJavascriptCallback(args[0],
                             base::Value("配置无效，请检查手势和网站名单。"));
    return;
  }
  Profile::FromWebUI(web_ui())->GetPrefs()->SetDict(aegis::kMouseGesturesPref,
                                                    settings->ToValue());
  ResolveJavascriptCallback(args[0], Snapshot());
}

void AegisGestureHandler::ResetSettings(const base::ListValue& args) {
  if (!IsGesturePage() || args.size() != 1 || !args[0].is_string()) {
    return;
  }
  AllowJavascript();
  Profile::FromWebUI(web_ui())->GetPrefs()->ClearPref(
      aegis::kMouseGesturesPref);
  ResolveJavascriptCallback(args[0], Snapshot());
}

void AegisGestureHandler::SetPracticeRegion(const base::ListValue& args) {
  if (!IsGesturePage() || args.size() != 4) {
    return;
  }
  std::array<double, 4> values{};
  for (size_t i = 0; i < 4; ++i) {
    if (!args[i].is_double() && !args[i].is_int()) {
      return;
    }
    values[i] = args[i].GetDouble();
    if (!std::isfinite(values[i]) || values[i] < 0 || values[i] > 1) {
      return;
    }
  }
  if (values[0] + values[2] > 1.001 || values[1] + values[3] > 1.001) {
    return;
  }
  auto region = std::make_unique<aegis::GesturePracticeRegion>();
  region->x = values[0];
  region->y = values[1];
  region->width = values[2];
  region->height = values[3];
  web_ui()->GetWebContents()->SetUserData(aegis::kGesturePracticeKey,
                                          std::move(region));
}

void AegisGestureHandler::OnJavascriptDisallowed() {
  web_ui()->GetWebContents()->RemoveUserData(aegis::kGesturePracticeKey);
}

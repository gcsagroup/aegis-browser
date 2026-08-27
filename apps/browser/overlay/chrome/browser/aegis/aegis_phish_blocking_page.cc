// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_phish_blocking_page.cc

#include "chrome/browser/aegis/aegis_phish_blocking_page.h"

#include <utility>

#include "base/notreached.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/values.h"
#include "chrome/browser/browser_process.h"
#include "components/security_interstitials/content/security_interstitial_controller_client.h"
#include "components/security_interstitials/core/metrics_helper.h"
#include "content/public/browser/web_contents.h"
#include "url/gurl.h"

namespace aegis {
namespace {

bool IsChineseLocale(const std::string& locale) {
  return base::StartsWith(locale, "zh",
                          base::CompareCase::INSENSITIVE_ASCII);
}

std::u16string WithWeight(std::u16string label, int weight) {
  if (weight <= 0) {
    return label;
  }
  label += u"  (+";
  label += base::UTF8ToUTF16(base::NumberToString(weight));
  label += u")";
  return label;
}

std::u16string ReasonLabel(const PhishReason& reason, bool zh) {
  const std::u16string detail = base::UTF8ToUTF16(reason.detail);
  if (reason.code == "seed_host") {
    return WithWeight(zh ? u"命中内置钓鱼名单" : u"Listed in the built-in phishing set",
                      reason.weight);
  }
  if (reason.code == "insecure_http") {
    return WithWeight(
        zh ? u"没有使用 HTTPS，连接可能被篡改" : u"Not using HTTPS",
        reason.weight);
  }
  if (reason.code == "ip_hostname") {
    return WithWeight(zh ? u"用 IP 地址当网址，仿冒站常用这一招"
                         : u"Uses a raw IP address instead of a normal domain",
                      reason.weight);
  }
  if (reason.code == "punycode_host") {
    return WithWeight(
        zh ? u"域名含国际化编码，可能在用相似字符仿冒品牌"
           : u"Internationalized domain that may mimic a brand",
        reason.weight);
  }
  if (reason.code == "deep_subdomain") {
    return WithWeight(
        zh ? u"子域名层数异常多，用来把真域名藏在后面"
           : u"Unusually deep subdomain, often used to hide the real site",
        reason.weight);
  }
  if (reason.code == "suspicious_tld") {
    std::u16string label =
        zh ? u"顶级域风险较高" : u"High-risk top-level domain";
    if (!detail.empty()) {
      label += u" (.";
      label += detail;
      label += u")";
    }
    return WithWeight(std::move(label), reason.weight);
  }
  if (reason.code == "brand_spoof_host") {
    std::u16string label;
    if (zh) {
      label = u"看起来像「";
      label += detail.empty() ? u"知名品牌" : detail;
      label += u"」，但不是该品牌的正站";
    } else {
      label = u"Looks like \"";
      label += detail.empty() ? u"a known brand" : detail;
      label += u"\", but this is not the official site";
    }
    return WithWeight(std::move(label), reason.weight);
  }
  if (reason.code == "at_symbol_trick") {
    return WithWeight(
        zh ? u"网址含 @，用来掩盖真实去向" : u"URL uses @ to hide the real destination",
        reason.weight);
  }
  if (reason.code == "invalid_url") {
    return WithWeight(zh ? u"地址无效" : u"Invalid URL", reason.weight);
  }
  if (reason.code == "urgency_language") {
    return WithWeight(
        zh ? u"页面催你马上登录，或声称账号异常"
           : u"Page copy urges you to sign in immediately",
        reason.weight);
  }
  if (reason.code == "password_on_risky_origin") {
    return WithWeight(
        zh ? u"在可疑网站上出现了密码框" : u"Password field on a risky site",
        reason.weight);
  }
  if (reason.code == "credential_form") {
    return WithWeight(
        zh ? u"页面在收集账号或密码" : u"Page is collecting credentials",
        reason.weight);
  }
  if (reason.code == "lightweight_model_blend") {
    return WithWeight(
        zh ? u"本地规则额外加分" : u"Extra local-rule score", reason.weight);
  }
  return WithWeight(base::UTF8ToUTF16(reason.code), reason.weight);
}

std::u16string FormatReasons(const PhishAssessment& assessment, bool zh) {
  std::u16string text;
  for (const PhishReason& reason : assessment.reasons) {
    if (!text.empty()) {
      text += u"<br>";
    }
    text += u"• ";
    text += ReasonLabel(reason, zh);
  }
  if (!text.empty()) {
    text += u"<br><br>";
  }
  text += zh ? u"合计 " : u"Total ";
  text += base::UTF8ToUTF16(base::NumberToString(assessment.score));
  text += zh ? u" 分，达到 " : u" / block at ";
  text += base::UTF8ToUTF16(base::NumberToString(kPhishBlockThreshold));
  text += zh ? u" 分即拦截。" : u".";
  return text;
}

}  // namespace

// static
const security_interstitials::SecurityInterstitialPage::TypeID
    AegisPhishBlockingPage::kTypeForTesting =
        &AegisPhishBlockingPage::kTypeForTesting;

AegisPhishBlockingPage::AegisPhishBlockingPage(
    content::WebContents* web_contents,
    const GURL& request_url,
    PhishAssessment assessment,
    std::unique_ptr<
        security_interstitials::SecurityInterstitialControllerClient>
        controller_client)
    : security_interstitials::SecurityInterstitialPage(
          web_contents,
          request_url,
          std::move(controller_client)),
      assessment_(std::move(assessment)) {
  controller()->metrics_helper()->RecordUserDecision(
      security_interstitials::MetricsHelper::SHOW);
}

AegisPhishBlockingPage::~AegisPhishBlockingPage() = default;

security_interstitials::SecurityInterstitialPage::TypeID
AegisPhishBlockingPage::GetTypeForTesting() {
  return AegisPhishBlockingPage::kTypeForTesting;
}

bool AegisPhishBlockingPage::ShouldDisplayURL() const {
  return true;
}

void AegisPhishBlockingPage::CommandReceived(const std::string& command) {
  if (command == "\"pageLoadComplete\"") {
    return;
  }

  int cmd = 0;
  bool retval = base::StringToInt(command, &cmd);
  DCHECK(retval);

  switch (cmd) {
    case security_interstitials::CMD_DONT_PROCEED:
      controller()->metrics_helper()->RecordUserDecision(
          security_interstitials::MetricsHelper::DONT_PROCEED);
      controller()->GoBack();
      break;
    case security_interstitials::CMD_PROCEED:
      controller()->metrics_helper()->RecordUserDecision(
          security_interstitials::MetricsHelper::PROCEED);
      controller()->Proceed();
      break;
    case security_interstitials::CMD_DO_REPORT:
    case security_interstitials::CMD_DONT_REPORT:
    case security_interstitials::CMD_SHOW_MORE_SECTION:
    case security_interstitials::CMD_OPEN_DATE_SETTINGS:
    case security_interstitials::CMD_OPEN_REPORTING_PRIVACY:
    case security_interstitials::CMD_OPEN_WHITEPAPER:
    case security_interstitials::CMD_OPEN_HELP_CENTER:
    case security_interstitials::CMD_RELOAD:
    case security_interstitials::CMD_OPEN_DIAGNOSTIC:
    case security_interstitials::CMD_OPEN_LOGIN:
    case security_interstitials::CMD_REPORT_PHISHING_ERROR:
      NOTREACHED() << "Unsupported command: " << command;
    case security_interstitials::CMD_ERROR:
    case security_interstitials::CMD_TEXT_FOUND:
    case security_interstitials::CMD_TEXT_NOT_FOUND:
      break;
  }
}

void AegisPhishBlockingPage::PopulateInterstitialStrings(
    base::DictValue& load_time_data) {
  PopulateValuesForSharedHTML(load_time_data);

  const std::string locale = g_browser_process->GetApplicationLocale();
  const bool zh = IsChineseLocale(locale);
  const std::u16string score_text = base::UTF8ToUTF16(
      base::NumberToString(assessment_.score));

  load_time_data.Set("tabTitle", zh ? u"疑似钓鱼网站" : u"Suspected phishing");
  load_time_data.Set("heading",
                     zh ? u"这个网站可能在仿冒别人"
                        : u"This site may be impersonating another");
  std::u16string primary =
      zh ? u"风险分 " : u"Risk score ";
  primary += score_text;
  primary += zh ? u"（达到 " : u" (block at ";
  primary += base::UTF8ToUTF16(base::NumberToString(kPhishBlockThreshold));
  primary += zh ? u" 即拦截）。下面是加分原因。继续访问可能泄露账号或支付信息。"
                : u"). Reasons below. Continuing may expose account or payment details.";
  load_time_data.Set("primaryParagraph", primary);
  load_time_data.Set("explanationParagraph", FormatReasons(assessment_, zh));
  load_time_data.Set("primaryButtonText",
                     zh ? u"返回安全页面" : u"Back to safety");
  load_time_data.Set("proceedButtonText",
                     zh ? u"仍然访问" : u"Visit this site");
  load_time_data.Set("optInLink", std::u16string());
  load_time_data.Set("enhancedProtectionMessage", std::u16string());
}

void AegisPhishBlockingPage::PopulateValuesForSharedHTML(
    base::DictValue& load_time_data) {
  // Reuse INSECURE_FORM UI wiring (primary + proceed buttons) without
  // modifying interstitial_large.js.
  load_time_data.Set("type", "INSECURE_FORM");
  load_time_data.Set("overridable", false);
  load_time_data.Set("hide_primary_button", false);
  load_time_data.Set("openDetails", "");
  load_time_data.Set("finalParagraph", "");
}

}  // namespace aegis

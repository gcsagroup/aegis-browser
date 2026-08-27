#!/usr/bin/env bash
# Apply overlay WebUI + prefs + DynamicParams wiring for patch 0003.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SRC="$CHROMIUM_ROOT/src"
OVERLAY="$ROOT_DIR/overlay"

cd "$SRC"

echo "Syncing overlay…"
mkdir -p chrome/browser/ui/webui/aegis chrome/browser/resources/aegis
cp -R "$OVERLAY/chrome/browser/aegis/." chrome/browser/aegis/
cp -R "$OVERLAY/chrome/common/aegis/." chrome/common/aegis/
cp -R "$OVERLAY/chrome/browser/ui/webui/aegis/." chrome/browser/ui/webui/aegis/
cp -R "$OVERLAY/chrome/browser/resources/aegis/." chrome/browser/resources/aegis/

python3 - <<'PY'
from pathlib import Path

def ensure_once(path: Path, needle: str, insert: str, after: str | None = None, before: str | None = None):
    text = path.read_text()
    if needle in text:
        print(f"skip existing: {needle[:60]}… in {path}")
        return
    if after:
        if after not in text:
            raise SystemExit(f"anchor after missing in {path}: {after[:80]}")
        text = text.replace(after, after + insert, 1)
    elif before:
        if before not in text:
            raise SystemExit(f"anchor before missing in {path}: {before[:80]}")
        text = text.replace(before, insert + before, 1)
    else:
        raise SystemExit("need after or before")
    path.write_text(text)
    print(f"patched {path}")

# --- webui_url_constants.h ---
path = Path("chrome/common/webui_url_constants.h")
ensure_once(
    path,
    'kChromeUIAegisHost',
    'inline constexpr char kChromeUIAegisHost[] = "aegis";\n'
    'inline constexpr char kChromeUIAegisURL[] = "chrome://aegis/";\n',
    after='inline constexpr char kChromeUIVersionHost[] = "version";\n',
)

# --- ChromeURLHosts ---
path = Path("chrome/common/webui_url_constants.cc")
ensure_once(
    path,
    "kChromeUIAegisHost,",
    "      kChromeUIAegisHost,\n",
    after="      kChromeUIAboutHost,\n",
)

# --- RegisterChromeWebUIConfigs ---
path = Path("chrome/browser/ui/webui/chrome_web_ui_configs.cc")
text = path.read_text()
if 'aegis/aegis_ui.h' not in text:
    import re
    m = re.search(r'#include "chrome/browser/ui/webui/[^"]+"\n', text)
    if not m:
        raise SystemExit("no webui include anchor")
    marker = m.group(0)
    text = text.replace(marker, marker + '#include "chrome/browser/ui/webui/aegis/aegis_ui.h"\n', 1)
    path.write_text(text)
    print("added aegis_ui include")

ensure_once(
    path,
    "AegisUIConfig",
    "  map.AddWebUIConfig(std::make_unique<AegisUIConfig>());\n",
    after="  map.AddWebUIConfig(std::make_unique<AccessibilityUIConfig>());\n",
)

# --- ui/webui/BUILD.gn ---
path = Path("chrome/browser/ui/webui/BUILD.gn")
ensure_once(
    path,
    "//chrome/browser/ui/webui/aegis",
    '    "//chrome/browser/ui/webui/aegis",\n',
    after='    "//chrome/browser/ui/webui/accessibility",\n',
)

# --- resources/BUILD.gn ---
path = Path("chrome/browser/resources/BUILD.gn")
ensure_once(
    path,
    "aegis:resources",
    '      "aegis:resources",\n',
    after='      "webui_js_error:resources",\n',
)
ensure_once(
    path,
    "aegis_resources.pak",
    '      "$root_gen_dir/chrome/aegis_resources.pak",\n',
    after='      "$root_gen_dir/chrome/webui_js_error_resources.pak",\n',
)

# --- browser_prefs.cc ---
path = Path("chrome/browser/prefs/browser_prefs.cc")
text = path.read_text()
if "aegis/aegis_prefs.h" not in text:
    # insert include near other chrome/browser includes
    marker = '#include "chrome/browser/about_flags.h"\n'
    if marker not in text:
        marker = '#include "chrome/browser/browser_process.h"\n'
    text = text.replace(marker, marker + '#include "chrome/browser/aegis/aegis_prefs.h"\n', 1)
if "aegis::RegisterProfilePrefs" not in text:
    anchor = "  AccessibilityLabelsService::RegisterProfilePrefs(registry);\n"
    text = text.replace(
        anchor,
        anchor + "  aegis::RegisterProfilePrefs(registry);\n",
        1,
    )
path.write_text(text)
print("patched browser_prefs.cc")

# --- DynamicParams ---
path = Path("chrome/common/renderer_configuration.mojom")
ensure_once(
    path,
    "aegis_tracker_blocking",
    "  bool aegis_tracker_blocking = true;\n",
    after="  string allowed_domains_for_apps;\n",
)

# --- RendererUpdater ---
path = Path("chrome/browser/profiles/renderer_updater.cc")
ensure_once(
    path,
    "aegis/pref_names.h",
    '#include "chrome/common/aegis/pref_names.h"\n',
    after='#include "chrome/common/pref_names.h"\n',
)
text = path.read_text()
if "aegis_tracker_blocking_" not in text:
    # Init BooleanPrefMember - add after allowed_domains_for_apps_.Init
    anchor = "  allowed_domains_for_apps_.Init(prefs::kAllowedDomainsForApps, pref_service);\n"
    insert = (
        anchor
        + "  aegis_tracker_blocking_.Init(aegis::prefs::kTrackerBlockingEnabled,\n"
        + "                               pref_service);\n"
    )
    if anchor not in text:
        raise SystemExit("allowed_domains init missing")
    text = text.replace(anchor, insert, 1)
    # pref change registrar
    anchor2 = (
        "  pref_change_registrar_.Add(\n"
        "      prefs::kAllowedDomainsForApps,\n"
        "      base::BindRepeating(&RendererUpdater::UpdateAllRenderers,\n"
        "                          base::Unretained(this)));\n"
    )
    insert2 = (
        anchor2
        + "  pref_change_registrar_.Add(\n"
        + "      aegis::prefs::kTrackerBlockingEnabled,\n"
        + "      base::BindRepeating(&RendererUpdater::UpdateAllRenderers,\n"
        + "                          base::Unretained(this)));\n"
    )
    if anchor2 not in text:
        raise SystemExit("pref registrar anchor missing")
    text = text.replace(anchor2, insert2, 1)
    # CreateRendererDynamicParams
    old = (
        "  return chrome::mojom::DynamicParams::New(\n"
        "#if BUILDFLAG(ENABLE_BOUND_SESSION_CREDENTIALS)\n"
        "      GetBoundSessionThrottlerParams(),\n"
        "#endif\n"
        "      force_google_safesearch_.GetValue(), force_youtube_restrict_.GetValue(),\n"
        "      allowed_domains_for_apps_.GetValue());\n"
    )
    new = (
        "  return chrome::mojom::DynamicParams::New(\n"
        "#if BUILDFLAG(ENABLE_BOUND_SESSION_CREDENTIALS)\n"
        "      GetBoundSessionThrottlerParams(),\n"
        "#endif\n"
        "      force_google_safesearch_.GetValue(), force_youtube_restrict_.GetValue(),\n"
        "      allowed_domains_for_apps_.GetValue(),\n"
        "      aegis_tracker_blocking_.GetValue());\n"
    )
    if old not in text:
        raise SystemExit("CreateRendererDynamicParams body missing")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print("patched renderer_updater.cc")

path = Path("chrome/browser/profiles/renderer_updater.h")
ensure_once(
    path,
    "aegis_tracker_blocking_",
    "  BooleanPrefMember aegis_tracker_blocking_;\n",
    after="  StringPrefMember allowed_domains_for_apps_;\n",
)

# --- CCB DynamicParams for GoogleURLLoaderThrottle ---
path = Path("chrome/browser/chrome_content_browser_client.cc")
text = path.read_text()
if "aegis_tracker_blocking" not in text and "aegis::prefs::kTrackerBlockingEnabled" not in text:
    ensure_once(
        path,
        "aegis/pref_names.h",
        '#include "chrome/common/aegis/pref_names.h"\n',
        after='#include "chrome/common/pref_names.h"\n',
    )
    text = path.read_text()
    old = (
        "  chrome::mojom::DynamicParamsPtr dynamic_params =\n"
        "      chrome::mojom::DynamicParams::New(\n"
        "#if BUILDFLAG(ENABLE_BOUND_SESSION_CREDENTIALS)\n"
        "          std::move(bound_session_throttler_params),\n"
        "#endif\n"
        "          profile->GetPrefs()->GetBoolean(\n"
        "              policy::policy_prefs::kForceGoogleSafeSearch),\n"
        "          profile->GetPrefs()->GetInteger(\n"
        "              policy::policy_prefs::kForceYouTubeRestrict),\n"
        "          profile->GetPrefs()->GetString(prefs::kAllowedDomainsForApps));\n"
    )
    new = (
        "  chrome::mojom::DynamicParamsPtr dynamic_params =\n"
        "      chrome::mojom::DynamicParams::New(\n"
        "#if BUILDFLAG(ENABLE_BOUND_SESSION_CREDENTIALS)\n"
        "          std::move(bound_session_throttler_params),\n"
        "#endif\n"
        "          profile->GetPrefs()->GetBoolean(\n"
        "              policy::policy_prefs::kForceGoogleSafeSearch),\n"
        "          profile->GetPrefs()->GetInteger(\n"
        "              policy::policy_prefs::kForceYouTubeRestrict),\n"
        "          profile->GetPrefs()->GetString(prefs::kAllowedDomainsForApps),\n"
        "          profile->GetPrefs()->GetBoolean(\n"
        "              aegis::prefs::kTrackerBlockingEnabled));\n"
    )
    if old not in text:
        raise SystemExit("CCB DynamicParams::New missing")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print("patched CCB DynamicParams")

# Update AegisNetThrottle::MaybeCreate call sites
text = path.read_text()
old = (
    "  if (auto aegis_throttle = aegis::AegisNetThrottle::MaybeCreate();\n"
    "      aegis_throttle) {\n"
    "    result.push_back(std::move(aegis_throttle));\n"
    "  }\n"
)
new = (
    "  const bool aegis_tracker_blocking =\n"
    "      profile->GetPrefs()->GetBoolean(aegis::prefs::kTrackerBlockingEnabled);\n"
    "  if (auto aegis_throttle =\n"
    "          aegis::AegisNetThrottle::MaybeCreate(aegis_tracker_blocking);\n"
    "      aegis_throttle) {\n"
    "    result.push_back(std::move(aegis_throttle));\n"
    "  }\n"
)
if "AegisNetThrottle::MaybeCreate(aegis_tracker_blocking)" not in text:
    if old not in text:
        # try without blank lines variance
        raise SystemExit("AegisNetThrottle call site missing in CCB")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print("updated CCB MaybeCreate")
else:
    print("CCB MaybeCreate already updated")

# Ensure pref_names include exists for CCB throttle path
if 'aegis/pref_names.h' not in path.read_text():
    ensure_once(
        path,
        "aegis/pref_names.h",
        '#include "chrome/common/aegis/pref_names.h"\n',
        after='#include "chrome/common/aegis/aegis_net_throttle.h"\n',
    )

# --- renderer provider ---
path = Path("chrome/renderer/url_loader_throttle_provider_impl.cc")
text = path.read_text()
old = (
    "  if (auto aegis_throttle = aegis::AegisNetThrottle::MaybeCreate();\n"
    "      aegis_throttle) {\n"
    "    throttles.emplace_back(std::move(aegis_throttle));\n"
    "  }\n"
)
new = (
    "  bool aegis_tracker_blocking = true;\n"
    "  if (auto* observer = chrome_content_renderer_client_->GetChromeObserver()) {\n"
    "    if (auto params = observer->GetDynamicParams(); params) {\n"
    "      aegis_tracker_blocking = params->aegis_tracker_blocking;\n"
    "    }\n"
    "  }\n"
    "  if (auto aegis_throttle =\n"
    "          aegis::AegisNetThrottle::MaybeCreate(aegis_tracker_blocking);\n"
    "      aegis_throttle) {\n"
    "    throttles.emplace_back(std::move(aegis_throttle));\n"
    "  }\n"
)
if "params->aegis_tracker_blocking" not in text:
    if old not in text:
        raise SystemExit("renderer MaybeCreate call site missing")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print("updated renderer MaybeCreate")
else:
    print("renderer MaybeCreate already updated")

print("Done applying 0003 wiring.")
PY

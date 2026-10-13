// Copyright 2026 GCSA
#include "chrome/browser/ui/webui/aegis/aegis_markdown_ui.h"
#include <string>
#include "chrome/grit/aegis_resources_map.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "content/public/browser/web_ui_data_source.h"
#include "services/network/public/mojom/content_security_policy.mojom.h"
AegisMarkdownUI::AegisMarkdownUI(content::WebUI* web_ui)
    : ui::UntrustedWebUIController(web_ui) {
  auto* source = content::WebUIDataSource::CreateAndAdd(
      web_ui->GetWebContents()->GetBrowserContext(),
      "chrome-untrusted://aegis-markdown/");
  for (const auto& resource : kAegisResources) {
    std::string path = resource.path;
    if (path.starts_with("enhancements_shared/")) {
      path.erase(0, 20);
      source->AddResourcePath(path, resource.id);
      if (path == "viewer.html")
        source->SetDefaultResource(resource.id);
    }
  }
  source->OverrideContentSecurityPolicy(
      network::mojom::CSPDirectiveName::ScriptSrc, "script-src 'self';");
  source->OverrideContentSecurityPolicy(
      network::mojom::CSPDirectiveName::StyleSrc,
      "style-src 'self' 'unsafe-inline';");
  source->OverrideContentSecurityPolicy(
      network::mojom::CSPDirectiveName::ImgSrc, "img-src data: https: http:;");
  source->OverrideContentSecurityPolicy(
      network::mojom::CSPDirectiveName::ConnectSrc, "connect-src 'none';");
  source->OverrideContentSecurityPolicy(
      network::mojom::CSPDirectiveName::FrameSrc, "frame-src 'none';");
  source->OverrideContentSecurityPolicy(
      network::mojom::CSPDirectiveName::TrustedTypes,
      "trusted-types dompurify;");
  source->AddFrameAncestor(GURL("chrome://aegis"));
}

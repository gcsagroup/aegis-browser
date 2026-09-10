// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/aegis_agent_service_factory.h"

#include "base/feature_list.h"
#include "chrome/browser/actor/actor_keyed_service_factory.h"
#include "chrome/browser/aegis/aegis_service_factory.h"
#include "chrome/browser/aegis/agent/aegis_agent_service.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_context.h"

namespace aegis::agent {

// static
AegisAgentServiceFactory* AegisAgentServiceFactory::GetInstance() {
  static base::NoDestructor<AegisAgentServiceFactory> factory{
      base::PassKey<AegisAgentServiceFactory>()};
  return factory.get();
}

// static
void AegisAgentServiceFactory::EnsureForProfileAtStartup(Profile* profile) {
  // 关闭状态不能请求创建：工厂会缓存 Build 返回的 nullptr，阻止之后启用。
  // 无痕服务仍由其会话入口按需创建，不在启动时恢复持久化监控。
  if (!aegis::IsAegisProfileSupported(profile) || !profile->IsRegularProfile() ||
      !base::FeatureList::IsEnabled(aegis::features::kAegisAgent) ||
      !profile->GetPrefs()->GetBoolean(aegis::prefs::kAgentEnabled)) {
    return;
  }
  GetForProfile(profile);
}

// static
AegisAgentService* AegisAgentServiceFactory::GetForProfile(Profile* profile) {
  if (!profile) {
    return nullptr;
  }
  return static_cast<AegisAgentService*>(
      GetInstance()->GetServiceForBrowserContext(profile, /*create=*/true));
}

// static
AegisAgentService* AegisAgentServiceFactory::GetForProfileIfExists(
    Profile* profile) {
  if (!profile) {
    return nullptr;
  }
  return static_cast<AegisAgentService*>(
      GetInstance()->GetServiceForBrowserContext(profile, /*create=*/false));
}

AegisAgentServiceFactory::AegisAgentServiceFactory(
    base::PassKey<AegisAgentServiceFactory>)
    : ProfileKeyedServiceFactory(
          "AegisAgentService",
          ProfileSelections::BuildForRegularAndIncognito()) {
  DependsOn(actor::ActorKeyedServiceFactory::GetInstance());
  DependsOn(aegis::AegisServiceFactory::GetInstance());
}

AegisAgentServiceFactory::~AegisAgentServiceFactory() = default;

std::unique_ptr<KeyedService>
AegisAgentServiceFactory::BuildServiceInstanceForBrowserContext(
    content::BrowserContext* context) const {
  Profile* profile = Profile::FromBrowserContext(context);
  if (!aegis::IsAegisProfileSupported(profile) ||
      !base::FeatureList::IsEnabled(aegis::features::kAegisAgent) ||
      !profile->GetPrefs()->GetBoolean(aegis::prefs::kAgentEnabled)) {
    return nullptr;
  }
  return std::make_unique<AegisAgentService>(profile);
}

}  // namespace aegis::agent

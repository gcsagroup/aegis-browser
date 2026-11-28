// 桌面账号 WebUI 和原生控件共用的导航入口与未同步的 Profile 偏好键。
#ifndef CHROME_COMMON_AEGIS_LINK_ACCOUNT_H_
#define CHROME_COMMON_AEGIS_LINK_ACCOUNT_H_
namespace aegis::link {
inline constexpr char kDeferredStartup[] = "aegis-deferred-first-run";
inline constexpr char kPage[] = "chrome://aegis/account.html";
inline constexpr char kSigninPage[] = "chrome://aegis/account.html#signin";
inline constexpr char kWelcomePage[] = "chrome://aegis/account.html#welcome";
inline constexpr char kWelcomePending[] = "aegis.link.welcome_pending";
inline constexpr char kEmail[] = "aegis.link.email";
inline constexpr char kWelcomeSeen[] = "aegis.link.welcome_seen";
inline constexpr char kFolders[] = "aegis.link.folders";
}  // namespace aegis::link
#endif

// 桌面账号 WebUI 和原生控件共用的导航入口与未同步的 Profile 偏好键。
#ifndef CHROME_COMMON_AEGIS_LINK_ACCOUNT_H_
#define CHROME_COMMON_AEGIS_LINK_ACCOUNT_H_
namespace aegis::link {
inline constexpr char kDeferredStartup[] = "aegis-deferred-first-run";
inline constexpr char kPage[] = "chrome://aegis/account.html";
inline constexpr char kBackgroundPage[] = "chrome://aegis/account.html#autosync";
inline constexpr char kSigninPage[] = "chrome://aegis/account.html#signin";
// Chromium 的单例标签匹配会忽略片段，用查询区分各菜单入口。
inline constexpr char kPortalProfilePage[] =
    "chrome://aegis/account.html?view=portal-profile";
inline constexpr char kSignoutPage[] = "chrome://aegis/account.html?view=signout";
inline constexpr char kWelcomePage[] = "chrome://aegis/account.html#welcome";
inline constexpr char kWelcomePending[] = "aegis.link.welcome_pending";
inline constexpr char kEmail[] = "aegis.link.email";
// 仅作本机头像菜单的展示缓存，授权仍以真实门户会话为准。
inline constexpr char kDisplayName[] = "aegis.link.display_name";
inline constexpr char kWelcomeSeen[] = "aegis.link.welcome_seen";
inline constexpr char kFolders[] = "aegis.link.folders";
}  // namespace aegis::link
#endif

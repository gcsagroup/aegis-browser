// 首启决定绑定到窗口拥有的 WebContents。普通账号标签页不能结束其他窗口的引导。
#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_LINK_FIRST_RUN_CHOICE_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_LINK_FIRST_RUN_CHOICE_H_
#include <utility>
#include "base/functional/callback.h"
#include "base/supports_user_data.h"
#include "content/public/browser/web_contents.h"

namespace aegis::link {
class FirstRunChoice : public base::SupportsUserData::Data {
 public:
  explicit FirstRunChoice(base::OnceClosure complete);
  ~FirstRunChoice() override;
  static FirstRunChoice* From(content::WebContents* web_contents) {
    return static_cast<FirstRunChoice*>(web_contents->GetUserData(&kKey));
  }
  static void Attach(content::WebContents* web_contents,
                     base::OnceClosure complete) {
    web_contents->SetUserData(
        &kKey, std::make_unique<FirstRunChoice>(std::move(complete)));
  }
  void Complete() {
    if (complete_)
      std::move(complete_).Run();
  }

 private:
  inline static constexpr char kKey = 0;
  base::OnceClosure complete_;
};
}  // namespace aegis::link
#endif

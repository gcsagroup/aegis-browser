// 将完成回调的生命周期绑定到首启窗口的 WebContents。
#include "chrome/browser/ui/webui/aegis/link_first_run_choice.h"
namespace aegis::link {
FirstRunChoice::FirstRunChoice(base::OnceClosure complete)
    : complete_(std::move(complete)) {}
FirstRunChoice::~FirstRunChoice() = default;
}  // namespace aegis::link

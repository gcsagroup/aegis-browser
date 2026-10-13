// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_AGENT_READING_WORKSPACE_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_AGENT_READING_WORKSPACE_H_

#include <map>
#include <memory>
#include <string>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/aegis/model_provider_client.h"
#include "chrome/common/chrome_render_frame.mojom.h"
#include "content/public/browser/weak_document_ptr.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "url/gurl.h"

class Profile;
class BrowserWindowInterface;
namespace os_crypt_async { class Encryptor; }

// 用户主动保存的有界资料库；加密落盘、比较后写入，不依赖模型或 Agent 开关。
class AegisReadingWorkspace {
 public:
  inline static constexpr char kStoragePref[] = "aegis.reading_library";
  using Callback = base::OnceCallback<void(std::string, std::string)>;
  AegisReadingWorkspace(Profile* profile, BrowserWindowInterface* browser);
  ~AegisReadingWorkspace();
  void Run(const std::string& request, Callback callback);
  static bool ValidateRecords(const base::ListValue& records);

 private:
  void Load(base::DictValue request, Callback callback,
            scoped_refptr<os_crypt_async::Encryptor> encryptor);
  void Dispatch(base::DictValue request, Callback callback,
                scoped_refptr<os_crypt_async::Encryptor> encryptor);
  void Persist(base::ListValue records, Callback callback,
               scoped_refptr<os_crypt_async::Encryptor> encryptor);
  void Capture(int tab_id, int page, Callback callback);
  void Captured(Callback callback, int passwords, int forms,
                const std::vector<std::string>& actions,
                const std::string& title, const std::string& text);
  bool SourceCurrent() const;
  void Translate(const base::DictValue& request, Callback callback);
  void Reply(Callback callback, base::DictValue value, std::string error = {});
  base::DictValue State() const;

  raw_ptr<Profile> profile_;
  raw_ptr<BrowserWindowInterface> browser_;
  bool busy_ = false;
  std::string loaded_ciphertext_;
  base::ListValue records_;
  std::map<int, GURL> listed_tabs_;
  base::DictValue draft_;
  content::WeakDocumentPtr source_document_;
  GURL source_url_;
  base::TimeTicks captured_at_;
  bool model_allowed_ = false;
  mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> capture_client_;
  aegis::ModelProviderClient model_client_;
  base::OneShotTimer capture_timer_;
  base::WeakPtrFactory<AegisReadingWorkspace> capture_factory_{this};
  base::WeakPtrFactory<AegisReadingWorkspace> weak_factory_{this};
};
#endif

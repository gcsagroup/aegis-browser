// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/ollama_sidecar.h

#ifndef CHROME_BROWSER_AEGIS_OLLAMA_SIDECAR_H_
#define CHROME_BROWSER_AEGIS_OLLAMA_SIDECAR_H_

#include <memory>
#include <string>

#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"

namespace network {
class SimpleURLLoader;
}  // namespace network

namespace aegis {

// Optional local ModelRuntime: HTTP to an Ollama sidecar on loopback.
class OllamaSidecar {
 public:
  using ChatCallback =
      base::OnceCallback<void(bool ok, std::string body_or_error)>;

  OllamaSidecar();
  OllamaSidecar(const OllamaSidecar&) = delete;
  OllamaSidecar& operator=(const OllamaSidecar&) = delete;
  ~OllamaSidecar();

  void Probe(const std::string& base_url, ChatCallback done);
  void Chat(const std::string& base_url,
            const std::string& model,
            const std::string& system,
            const std::string& user,
            ChatCallback done);

 private:
  void OnProbe(ChatCallback done, std::optional<std::string> body);
  void OnChat(ChatCallback done, std::optional<std::string> body);

  std::unique_ptr<network::SimpleURLLoader> loader_;
  base::WeakPtrFactory<OllamaSidecar> weak_factory_{this};
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_OLLAMA_SIDECAR_H_

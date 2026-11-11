// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_local_core_manager.h"

#include <atomic>
#include <vector>

#include "base/barrier_closure.h"
#include "base/command_line.h"
#include "base/base_paths.h"
#include "base/files/file.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/process/launch.h"
#include "base/process/kill.h"
#include "base/path_service.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/synchronization/lock.h"
#include "base/task/bind_post_task.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/timer/timer.h"
#include "base/uuid.h"
#include "base/values.h"
#include "chrome/browser/aegis/access/access_buildflags.h"
#include "crypto/hash.h"
#include "net/base/auth.h"
#include "net/base/ip_address.h"
#include "net/base/ip_endpoint.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/log/net_log_source.h"
#include "net/proxy_resolution/proxy_config_service_fixed.h"
#include "net/socket/tcp_server_socket.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "net/url_request/url_request.h"
#include "net/url_request/url_request_context.h"
#include "net/url_request/url_request_context_builder.h"

namespace aegis::access {
std::optional<AccessLocalCoreInput> ResolveAccessLocalCoreInput() {
#if BUILDFLAG(AEGIS_ALPHA_TEST_NODE_ENABLED)
  base::FilePath assets;
  if (!base::PathService::Get(base::DIR_ASSETS, &assets)) return std::nullopt;
  assets = assets.AppendASCII("AegisAlphaAccess");
  return AccessLocalCoreInput{assets.AppendASCII("core-manifest.json"),
      assets.AppendASCII("node.json"), AccessLocalCoreSource::kAlphaBundle};
#else
  const auto* command = base::CommandLine::ForCurrentProcess();
  auto manifest = command->GetSwitchValuePath("aegis-access-dev-core-manifest");
  auto node = command->GetSwitchValuePath("aegis-access-dev-node-config");
  if (manifest.empty() || node.empty()) return std::nullopt;
  return AccessLocalCoreInput{std::move(manifest), std::move(node)};
#endif
}
namespace {
constexpr auto kCanaryAnnotation = net::DefineNetworkTrafficAnnotation(
    "aegis_access_local_core_canary", R"(
      semantics {
        sender: "Aegis Access local core"
        description: "Checks the authorized Alpha or DEV proxy before retrying a failed navigation."
        trigger: "User asks to retry through the proxy."
        data: "A fixed HTTPS connectivity request and process-local proxy authentication. No browsing URL or cookies."
        destination: GOOGLE_OWNED_SERVICE
      }
      policy {
        cookies_allowed: NO
        setting: "Only the explicitly enabled DEV local-node binding can start this check."
        policy_exception_justification: "User-initiated DEV proxy validation."
      })");
constexpr char kCanary[] = "https://www.gstatic.com/generate_204";
std::string Token() { return base::Uuid::GenerateRandomV4().AsLowercaseString(); }
}  // namespace

class AccessLocalCoreManager::ShutdownHandle
    : public std::enable_shared_from_this<ShutdownHandle> {
 public:
  explicit ShutdownHandle(scoped_refptr<base::SequencedTaskRunner> runner)
      : runner_(std::move(runner)) {}

  // Registry access stays on the owning Browser sequence. The worker retains
  // its handle through asynchronous destruction, so removing a service cannot
  // hide a still-running child from session-ending cleanup.
  static std::vector<std::weak_ptr<ShutdownHandle>>& Registry() {
    static base::NoDestructor<std::vector<std::weak_ptr<ShutdownHandle>>> handles;
    return *handles;
  }
  bool stop_requested() const { return stop_requested_.load(); }
  void SetWorker(Worker* worker) { worker_ = worker; }  // Core thread only.

  void RequestStop(base::OnceClosure completion) {
    stop_requested_.store(true);
    bool stopped;
    {
      base::AutoLock lock(lock_);
      stopped = stopped_;
      if (!stopped) completions_.push_back(std::move(completion));
    }
    if (stopped) {
      std::move(completion).Run();
      return;
    }
    // If the thread is already stopping and rejects the task, destruction of
    // its queued SequenceBound worker completes the same cleanup barrier.
    runner_->PostTask(FROM_HERE, base::BindOnce(
        [](std::shared_ptr<ShutdownHandle> handle) {
          handle->StopOnCoreThread();
        }, shared_from_this()));
  }
  void CompleteStop() {
    std::vector<base::OnceClosure> completions;
    {
      base::AutoLock lock(lock_);
      stopped_ = true;
      completions.swap(completions_);
    }
    for (auto& completion : completions) std::move(completion).Run();
  }

 private:
  void StopOnCoreThread();
  scoped_refptr<base::SequencedTaskRunner> runner_;
  raw_ptr<Worker> worker_ = nullptr;  // Accessed only on the core thread.
  std::atomic_bool stop_requested_{false};
  base::Lock lock_;
  bool stopped_ GUARDED_BY(lock_) = false;
  std::vector<base::OnceClosure> completions_ GUARDED_BY(lock_);
};

class AccessLocalCoreManager::Worker : public net::URLRequest::Delegate {
 public:
  Worker(AccessLocalCoreInput input, std::shared_ptr<ShutdownHandle> shutdown)
      : input_(std::move(input)), shutdown_(std::move(shutdown)) {
    shutdown_->SetWorker(this);
  }
  ~Worker() override {
    StopChild();
    shutdown_->SetWorker(nullptr);
    shutdown_->CompleteStop();
  }

  void Prepare(base::OnceCallback<void(AccessLocalCoreReady)> completion) {
    if (shutdown_->stop_requested()) {
      std::move(completion).Run({.error = "The local proxy is shutting down."});
      return;
    }
    if (completion_) {
      std::move(completion).Run({.error = "Proxy preparation is already running."});
      return;
    }
    if (Running()) {
      Verify(std::move(completion));
      return;
    }
    StopChild();
    completion_ = std::move(completion);
    if (!Launch()) {
      Complete(false, "Cannot start the authorized local proxy.");
      return;
    }
    started_ = base::TimeTicks::Now();
    timeout_.Start(FROM_HERE, base::Seconds(25), base::BindOnce(
        &Worker::Complete, base::Unretained(this), false,
        "Proxy connectivity check timed out."));
    StartProbe();
  }

  void Verify(base::OnceCallback<void(AccessLocalCoreReady)> completion) {
    if (shutdown_->stop_requested()) {
      std::move(completion).Run({.error = "The local proxy is shutting down."});
      return;
    }
    if (completion_) {
      std::move(completion).Run({.error = "Proxy preparation is already running."});
      return;
    }
    completion_ = std::move(completion);
    health_.Stop();
    if (!Running()) {
      Complete(false, "The local proxy has stopped.");
      return;
    }
    started_ = base::TimeTicks();  // A recheck never relaunches or retries startup.
    request_.reset();
    context_.reset();
    authenticated_ = false;  // Each readiness check proves a fresh authenticated connection.
    timeout_.Start(FROM_HERE, base::Seconds(25), base::BindOnce(
        &Worker::Complete, base::Unretained(this), false,
        "Proxy connectivity check timed out."));
    StartProbe();
  }

  void Stop(base::OnceClosure completion) {
    if (completion_) Complete(false, "Proxy preparation was cancelled.");
    StopChild();
    std::move(completion).Run();
  }
  void SetStoppedCallback(base::RepeatingCallback<void(std::string)> callback) {
    stopped_callback_ = std::move(callback);
  }

 private:
  bool Running() {
    int code = 0;
    return process_.IsValid() &&
        base::GetTerminationStatus(process_.Handle(), &code) ==
            base::TERMINATION_STATUS_STILL_RUNNING;
  }
  bool Launch() {
    std::string manifest_json;
    std::string node_json;
    if (!base::ReadFileToStringWithMaxSize(input_.manifest, &manifest_json, 65536) ||
        !base::ReadFileToStringWithMaxSize(input_.node_config, &node_json, 1024 * 1024))
      return false;
    auto manifest = base::JSONReader::ReadDict(manifest_json, base::JSON_PARSE_RFC);
    auto node = base::JSONReader::ReadDict(node_json, base::JSON_PARSE_RFC);
    if (!manifest || !node) return false;
    base::FilePath binary;
    if (input_.source == AccessLocalCoreSource::kAlphaBundle) {
#if BUILDFLAG(AEGIS_ALPHA_TEST_NODE_ENABLED)
      const auto* channel = manifest->FindString("channel");
      const auto* relative = manifest->FindString("binaryRelativePath");
      const auto* node_name = manifest->FindString("nodeConfigRelativePath");
      const auto* node_pin = manifest->FindString("nodeConfigSha256");
      if (manifest->FindInt("schemaVersion") != 1 || !channel || *channel != "alpha" ||
          !relative || *relative != "xray" || !node_name || *node_name != "node.json" ||
          input_.node_config != input_.manifest.DirName().AppendASCII("node.json") ||
          !node_pin || base::HexEncodeLower(crypto::hash::Sha256(base::as_byte_span(node_json))) != *node_pin)
        return false;
      binary = input_.manifest.DirName().AppendASCII("xray");
#else
      return false;
#endif
    } else {
      const auto* path = manifest->FindString("binaryPath");
      if (!path) return false;
      binary = base::FilePath(*path);
    }
    const auto* pin = manifest->FindString("binarySha256");
    if (!pin) return false;
    auto bytes = base::ReadFileToBytes(binary);
    if (!binary.IsAbsolute() || !bytes ||
        base::HexEncodeLower(crypto::hash::Sha256(*bytes)) != *pin)
      return false;
    const auto* outbounds = node->FindList("outbounds");
    if (!outbounds || outbounds->empty() || !outbounds->front().is_dict()) return false;
    const auto& outbound = outbounds->front().GetDict();
    const auto* protocol = outbound.FindString("protocol");
    const auto* transport = outbound.FindStringByDottedPath("streamSettings.network");
    const auto* security = outbound.FindStringByDottedPath("streamSettings.security");
    if (!protocol || *protocol != "vless" || !transport || *transport != "tcp" ||
        !security || *security != "reality") return false;
    // The selected outbound is copied privately; no subscription, system
    // routing, original V2Ray process or original input file is changed.
    if (!directory_.CreateUniqueTempDir() ||
        !base::SetPosixFilePermissions(directory_.GetPath(), 0700)) return false;
    auto reservation = std::make_unique<net::TCPServerSocket>(nullptr, net::NetLogSource());
    if (reservation->Listen(net::IPEndPoint(net::IPAddress::IPv4Localhost(), 0),
                            1, std::nullopt) != net::OK) return false;
    net::IPEndPoint address;
    if (reservation->GetLocalAddress(&address) != net::OK) return false;
    port_ = address.port();
    const auto user = Token();
    const auto password = Token();
    credentials_.emplace(base::UTF8ToUTF16(user), base::UTF8ToUTF16(password));
    registration_ = Token();
    auto config = base::DictValue()
        .Set("log", base::DictValue().Set("loglevel", "none"))
        .Set("inbounds", base::ListValue().Append(base::DictValue()
            .Set("listen", "127.0.0.1").Set("port", port_).Set("protocol", "http")
            .Set("settings", base::DictValue().Set("accounts", base::ListValue()
                .Append(base::DictValue().Set("user", user).Set("pass", password))))))
        .Set("outbounds", base::ListValue().Append(outbound.Clone()));
    const auto config_path = directory_.GetPath().AppendASCII("config.json");
    std::string serialized;
    if (!base::JSONWriter::Write(config, &serialized)) return false;
    // Create private before writing secret bytes, rather than chmod after.
    base::File file(config_path, base::File::FLAG_CREATE | base::File::FLAG_WRITE);
    if (!file.IsValid() || !base::SetPosixFilePermissions(config_path, 0600) ||
        !file.WriteAtCurrentPosAndCheck(base::as_byte_span(serialized))) return false;
    file.Close();
    base::CommandLine command(binary);
    command.AppendArg("run");
    command.AppendArg("-config");
    command.AppendArgPath(config_path);
    base::LaunchOptions options;
    options.clear_environment = true;
    options.current_directory = directory_.GetPath();
    // Release the reservation immediately before launching. A port race is a
    // preparation failure: only the authenticated HTTPS probe may admit it.
    reservation.reset();
    base::File null_output(base::FilePath("/dev/null"),
                           base::File::FLAG_OPEN | base::File::FLAG_WRITE);
    if (!null_output.IsValid()) return false;
    options.fds_to_remap = {{null_output.GetPlatformFile(), 1},
                            {null_output.GetPlatformFile(), 2}};
    process_ = base::LaunchProcess(command, options);
    return process_.IsValid();
  }
  void StartProbe() {
    if (!Running()) {
      Complete(false, "The local proxy exited before becoming ready.");
      return;
    }
    request_.reset();
    if (!context_) {
      net::ProxyConfig proxy;
      proxy.proxy_rules().ParseFromString("http://127.0.0.1:" + base::NumberToString(port_));
      net::URLRequestContextBuilder builder;
      builder.DisableHttpCache();
      builder.set_proxy_config_service(std::make_unique<net::ProxyConfigServiceFixed>(
          net::ProxyConfigWithAnnotation(proxy, kCanaryAnnotation)));
      context_ = builder.Build();
    }
    auth_attempts_ = 0;
    request_ = context_->CreateRequest(GURL(kCanary), net::DEFAULT_PRIORITY,
                                       this, kCanaryAnnotation,
                                       net::handles::kInvalidNetworkHandle);
    request_->SetLoadFlags(net::LOAD_DISABLE_CACHE | net::LOAD_DO_NOT_SAVE_COOKIES);
    request_->set_disallow_credentials();
    request_->set_site_for_cookies(net::SiteForCookies());
    request_->Start();
  }
  void OnAuthRequired(net::URLRequest* request,
                      const net::AuthChallengeInfo& challenge) override {
    if (!challenge.is_proxy || challenge.challenger.host() != "127.0.0.1" ||
        challenge.challenger.port() != port_ || ++auth_attempts_ > 1) {
      Complete(false, "Local proxy authentication failed.");
      return;
    }
    authenticated_ = true;
    request->SetAuth(*credentials_);
  }
  void OnReceivedRedirect(net::URLRequest*, const net::RedirectInfo&,
                          bool* defer_redirect) override {
    *defer_redirect = true;
    Complete(false, "Unexpected proxy connectivity response.");
  }
  void OnSSLCertificateError(net::URLRequest*, int,
                             const net::SSLInfo&, bool) override {
    Complete(false, "Proxy connectivity certificate verification failed.");
  }
  void OnResponseStarted(net::URLRequest* request, int error) override {
    if (error == net::ERR_PROXY_CONNECTION_FAILED && !started_.is_null() &&
        base::TimeTicks::Now() - started_ < base::Seconds(3) && Running()) {
      retry_.Start(FROM_HERE, base::Milliseconds(100),
                   base::BindOnce(&Worker::StartProbe, base::Unretained(this)));
      return;
    }
    Complete(error == net::OK && request->GetResponseCode() == 204 && authenticated_,
              "The authorized proxy could not complete the HTTPS check.");
  }
  void OnReadCompleted(net::URLRequest*, int) override {}
  void Complete(bool ready, std::string error) {
    ready = ready && Running();
    timeout_.Stop();
    retry_.Stop();
    request_.reset();
    AccessLocalCoreReady result;
    result.ready = ready;
    if (ready) {
      result.port = port_;
      result.registration_id = registration_;
      result.local_credentials = credentials_;
      health_.Start(FROM_HERE, base::Seconds(1), base::BindRepeating(
          &Worker::CheckChild, base::Unretained(this)));
    } else {
      result.error = std::move(error);
      StopChild();
    }
    if (completion_) std::move(completion_).Run(std::move(result));
  }
  void CheckChild() {
    if (Running()) return;
    const auto registration = registration_;
    StopChild();
    if (stopped_callback_) stopped_callback_.Run(registration);
  }
  void StopChild() {
    health_.Stop();
    timeout_.Stop();
    retry_.Stop();
    request_.reset();
    context_.reset();
    if (process_.IsValid()) {
      if (Running()) process_.Terminate(0, true);
      process_.Close();
    }
    credentials_.reset();
    authenticated_ = false;
    const bool deleted = directory_.Delete();
    (void)deleted;
  }

  AccessLocalCoreInput input_;
  std::shared_ptr<ShutdownHandle> shutdown_;
  base::ScopedTempDir directory_;
  base::Process process_;
  uint16_t port_ = 0;
  std::string registration_;
  std::optional<net::AuthCredentials> credentials_;
  bool authenticated_ = false;
  int auth_attempts_ = 0;
  base::TimeTicks started_;
  base::OneShotTimer timeout_;
  base::OneShotTimer retry_;
  base::RepeatingTimer health_;
  std::unique_ptr<net::URLRequestContext> context_;
  std::unique_ptr<net::URLRequest> request_;
  base::OnceCallback<void(AccessLocalCoreReady)> completion_;
  base::RepeatingCallback<void(std::string)> stopped_callback_;
};

void AccessLocalCoreManager::ShutdownHandle::StopOnCoreThread() {
  if (!worker_) {
    CompleteStop();
    return;
  }
  worker_->Stop(base::BindOnce([](std::shared_ptr<ShutdownHandle> handle) {
    handle->CompleteStop();
  }, shared_from_this()));
}

AccessLocalCoreManager::AccessLocalCoreManager(AccessLocalCoreInput input) {
  base::Thread::Options options;
  options.message_pump_type = base::MessagePumpType::IO;
  thread_ = std::make_unique<base::Thread>("AccessLocalCore");
  CHECK(thread_->StartWithOptions(std::move(options)));
  shutdown_ = std::make_shared<ShutdownHandle>(thread_->task_runner());
  auto& handles = ShutdownHandle::Registry();
  std::erase_if(handles, [](const auto& handle) { return handle.expired(); });
  handles.emplace_back(shutdown_);
  worker_ = base::SequenceBound<Worker>(thread_->task_runner(), std::move(input),
                                      shutdown_);
}
AccessLocalCoreManager::~AccessLocalCoreManager() {
  worker_.Reset();
  thread_->DetachFromSequence();
  base::ThreadPool::PostTask(FROM_HERE,
      {base::MayBlock(), base::WithBaseSyncPrimitives(),
       base::TaskShutdownBehavior::BLOCK_SHUTDOWN},
      base::BindOnce([](std::unique_ptr<base::Thread> thread) { thread->Stop(); },
                     std::move(thread_)));
}
void AccessLocalCoreManager::Prepare(
    base::OnceCallback<void(AccessLocalCoreReady)> completion) {
  worker_.AsyncCall(&Worker::Prepare).WithArgs(
      base::BindPostTaskToCurrentDefault(std::move(completion)));
}
void AccessLocalCoreManager::Verify(
    base::OnceCallback<void(AccessLocalCoreReady)> completion) {
  worker_.AsyncCall(&Worker::Verify).WithArgs(
      base::BindPostTaskToCurrentDefault(std::move(completion)));
}
void AccessLocalCoreManager::Stop(base::OnceClosure completion) {
  worker_.AsyncCall(&Worker::Stop).WithArgs(
      base::BindPostTaskToCurrentDefault(std::move(completion)));
}
void AccessLocalCoreManager::StopAllForSessionEnding(base::OnceClosure completion) {
  std::vector<std::shared_ptr<ShutdownHandle>> handles;
  for (auto& weak : ShutdownHandle::Registry()) {
    if (auto handle = weak.lock()) handles.push_back(std::move(handle));
  }
  if (handles.empty()) {
    std::move(completion).Run();
    return;
  }
  auto stopped = base::BarrierClosure(handles.size(), std::move(completion));
  for (auto& handle : handles) handle->RequestStop(base::OnceClosure(stopped));
}
void AccessLocalCoreManager::SetStoppedCallback(
    base::RepeatingCallback<void(std::string)> callback) {
  worker_.AsyncCall(&Worker::SetStoppedCallback).WithArgs(
      base::BindPostTaskToCurrentDefault(std::move(callback)));
}
}  // namespace aegis::access

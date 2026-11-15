// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_local_core_manager.h"

#include <signal.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <vector>

#include "base/barrier_closure.h"
#include "base/strings/string_util.h"

#include "base/files/file_descriptor_watcher_posix.h"
#include "base/base64.h"
#include "chrome/browser/aegis/access/access_core_log_share.h"
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
#include "chrome/browser/aegis/access/access_build_channel.h"
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
#if BUILDFLAG(AEGIS_PRIVATE_TEST_NODE_ENABLED)
  if (AccessChannelForCurrentBuild() != BundledAccessTestChannel())
    return std::nullopt;
  base::FilePath assets;
  if (!base::PathService::Get(base::DIR_ASSETS, &assets)) return std::nullopt;
  assets = assets.AppendASCII("AegisAlphaAccess");
  return AccessLocalCoreInput{assets.AppendASCII("core-manifest.json"),
      assets.AppendASCII("node.json"), AccessLocalCoreSource::kPrivateTestBundle};
#elif BUILDFLAG(AEGIS_DEV_LOCAL_NODE_ALLOWED)
  if (AccessChannelForCurrentBuild() != aegis_access::ChannelNamespace::kDev)
    return std::nullopt;
  const auto* command = base::CommandLine::ForCurrentProcess();
  auto manifest = command->GetSwitchValuePath("aegis-access-dev-core-manifest");
  auto node = command->GetSwitchValuePath("aegis-access-dev-node-config");
  if (manifest.empty() || node.empty()) return std::nullopt;
  return AccessLocalCoreInput{std::move(manifest), std::move(node)};
#else
  return std::nullopt;
#endif
}
namespace {

const base::DictValue* SelectedOutbound(const base::DictValue& node) {
  const auto* outbounds = node.FindList("outbounds");
  if (!outbounds || outbounds->empty() || !outbounds->front().is_dict()) {
    return nullptr;
  }
  const auto& outbound = outbounds->front().GetDict();
  const auto* protocol = outbound.FindString("protocol");
  const auto* transport = outbound.FindStringByDottedPath("streamSettings.network");
  const auto* security = outbound.FindStringByDottedPath("streamSettings.security");
  return protocol && *protocol == "vless" && transport && *transport == "tcp" &&
                 security && *security == "reality" ? &outbound : nullptr;
}

}  // namespace

std::string ReadConfiguredAccessNodeId(const AccessLocalCoreInput& input) {
  std::string node_json;
  if (!base::ReadFileToStringWithMaxSize(input.node_config, &node_json, 1024 * 1024)) {
    return {};
  }
  auto node = base::JSONReader::ReadDict(node_json, base::JSON_PARSE_RFC);
  const auto* outbound = node ? SelectedOutbound(*node) : nullptr;
  const auto* servers = outbound ? outbound->FindListByDottedPath("settings.vnext") : nullptr;
  if (!servers || servers->empty() || !servers->front().is_dict()) {
    return {};
  }
  const auto& server = servers->front().GetDict();
  const auto* address = server.FindString("address");
  const int port = server.FindInt("port").value_or(0);
  if (!address || address->empty() || port <= 0 || port > 65535) {
    return {};
  }
  const auto label = base::ToLowerASCII(*address) + "\n" + base::NumberToString(port);
  const auto digest = crypto::hash::Sha256(base::as_byte_span(label));
  return base::HexEncodeLower(base::span(digest).first<6>());
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
// Refuse control characters before Xray can print a multiline node field as
// an independent diagnostic. Bound redaction work even for large configs.
bool CollectProtectedValues(const base::Value& value,
                            std::vector<std::string>& values,
                            std::string_view field = {}) {
  if (value.is_dict()) {
    for (auto entry : value.GetDict()) {
      if (!CollectProtectedValues(entry.second, values, entry.first))
        return false;
    }
  } else if (value.is_list()) {
    for (const auto& item : value.GetList()) {
      if (!CollectProtectedValues(item, values))
        return false;
    }
  } else if (value.is_string()) {
    const auto& text = value.GetString();
    if (std::any_of(text.begin(), text.end(), [](unsigned char c) {
          return c < 0x20 || c == 0x7f;
        }))
      return false;
    const bool structural = (field == "protocol" && text == "vless") ||
                            (field == "network" && text == "tcp") ||
                            (field == "security" && text == "reality") ||
                            (field == "flow" && text == "xtls-rprx-vision") ||
                            (field == "encryption" && text == "none");
    if (!structural && !text.empty() && values.size() < 256)
      values.push_back(base::ToLowerASCII(text));
  }
  return true;
}
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
    if (input_.source == AccessLocalCoreSource::kPrivateTestBundle) {
#if BUILDFLAG(AEGIS_PRIVATE_TEST_NODE_ENABLED)
      const auto* channel = manifest->FindString("channel");
      const auto* relative = manifest->FindString("binaryRelativePath");
      const auto* node_name = manifest->FindString("nodeConfigRelativePath");
      const auto* node_pin = manifest->FindString("nodeConfigSha256");
      if (manifest->FindInt("schemaVersion") != 1 || !channel ||
          *channel != LocalAccessIdentityChannel(BundledAccessTestChannel()) ||
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
    const auto* outbound = SelectedOutbound(*node);
    if (!outbound) return false;
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
    std::string level = "none";
    protected_values_ = {user, password, registration_,
                         base::ToLowerASCII(base::Base64Encode(user + ":" + password))};
    if (!CollectProtectedValues(base::Value(outbound->Clone()), protected_values_))
      return false;
    if (protected_values_.size() >= 256)
      protected_values_ = {""};  // A saturated budget suppresses every record.
    if (input_.log_store) {
      input_.log_store->SetProtectedValues(protected_values_);
      std::tie(level, log_generation_) = input_.log_store->LaunchConfig();
    }
    auto log = base::DictValue().Set("loglevel", level);
    if (CoreLogRank(level) >= 2) log.Set("access", "none");
    auto config = base::DictValue()
        .Set("log", std::move(log))
        .Set("inbounds", base::ListValue().Append(base::DictValue()
            .Set("listen", "127.0.0.1").Set("port", port_).Set("protocol", "http")
            .Set("settings", base::DictValue().Set("accounts", base::ListValue()
                .Append(base::DictValue().Set("user", user).Set("pass", password))))))
        .Set("outbounds", base::ListValue().Append(outbound->Clone()));
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
    base::ScopedFD read_end, write_end;
    int output = null_output.GetPlatformFile();
    auto create_log_pipe = input_.create_log_pipe_for_testing
                               ? input_.create_log_pipe_for_testing : &base::CreatePipe;
    if (level != "none" && create_log_pipe(&read_end, &write_end, /*non_blocking=*/true)) {
      // Diagnostic capture is optional; a failed pipe keeps /dev/null.
      log_read_ = base::File(std::move(read_end));
      output = write_end.get();
      log_clear_epoch_ = input_.log_store->RegisterPipe(log_read_.GetPlatformFile());
      log_watch_ = base::FileDescriptorWatcher::WatchReadable(
          log_read_.GetPlatformFile(),
          base::BindRepeating(&Worker::DrainLog, base::Unretained(this)));
    }
    options.fds_to_remap = {{output, STDOUT_FILENO}, {output, STDERR_FILENO}};
    process_ = base::LaunchProcess(command, options);
    return process_.IsValid();
  }
  void DrainLog() {
    std::array<char, 4096> chunk;
    for (int i = 0; i < 16 && log_read_.IsValid(); ++i) {
      const auto [count, error, epoch, prefix] =
          input_.log_store->ReadPipe(log_read_, chunk);
      if (epoch != log_clear_epoch_) {
        log_clear_epoch_ = epoch;
        framer_.DiscardPartial();
        discard_until_empty_ = !prefix.has_value();
        discard_bytes_ = prefix.value_or(0);
      }
      if (error == EAGAIN || error == EWOULDBLOCK) {
        discard_until_empty_ = false;
        discard_bytes_ = 0;
        return;
      }
      if (!count || *count == 0) {
        CloseLogPipe();
        break;
      }
      std::string_view bytes(chunk.data(), *count);
      const size_t discard = discard_until_empty_
                                 ? bytes.size() : std::min(discard_bytes_, bytes.size());
      if (discard) {
        framer_.Discard(bytes.substr(0, discard));
        if (!discard_until_empty_)
          discard_bytes_ -= discard;
        bytes.remove_prefix(discard);
      }
      framer_.Feed(bytes, [this, epoch](std::string_view line) {
        input_.log_store->Add(log_generation_, epoch, line, protected_values_);
      });
    }
  }
  void CloseLogPipe() {
    log_watch_.reset();
    if (log_read_.IsValid()) {
      input_.log_store->UnregisterPipe(log_read_.GetPlatformFile());
      log_read_.Close();
    }
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
  bool WaitForChildExit(base::TimeDelta maximum_wait) {
    auto deadline = maximum_wait.is_max()
        ? base::TimeTicks::Max() : base::TimeTicks::Now() + maximum_wait;
    bool session_bounded = false;
    for (;;) {
      // A session-ending request must also interrupt a Stop or destructor
      // already waiting on this thread. Retain the ordinary SIGTERM grace,
      // but bound each graceful/forced wait to one second during EndSession.
      if (!session_bounded && shutdown_->stop_requested()) {
        deadline = std::min(deadline, base::TimeTicks::Now() + base::Seconds(1));
        session_bounded = true;
      }
      const auto remaining = deadline - base::TimeTicks::Now();
      if (process_.WaitForExitWithTimeout(
              std::clamp(remaining, base::TimeDelta(), base::Milliseconds(100)),
              nullptr)) return true;
      if (remaining <= base::TimeDelta()) return false;
    }
  }
  void StopChild() {
    health_.Stop();
    timeout_.Stop();
    retry_.Stop();
    request_.reset();
    context_.reset();
    if (process_.IsValid()) {
      if (Running()) {
        process_.Terminate(0, false);
        if (!WaitForChildExit(base::Seconds(60)) &&
            kill(process_.Pid(), SIGKILL) == 0) {
          WaitForChildExit(base::TimeDelta::Max());
        }
      }
      process_.Close();
    }
    DrainLog();
    CloseLogPipe();
    framer_ = CoreLogFramer();
    discard_bytes_ = 0;
    discard_until_empty_ = false;
    protected_values_.clear();
    credentials_.reset();
    authenticated_ = false;
    const bool deleted = directory_.Delete();
    (void)deleted;
  }

  AccessLocalCoreInput input_;
  std::shared_ptr<ShutdownHandle> shutdown_;
  base::File log_read_;
  std::unique_ptr<base::FileDescriptorWatcher::Controller> log_watch_;
  CoreLogFramer framer_;
  uint64_t log_generation_ = 0;
  uint64_t log_clear_epoch_ = 0;
  size_t discard_bytes_ = 0;
  bool discard_until_empty_ = false;
  std::vector<std::string> protected_values_;
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
  auto stopped = base::BarrierClosure(
      handles.size() + 1,
      base::BindOnce(&AccessCoreLogStore::FlushAllForSessionEnding,
                     std::move(completion)));
  CoreLogShareSession::StopAllForSessionEnding(base::OnceClosure(stopped));
  for (auto& handle : handles) handle->RequestStop(base::OnceClosure(stopped));
}
void AccessLocalCoreManager::SetStoppedCallback(
    base::RepeatingCallback<void(std::string)> callback) {
  worker_.AsyncCall(&Worker::SetStoppedCallback).WithArgs(
      base::BindPostTaskToCurrentDefault(std::move(callback)));
}
}  // namespace aegis::access

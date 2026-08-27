// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/policy_worker.cc

#include "chrome/browser/aegis/policy_worker.h"

#include <utility>

#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/memory/singleton.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/aegis/generated/policy_worker_source.inc"
#include "gin/converter.h"
#include "gin/public/isolate_holder.h"
#include "gin/try_catch.h"
#include "v8/include/v8-context.h"
#include "v8/include/v8-function.h"
#include "v8/include/v8-isolate.h"
#include "v8/include/v8-local-handle.h"
#include "v8/include/v8-message.h"
#include "v8/include/v8-object.h"
#include "v8/include/v8-primitive.h"
#include "v8/include/v8-script.h"

namespace aegis {

// static
PolicyWorker* PolicyWorker::GetInstance() {
  return base::Singleton<PolicyWorker>::get();
}

PolicyWorker::PolicyWorker() = default;

PolicyWorker::~PolicyWorker() {
  if (thread_ && thread_->IsRunning()) {
    thread_->task_runner()->PostTask(
        FROM_HERE, base::BindOnce(&PolicyWorker::ShutdownOnWorker,
                                  base::Unretained(this)));
    thread_->Stop();
  }
}

std::string PolicyWorker::last_error() const {
  base::AutoLock lock(status_lock_);
  return last_error_;
}

void PolicyWorker::SetLastError(std::string error) {
  base::AutoLock lock(status_lock_);
  last_error_ = std::move(error);
}

void PolicyWorker::Start() {
  if (thread_) {
    return;
  }
  // The browser process does not load V8's external snapshot.
  // gin::V8Initializer::LoadV8Snapshot() is LOG(FATAL) on failure, so never
  // call it here. The JS bundle instead runs in chrome://aegis (renderer V8).
  // If this process already initialized gin (utility / tests), reuse it.
  if (!gin::IsolateHolder::Initialized()) {
    SetLastError(
        "browser process has no V8 snapshot; JS worker runs in chrome://aegis");
    VLOG(1) << "Aegis: " << last_error();
    return;
  }
  thread_ = std::make_unique<base::Thread>("AegisPolicyWorker");
  if (!thread_->Start()) {
    SetLastError("failed to start policy worker thread");
    LOG(ERROR) << "Aegis: " << last_error();
    thread_.reset();
    return;
  }
  thread_->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(&PolicyWorker::InitOnWorker, base::Unretained(this)));
}

void PolicyWorker::Evaluate(std::string request_json, EvaluateCallback done) {
  if (!thread_ || !thread_->IsRunning()) {
    std::move(done).Run(R"({"error":"worker not started"})");
    return;
  }
  auto reply = base::SequencedTaskRunner::GetCurrentDefault();
  thread_->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(&PolicyWorker::EvaluateOnWorker, base::Unretained(this),
                     std::move(request_json), std::move(reply),
                     std::move(done)));
}

void PolicyWorker::InitOnWorker() {
  if (!gin::IsolateHolder::Initialized()) {
    SetLastError("gin isolate holder not initialized");
    LOG(ERROR) << "Aegis: " << last_error();
    return;
  }

  isolate_holder_ = std::make_unique<gin::IsolateHolder>(
      base::SingleThreadTaskRunner::GetCurrentDefault(),
      gin::IsolateHolder::kSingleThread,
      gin::IsolateHolder::IsolateType::kUtility);

  v8::Isolate* isolate = isolate_holder_->isolate();
  v8::Isolate::Scope isolate_scope(isolate);
  v8::HandleScope handle_scope(isolate);
  v8::Local<v8::Context> context = v8::Context::New(isolate);
  v8::Context::Scope context_scope(context);
  gin::TryCatch try_catch(isolate);

  v8::Local<v8::String> source =
      gin::StringToV8(isolate, kAegisPolicyWorkerJs);
  v8::Local<v8::String> name =
      gin::StringToV8(isolate, "aegis-policy-worker.js");
  v8::ScriptOrigin origin(name);
  v8::ScriptCompiler::Source script_source(source, origin);
  v8::Local<v8::Script> script;
  if (!v8::ScriptCompiler::Compile(context, &script_source)
           .ToLocal(&script)) {
    SetLastError(try_catch.HasCaught() ? try_catch.GetStackTrace()
                                       : "compile failed");
    LOG(ERROR) << "Aegis: policy worker compile failed: " << last_error();
    isolate_holder_.reset();
    return;
  }
  if (script->Run(context).IsEmpty()) {
    SetLastError(try_catch.HasCaught() ? try_catch.GetStackTrace()
                                       : "run failed");
    LOG(ERROR) << "Aegis: policy worker run failed: " << last_error();
    isolate_holder_.reset();
    return;
  }

  context_.Reset(isolate, context);
  SetLastError(std::string());
  ready_.store(true, std::memory_order_release);
  LOG(INFO) << "Aegis: policy worker ready";
}

void PolicyWorker::ShutdownOnWorker() {
  ready_.store(false, std::memory_order_release);
  context_.Reset();
  isolate_holder_.reset();
}

void PolicyWorker::EvaluateOnWorker(
    std::string request_json,
    scoped_refptr<base::SequencedTaskRunner> reply,
    EvaluateCallback done) {
  std::string result = RunEvaluate(request_json);
  reply->PostTask(FROM_HERE,
                  base::BindOnce(std::move(done), std::move(result)));
}

std::string PolicyWorker::RunEvaluate(const std::string& request_json) {
  if (!ready() || !isolate_holder_) {
    const std::string error = last_error();
    return error.empty() ? R"({"error":"worker not ready"})"
                         : R"({"error":")" + error + R"("})";
  }

  v8::Isolate* isolate = isolate_holder_->isolate();
  v8::Isolate::Scope isolate_scope(isolate);
  v8::HandleScope handle_scope(isolate);
  v8::Local<v8::Context> context = context_.Get(isolate);
  v8::Context::Scope context_scope(context);
  gin::TryCatch try_catch(isolate);

  v8::Local<v8::Value> fn_val;
  if (!context->Global()
           ->Get(context, gin::StringToV8(isolate, "aegisEvaluate"))
           .ToLocal(&fn_val) ||
      !fn_val->IsFunction()) {
    return R"({"error":"aegisEvaluate missing"})";
  }

  v8::Local<v8::Value> argv[] = {gin::StringToV8(isolate, request_json)};
  v8::Local<v8::Value> result;
  if (!fn_val.As<v8::Function>()
           ->Call(context, context->Global(), 1, argv)
           .ToLocal(&result)) {
    const std::string err = try_catch.HasCaught() ? try_catch.GetStackTrace()
                                                  : "evaluate failed";
    return std::string(R"({"error":")") + err + R"("})";
  }
  return gin::V8ToString(isolate, result);
}

}  // namespace aegis

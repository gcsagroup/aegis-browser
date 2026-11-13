// Copyright 2026 GCSA
// Loopback-only fault fixture. It never opens an outbound connection and never
// records a request header or the generated proxy credentials.

#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>

#include <array>
#include <string>

#include "base/at_exit.h"
#include "base/base64.h"
#include "base/command_line.h"
#include "base/containers/span.h"
#include "base/files/file.h"
#include "base/files/file_util.h"
#include "base/files/scoped_file.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/posix/eintr_wrapper.h"
#include "base/values.h"

namespace {
int termination_marker_fd = -1;
void IgnoreTermination(int) {
  // Only async-signal-safe operations here. The marker proves that production
  // Stop has already sent SIGTERM before a later session-ending request.
  constexpr char marker = 'x';
  const auto written = write(termination_marker_fd, &marker, 1);
  (void)written;
}
void Record(const base::FilePath& path, const char* phase, int requests) {
  std::string json;
  const auto args = base::CommandLine::ForCurrentProcess()->GetArgs();
  if (!base::JSONWriter::Write(base::DictValue()
          .Set("phase", phase).Set("pid", static_cast<int>(getpid()))
          .Set("configDirectory", base::FilePath(args.back()).DirName().value())
          .Set("requests", requests), &json)) return;
  base::File file(path, base::File::FLAG_CREATE_ALWAYS | base::File::FLAG_WRITE);
  if (file.IsValid() && base::SetPosixFilePermissions(path, 0600))
    file.WriteAtCurrentPosAndCheck(base::as_byte_span(json));
}

std::string ReadHeaders(base::File& connection) {
  std::string headers;
  std::array<uint8_t, 2048> buffer;
  while (headers.size() < 65536 && headers.find("\r\n\r\n") == std::string::npos) {
    const auto read = connection.ReadAtCurrentPosNoBestEffort(buffer);
    if (!read || !*read) break;
    headers.append(base::as_string_view(base::span(buffer).first(*read)));
  }
  return headers;
}
}  // namespace

int main(int argc, const char* argv[]) {
  base::AtExitManager at_exit;
  base::CommandLine::Init(argc, argv);
  const auto* command = base::CommandLine::ForCurrentProcess();
  const auto args = command->GetArgs();
  if (args.size() != 2 || args.front() != "run" || !command->HasSwitch("config")) return 2;
  std::string json;
  if (!base::ReadFileToString(base::FilePath(args.back()), &json)) return 3;
  auto config = base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
  if (!config) return 3;
  const auto* inbounds = config->FindList("inbounds");
  const auto* outbounds = config->FindList("outbounds");
  if (!inbounds || inbounds->empty() || !outbounds || outbounds->empty()) return 3;
  const auto& inbound = inbounds->front().GetDict();
  const auto& outbound = outbounds->front().GetDict();
  const auto* mode = outbound.FindString("tag");
  const auto* state = outbound.FindStringByDottedPath("settings.fixtureStateFile");
  const auto port = inbound.FindInt("port");
  if (!mode || !state || !port) return 3;
  if (*mode == "exit-with-diagnostic") {
    const auto* level = config->FindStringByDottedPath("log.loglevel");
    if (level && *level == "warning") {
      constexpr char record[] = "2026/11/11 12:10:09 [Warning] core: Xray 1.2.3 started\n";
      if (write(STDERR_FILENO, record, sizeof(record) - 1) < 0) return 5;
    }
    return 4;
  }
  if (*mode == "exit-before-listen") return 4;
  const auto* accounts = inbound.FindListByDottedPath("settings.accounts");
  if (!accounts || accounts->empty()) return 3;
  const auto& account = accounts->front().GetDict();
  const auto* user = account.FindString("user");
  const auto* password = account.FindString("pass");
  if (!user || !password) return 3;
  const std::string credential = base::Base64Encode(*user + ":" + *password);
  const base::FilePath state_path(*state);
  base::File termination_marker;
  if (*mode == "ignore-term") {
    const auto marker_path = state_path.AddExtensionASCII("sigterm");
    termination_marker.Initialize(marker_path,
        base::File::FLAG_CREATE_ALWAYS | base::File::FLAG_WRITE);
    if (!termination_marker.IsValid() ||
        !base::SetPosixFilePermissions(marker_path, 0600)) return 5;
    termination_marker_fd = termination_marker.GetPlatformFile();
    signal(SIGTERM, IgnoreTermination);
  }
  signal(SIGPIPE, SIG_IGN);
  base::ScopedFD listener(socket(AF_INET, SOCK_STREAM, 0));
  if (!listener.is_valid()) return 5;
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(static_cast<uint16_t>(*port));
  if (bind(listener.get(), reinterpret_cast<sockaddr*>(&address), sizeof(address)) ||
      listen(listener.get(), 8)) return 5;
  Record(state_path, "listening", 0);
  int requests = 0;
  for (;;) {
    base::File connection(HANDLE_EINTR(accept(listener.get(), nullptr, nullptr)));
    if (!connection.IsValid()) return 6;
    const auto headers = ReadHeaders(connection);
    if (headers.empty()) continue;
    ++requests;
    std::string response;
    if (*mode == "unauthenticated-response") {
      Record(state_path, "unauthenticated-response", requests);
      response = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n";
    } else if (*mode == "reject-auth" || headers.find(credential) == std::string::npos) {
      Record(state_path, "auth-challenge", requests);
      response = "HTTP/1.1 407 Proxy Authentication Required\r\n"
                 "Proxy-Authenticate: Basic realm=\"fixture\"\r\n"
                 "Content-Length: 0\r\nConnection: close\r\n\r\n";
    } else if (*mode == "target-unavailable") {
      Record(state_path, "authenticated-target-unavailable", requests);
      response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n"
                 "Connection: close\r\n\r\n";
    } else {
      response = "HTTP/1.1 200 Connection Established\r\n\r\n";
      if (!connection.WriteAtCurrentPosAndCheck(base::as_byte_span(response))) continue;
      Record(state_path, "authenticated-tunnel-held", requests);
      std::array<uint8_t, 2048> buffer;
      while (const auto read = connection.ReadAtCurrentPosNoBestEffort(buffer)) {
        if (!*read) break;
      }
      continue;
    }
    connection.WriteAtCurrentPosAndCheck(base::as_byte_span(response));
  }
}

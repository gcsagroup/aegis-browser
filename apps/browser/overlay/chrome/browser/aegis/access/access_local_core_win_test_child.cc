// Copyright 2026 GCSA
// Windows 核心进程夹具：验证最小网络环境以及作业退出时的进程树和配置清理。
#include <winsock2.h>
#include <windows.h>

#include <array>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>

#include "base/compiler_specific.h"

namespace {

// 真实创建套接字，防止测试只比较字符串而漏掉 Winsock 对环境的依赖。
int CheckNetworkEnvironment() {
  std::array<wchar_t, MAX_PATH> actual{};
  std::array<wchar_t, MAX_PATH> expected{};
  const DWORD actual_length = ::GetEnvironmentVariableW(
      L"SystemRoot", actual.data(), actual.size());
  const UINT expected_length =
      ::GetWindowsDirectoryW(expected.data(), expected.size());
  if (actual_length == 0 || actual_length >= actual.size() ||
      expected_length == 0 || expected_length >= expected.size() ||
      std::wstring_view(actual.data(), actual_length) !=
          std::wstring_view(expected.data(), expected_length)) {
    return 10;
  }
  for (const auto* key : {L"AEGIS_CORE_TEST_SECRET", L"HTTP_PROXY", L"PATH"}) {
    if (::GetEnvironmentVariableW(key, nullptr, 0) != 0) {
      return 11;
    }
  }
  WSADATA data{};
  if (::WSAStartup(MAKEWORD(2, 2), &data) != 0) {
    return 12;
  }
  const SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  const bool valid = socket != INVALID_SOCKET;
  if (valid) ::closesocket(socket);
  ::WSACleanup();
  return valid ? 0 : 13;
}

}  // namespace

// 夹具参数仅接受固定测试模式；正常模式保持配置占用，供父进程验证退出清理。
int wmain(int argc, wchar_t* argv[]) {
  // The CRT provides argc pointers. Each argument access is count-checked.
  if (argc == 2 &&
      UNSAFE_BUFFERS(std::wstring_view(argv[1])) == L"--access-fixture-environment") {
    return CheckNetworkEnvironment();
  }
  if (argc == 2 &&
      UNSAFE_BUFFERS(std::wstring_view(argv[1])) == L"--access-fixture-grandchild") {
    // Keep the private configuration open without sharing deletion.
    HANDLE config = ::CreateFileW(L"config.json", GENERIC_READ, FILE_SHARE_READ,
                                  nullptr, OPEN_EXISTING,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);
    if (config == INVALID_HANDLE_VALUE) {
      return 6;
    }
    {
      std::ofstream ready("grandchild-ready");
      ready << "ready\n";
      ready.close();
      if (!ready) {
        ::CloseHandle(config);
        return 7;
      }
    }
    ::Sleep(INFINITE);
    ::CloseHandle(config);
    return 0;
  }
  std::error_code error;
  const auto directory = std::filesystem::current_path(error);
  if (error) {
    return 1;
  }
  const auto config_path = directory / L"config.json";
  if (argc != 4 || UNSAFE_BUFFERS(std::wstring_view(argv[1])) != L"run" ||
      UNSAFE_BUFFERS(std::wstring_view(argv[2])) != L"-config" ||
      UNSAFE_BUFFERS(std::filesystem::path(argv[3])) != config_path) {
    return 2;
  }
  {
    std::ifstream config(config_path);
    if (config.peek() != '{') {
      return 3;
    }
  }
  std::wstring child_command = L"\"access fixture\" --access-fixture-grandchild";
  STARTUPINFOW startup{.cb = sizeof(startup)};
  PROCESS_INFORMATION child = {};
  if (!::CreateProcessW(argv[0], child_command.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child)) {
    return 4;
  }
  ::CloseHandle(child.hProcess);
  ::CloseHandle(child.hThread);
  {
    std::ofstream pids(directory / L"fixture-pids");
    pids << ::GetCurrentProcessId() << ' ' << child.dwProcessId << '\n';
    pids.close();
    if (!pids) {
      return 5;
    }
  }
  ::Sleep(INFINITE);
  return 0;
}

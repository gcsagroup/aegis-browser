// Copyright 2026 The GCSA Aegis Authors
// mini_installer 与 setup 的单向展示通道；不传路径、命令或安装决策，不依赖
// CRT。
#ifndef CHROME_INSTALLER_AEGIS_INSTALL_PROGRESS_H_
#define CHROME_INSTALLER_AEGIS_INSTALL_PROGRESS_H_

#include <windows.h>

namespace aegis_installer {

inline constexpr char kProgressSwitch[] = "aegis-install-progress";
inline constexpr wchar_t kProgressNamePrefix[] = L"Local\\GCSA.Aegis.Progress.";

// 百分比仅描述当前可计量阶段；-1 表示无可靠分母，不能据此推测剩余时间。
enum class Phase : unsigned {
  kPreparing,
  kDecompressing,
  kUnpacking,
  kInstalling,
  kConfiguring,
  kFinishing,
  kRollingBack
};
struct Progress {
  Phase phase = Phase::kPreparing;
  int percent = -1;
};

// 随机名称限于当前会话，沿用创建者默认 DACL；不放宽权限给 Everyone。
// 每次安装使用独立的 128 位随机名称；UAC 之后无权连接时退回无百分比展示。
// 映射仅有一个原子 DWORD，避免读到不同阶段和百分比的撕裂组合。
class ProgressChannel {
 public:
  ProgressChannel() = default;
  ~ProgressChannel() { Close(); }
  ProgressChannel(const ProgressChannel&) = delete;
  ProgressChannel& operator=(const ProgressChannel&) = delete;

  static bool IsValidName(const wchar_t* name) {
    const int prefix_length = ::lstrlenW(kProgressNamePrefix);
    if (!name || ::lstrlenW(name) != prefix_length + 32 ||
        ::CompareStringOrdinal(name, prefix_length, kProgressNamePrefix,
                               prefix_length, FALSE) != CSTR_EQUAL)
      return false;
    const wchar_t* digit = name;
    for (int index = 0; index < prefix_length; ++index)
      digit = ::CharNextW(digit);
    for (int index = 0; index < 32; ++index, digit = ::CharNextW(digit)) {
      if (!((*digit >= L'0' && *digit <= L'9') ||
            (*digit >= L'a' && *digit <= L'f')))
        return false;
    }
    return true;
  }

  // 名称冲突时拒绝复用现存对象；参数句柄不继承给其他子进程。
  bool Create(const wchar_t* name) {
    Close();
    if (!IsValidName(name))
      return false;
    mapping_ = ::CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr,
                                    PAGE_READWRITE, 0, sizeof(LONG), name);
    if (!mapping_ || ::GetLastError() == ERROR_ALREADY_EXISTS) {
      Close();
      return false;
    }
    if (!Map())
      return false;
    Write(Phase::kPreparing, -1);
    return true;
  }

  // setup 只打开父安装器预先创建的对象；失败不会创建对象或改变安装结果。
  bool Open(const wchar_t* name) {
    Close();
    if (!IsValidName(name))
      return false;
    mapping_ = ::OpenFileMappingW(FILE_MAP_READ | FILE_MAP_WRITE, FALSE, name);
    return mapping_ && Map();
  }

  // 释放当前进程持有的映射；最后一个进程关闭后由内核回收，不留下磁盘文件。
  void Close() {
    if (packet_)
      ::UnmapViewOfFile(const_cast<LONG*>(packet_));
    if (mapping_)
      ::CloseHandle(mapping_);
    packet_ = nullptr;
    mapping_ = nullptr;
  }

  // 100% 只由父进程确认安装退出成功后展示；阶段内最多 99%，保留最终校验。
  void Write(Phase phase, int percent) const {
    if (!packet_ ||
        static_cast<unsigned>(phase) >
            static_cast<unsigned>(Phase::kRollingBack) ||
        percent < -1 || percent > 99)
      return;
    DWORD value = 0xa6010000u | (static_cast<unsigned>(phase) << 8) |
                  (percent < 0 ? 255u : static_cast<unsigned>(percent));
    ::InterlockedExchange(packet_, static_cast<LONG>(value));
  }

  // 拒绝损坏或未知版本的数据；本通道不能用来宣告安装成功或驱动任何系统操作。
  bool Read(Progress* progress) const {
    if (!packet_ || !progress)
      return false;
    DWORD value =
        static_cast<DWORD>(::InterlockedCompareExchange(packet_, 0, 0));
    unsigned phase = (value >> 8) & 255;
    unsigned percent = value & 255;
    if ((value & 0xffff0000u) != 0xa6010000u ||
        phase > static_cast<unsigned>(Phase::kRollingBack) ||
        (percent > 99 && percent != 255))
      return false;
    *progress = {static_cast<Phase>(phase),
                 percent == 255 ? -1 : static_cast<int>(percent)};
    return true;
  }

 private:
  bool Map() {
    packet_ = static_cast<volatile LONG*>(::MapViewOfFile(
        mapping_, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, sizeof(LONG)));
    if (!packet_)
      Close();
    return packet_ != nullptr;
  }
  HANDLE mapping_ = nullptr;
  // MapViewOfFile 地址由内核管理，不属于 PartitionAlloc；不能用 raw_ptr 管理。
  // 直接标注以保持此协议头不依赖 Chromium 分配器或 CRT。
#if defined(__clang__)
  __attribute__((annotate("raw_ptr_exclusion")))
#endif
  volatile LONG* packet_ = nullptr;
};
}  // namespace aegis_installer

#endif  // CHROME_INSTALLER_AEGIS_INSTALL_PROGRESS_H_

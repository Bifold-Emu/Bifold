// JIT availability detection. Licensed under GPLv2 or any later version.

#include <atomic>
#include <cstdlib>
#include <cstring>

#include "az_internal.h"

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);
#endif

namespace AzIOS {

namespace {
#if defined(__APPLE__)
constexpr unsigned int CS_OPS_STATUS = 0;
constexpr uint32_t CS_DEBUGGED = 0x10000000;

bool IsDebugged() {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & CS_DEBUGGED) != 0;
}

bool IsTraced() {
    struct kinfo_proc info;
    std::memset(&info, 0, sizeof(info));
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &info, &size, nullptr, 0) != 0) {
        return false;
    }
    return (info.kp_proc.p_flag & 0x00000800 /* P_TRACED */) != 0;
}

/// Same probe as oaknut's ios_jit::LegacyJitWorks(): can this process still turn its own pages
/// executable? On TXM devices (A15+ on iOS 26) mprotect(PROT_EXEC) "succeeds" but the execute
/// bit is stripped, so the resulting protection is read back. Nothing is executed.
bool LegacyJitWorks() {
    const size_t size = 16 * 1024;
    void* p = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) {
        return false;
    }
    *static_cast<uint32_t*>(p) = 0xD65F03C0; // ret
    bool ok = mprotect(p, size, PROT_READ | PROT_EXEC) == 0;
    if (ok) {
        vm_address_t address = reinterpret_cast<vm_address_t>(p);
        vm_size_t region_size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        ok = vm_region_64(mach_task_self(), &address, &region_size, VM_REGION_BASIC_INFO_64,
                          reinterpret_cast<vm_region_info_t>(&info), &count, &object) == KERN_SUCCESS &&
             (info.protection & VM_PROT_EXECUTE) != 0;
    }
    munmap(p, size);
    return ok;
}
#endif
} // namespace

AZJitStatus DetectJit() {
#if defined(AZIOS_APPSTORE)
    return AZ_JIT_DISABLED_BUILD;
#elif defined(__APPLE__) && TARGET_OS_IPHONE
    // Must agree with oaknut's ios_jit::GetMode(), otherwise the core would emit code into
    // pages that can never become executable (SIGBUS on the first block, measured on an
    // iPhone 14 Pro Max / iOS 26.7.1 after a debugger attached and detached again).
    const char* mode = std::getenv("OAKNUT_IOS_JIT_MODE");
    if (!IsDebugged()) {
        return AZ_JIT_UNAVAILABLE;
    }
    const bool traced = IsTraced();
    if (mode && std::strcmp(mode, "universal") == 0) {
        // The region is requested with brk #0xf00d: without a debugger that would be a SIGTRAP.
        return traced ? AZ_JIT_TXM_SCRIPT : AZ_JIT_UNAVAILABLE;
    }
    const bool legacy_ok = LegacyJitWorks();
    if (mode && std::strcmp(mode, "legacy") == 0) {
        return legacy_ok ? AZ_JIT_LEGACY : AZ_JIT_UNAVAILABLE;
    }
    if (legacy_ok) {
        return AZ_JIT_LEGACY;
    }
    // TXM device: only the debugger-script path works, and only while the debugger is attached.
    return traced ? AZ_JIT_TXM_SCRIPT : AZ_JIT_UNAVAILABLE;
#else
    // Desktop hosts (unit tests) can always map executable memory.
    return AZ_JIT_LEGACY;
#endif
}

} // namespace AzIOS

namespace AzIOS {
namespace {
std::atomic<int> g_session_jit{-1};
}
void SetSessionJit(AZJitStatus status) {
    g_session_jit = static_cast<int>(status);
}
} // namespace AzIOS

extern "C" AZJitStatus az_jit_status(void) {
    // While a game runs, report what it actually runs with.
    const int session = AzIOS::g_session_jit.load();
    if (session >= 0) {
        return static_cast<AZJitStatus>(session);
    }
    return AzIOS::DetectJit();
}

#pragma once

// Flat 4 GiB guest address space: a guest access is just `*(T*)(kFlatGuestBase + addr)` plus a
// byte swap, no page-table load/branch. Two views alias the same physical memory: the GUEST
// view at kFlatGuestBase has page protections as the interception mechanism (unmapped/MMIO/
// executable/deferred-read pages are uncommitted or protected), while the HOST view is a plain
// alias native runtime code (image loading, DVD reads, HLE, GX) writes through unchecked.
#include <cstddef>
#include <cstdint>
#include <vector>

namespace GuestFlat {

inline constexpr uint64_t kGuestSpaceSize = 0x1'0000'0000ull;

// Every guest address this runtime ever actually dereferences has the top bit set - real
// Wii/GameCube hardware never legitimately addresses below this (RAM, MMIO, and everything else
// this module maps all live at 0x80000000 and up), so EnsureReservation() only needs to reserve
// host memory for the top half of the 4 GiB conceptual guest space, [g_base +
// kGuestReservationBase, g_base + kGuestSpaceSize), not the full 4 GiB. g_base itself still
// conceptually points at "guest address 0" so every existing `g_base + addr` /
// MKW_FLAT_GUEST_BASE + addr formula throughout this runtime and every translated function
// keeps working unchanged; only the actual mmap/VirtualAlloc2 reservation (and
// HandleAccessViolation's admissible-fault range) need to know the bottom half was never really
// reserved. This roughly halves the process's virtual memory footprint, which matters on iOS -
// see g_base's comment below for why the address itself, not just the size, turned out to
// matter there too.
inline constexpr uint64_t kGuestReservationBase = 0x8000'0000ull;

// The live reservation's conceptual "guest address 0", set once by EnsureReservation() and read
// by every translated function's memory access via MKW_FLAT_GUEST_BASE below.
//
// This used to be a compile-time constant (a fixed high address, 16 TiB - clear of the Windows
// ASan shadow at 32 TiB and of the usual image/heap placement), which let the emitted guest
// access compile to `[reg + imm64-in-register]` with no load of a global. That doesn't work on
// iOS: a sideloaded app without the Extended Virtual Addressing entitlement cannot obtain memory
// anywhere near that address at all - not "not enough size available there", the OS will not
// place a mapping that high for such a process at any size, silently handing back a mapping
// elsewhere instead (which EnsureReservation() then correctly rejects as "the fixed base was not
// honored"). There is no fixed address that is simultaneously high enough to be clear of a
// desktop process's normal layout (matters on Windows/Linux/macOS) and low enough to be reachable
// by a non-entitled iOS process (which is capped at roughly 7 GiB of *total* usable address
// space) - the two constraints are incompatible. So on every platform this runtime targets, the
// reservation now asks the OS to place it anywhere free (no address hint at all) instead of
// gambling on one fixed guess, and every access pays one small global-variable load in exchange
// (a load that is effectively always an L1 hit - this pointer is read constantly and never
// written after startup - and is comparable in cost to the multi-instruction sequence ARM64
// needs to materialize a 48-bit immediate like the old fixed base anyway, so the desktop
// platforms that didn't strictly need this change shouldn't see a meaningful regression from it
// either).
extern uint8_t* g_base;

#define MKW_FLAT_GUEST_BASE (GuestFlat::g_base)

enum class Backing {
    Owned,
    Mem1,
    Mem2,
};

struct RegionRequest {
    uint32_t base = 0;
    uint64_t size = 0;
    Backing backing = Backing::Owned;
};

struct FaultCounters {
    uint32_t mmio = 0;      // MMIO access that reached the handler
    uint32_t efb = 0;       // deferred (EFB) read materialized from a trap
    uint32_t xguard = 0;    // executable-page write trap
    uint32_t unmapped = 0;  // guest touches that landed outside every mapped region
    uint32_t unmappedRegions = 0;  // distinct 64 KiB blocks committed on demand
};

// True once the reservation exists and translated code may use the flat path.
bool IsActive();

// Reserves the 4 GiB space (once per process) and maps every requested region
// into both views. Throws std::runtime_error with a precise diagnosis when the
// reservation, the section objects or a view cannot be created - a silent
// fallback would let translated code read from an unmapped constant base.
void Initialize(const std::vector<RegionRequest>& regions);

// Host-view pointer for a mapped guest address, or nullptr when the address is
// outside every mapped region. This is what the page table and
// Memory::GetPointer hand out.
uint8_t* HostPointer(uint32_t guestAddress);

// Deferred (EFB) reads: the covered guest pages are made PAGE_NOACCESS in the
// guest view so a flat read traps and materializes the copy.
void ProtectDeferredRange(uint32_t address, size_t length);
void UnprotectDeferredRange(uint32_t address, size_t length);

// Executable-write guard: pages fully covered by a registered executable range
// become PAGE_READONLY in the guest view. Registration order does not matter -
// ranges registered before the mapping exists are re-applied by Initialize.
void RegisterExecutableRange(uint32_t start, uint32_t end);

FaultCounters Counters();

// End-of-run report for the counters above. An unmapped touch is a wild guest
// pointer whose block this module silently committed so execution could go on,
// which makes it invisible unless it is repeated at shutdown; a nonzero count
// is therefore reported as a warning. Idempotent, so every exit path (normal
// return, caught exception, abort handler) may call it.
void LogFaultSummary() noexcept;

// Returns true when the access violation was a guest-space fault this module
// resolved; the caller must then resume execution. `faultAddress` is the raw
// host pointer the access violation trapped on (Windows: ExceptionInformation[1];
// POSIX: siginfo_t::si_addr) and `isWrite` is whether it was a write access
// (Windows: ExceptionInformation[0] != 0; POSIX: derived from the ucontext).
// The platform-specific handler that calls this is expected to have already
// done that extraction - this function only ever works with the parsed pair.
bool HandleAccessViolation(void* faultAddress, bool isWrite) noexcept;

} // namespace GuestFlat

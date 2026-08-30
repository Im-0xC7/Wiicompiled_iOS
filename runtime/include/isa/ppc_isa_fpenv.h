#pragma once
// FPSCR[NI] (non-IEEE flush-to-zero) modeled on the host FP environment, plus
// the thread-local mirror of that state the hot paths read instead of MXCSR.

#include "ppc_isa_config.h"

#include <cstdint>

// Software-flushing Gekko's single-precision denormals per op roughly doubled the THP IDCT
// kernel's cycle count, so instead the runtime mirrors guest FPSCR[NI] into a host flush-to-zero
// control bit wherever FPSCR can change (PPC_Mtfs*, fiber context switches, CpuContextScope),
// making per-op flushes free. Accepted deviations (same trade Dolphin makes): flush-to-zero also
// flushes double denormals unlike real NI, and a pre-round-flush edge near FLT_MIN rounds via a
// double->float conversion instead.
//
// x86-64: MXCSR's FTZ (output denormals) and DAZ (input denormals) bits, read/written via
// _mm_getcsr()/_mm_setcsr(). arm64: AArch64 FPCR.FZ (bit 24) is the direct analog - unlike MXCSR
// it flushes both input and output denormals with the single bit, and (being a core-wide control
// register, not a SIMD-unit-only one) it governs plain scalar float arithmetic exactly the same
// way it would govern NEON, so the scalar paired-single port in ppc_isa_float.h/ppc_isa_quantized.h
// gets the same "hardware already flushed it" free lunch the SSE path relies on.
#if defined(__x86_64__) || defined(_M_X64)
inline uint32_t MkwGetHostFpControl() noexcept { return _mm_getcsr(); }
inline void MkwSetHostFpControl(uint32_t value) noexcept { _mm_setcsr(value); }
inline constexpr uint32_t kMkwFlushToZeroBits = (1u << 15) | (1u << 6); // FTZ | DAZ
#elif defined(__aarch64__) || defined(_M_ARM64)
inline uint32_t MkwGetHostFpControl() noexcept
{
    uint64_t fpcr = 0;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
    return static_cast<uint32_t>(fpcr);
}
inline void MkwSetHostFpControl(uint32_t value) noexcept
{
    // FPCR's upper 32 bits are architecturally reserved (RES0) as of ARMv8/ARMv9; every flag this
    // runtime touches (rounding mode, FZ) lives in the low 32, so zero-extending this 32-bit
    // mirror back out to the real 64-bit register on write is safe.
    const uint64_t fpcr = value;
    __asm__ __volatile__("msr fpcr, %0" ::"r"(fpcr));
}
inline constexpr uint32_t kMkwFlushToZeroBits = (1u << 24); // FPCR.FZ
#endif


inline thread_local bool g_mkwHostNiActive = false;

// Same state in the form PpcForceSingleValueInline consumes: the pre-round subnormal threshold
// while NI is active, 0.0 (identity, `|value| < 0.0` is always false) otherwise, so that path
// needs no branch. Every writer of g_mkwHostNiActive must write this beside it in agreement.
inline constexpr double kMkwNiFlushThreshold = 0x1p-126;  // 0x3810000000000000
inline thread_local double g_mkwNiFlushThreshold = 0.0;

inline void MkwApplyHostNiMode(uint32_t fpscr) noexcept
{
    const uint32_t csr = MkwGetHostFpControl();
    const bool wantNi = (fpscr & 0x4u) != 0;
    const uint32_t want = wantNi
        ? (csr | kMkwFlushToZeroBits)
        : (csr & ~kMkwFlushToZeroBits);
    if (want != csr)
        MkwSetHostFpControl(want);
    // `want` has every flush-to-zero bit set or every one clear, so this is exactly
    // `(MkwGetHostFpControl() & kMkwFlushToZeroBits) != 0` after the write - the
    // mirror cannot disagree with the register even if the incoming value held
    // only some of those bits.
    g_mkwHostNiActive = wantNi;
    g_mkwNiFlushThreshold = wantNi ? kMkwNiFlushThreshold : 0.0;
}

/// <summary>
/// Restores a previously captured host FP control value and re-derives the mirror from
/// it. Every raw restore has to go through here; a bare MkwSetHostFpControl would leave
/// the mirror describing the FP environment that was just replaced.
/// </summary>
inline void MkwRestoreHostMxcsr(uint32_t csr) noexcept
{
    MkwSetHostFpControl(csr);
    const bool niActive = (csr & kMkwFlushToZeroBits) != 0;
    g_mkwHostNiActive = niActive;
    g_mkwNiFlushThreshold = niActive ? kMkwNiFlushThreshold : 0.0;
}

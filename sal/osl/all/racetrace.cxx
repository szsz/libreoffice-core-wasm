/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * Diagnostic ring-buffer for the WASM SECOND_INIT thread-lifetime race.
 *
 * The late-join in-place document reload (kit writes checkpoint bytes to
 * /tempdoc, lok_init_2, load) probabilistically traps with
 * "RuntimeError: memory access out of bounds" in a pthread shortly after
 * startMainLoop. The trap site moves with code layout, so a names build
 * can't catch it. Instead, mark the candidate sites with a cheap
 * (tid, site) record into a lock-free ring buffer — no console I/O on the
 * hot path, so timing is barely perturbed — and dump the ring from the JS
 * trap handler. Reading which (tid, site) pair is live across the
 * SECOND_INIT boundary when the OOB fires confirms WHICH of the audited
 * candidates is the real culprit before committing a multi-hour LO build
 * to a gating fix. See ai/tasks/todo/fix-second-init-race.md in the
 * online repo for the full plan.
 *
 * This file is intentionally additive and logic-free: it only records.
 * Callers (vcl, desktop, salhelper, and the online repo's Kit/FakeSocket/
 * wasmapp) declare the two functions with a bare `extern "C"` prototype
 * (the established cross-TU/cross-repo pattern in this tree).
 */

#include <atomic>
#include <cstdint>

#ifdef __EMSCRIPTEN__

#include <emscripten.h>
#include <pthread.h>
#include <cstdio>

namespace
{
struct RaceSlot
{
    std::uint32_t seq;
    std::uint32_t tid;
    std::uint32_t site;
};

// Power-of-two so the modulo is a mask. 512 slots is ample to cover the
// ~4 s window between doc bytes landing and the trap.
constexpr std::uint32_t RACE_N = 512;
RaceSlot g_raceTrace[RACE_N];
std::atomic<std::uint32_t> g_raceIdx{ 0 };
}

extern "C" EMSCRIPTEN_KEEPALIVE void wasm_race_mark(unsigned site)
{
    const std::uint32_t seq = g_raceIdx.fetch_add(1, std::memory_order_relaxed);
    RaceSlot& slot = g_raceTrace[seq & (RACE_N - 1)];
    // Plain stores — the seq written last acts as a torn-write tell-tale
    // (if seq doesn't match the expected index on dump, the slot was
    // mid-write when the trap fired; that's still useful signal).
    slot.tid = static_cast<std::uint32_t>(reinterpret_cast<std::uintptr_t>(pthread_self()));
    slot.site = site;
    slot.seq = seq;
}

extern "C" EMSCRIPTEN_KEEPALIVE void wasm_dump_race_trace()
{
    const std::uint32_t total = g_raceIdx.load(std::memory_order_acquire);
    const std::uint32_t start = total > RACE_N ? total - RACE_N : 0;
    std::fprintf(stderr, "=== WASM RACE TRACE (last %u of %u marks) ===\n",
                 total - start, total);
    for (std::uint32_t s = start; s < total; ++s)
    {
        const RaceSlot& slot = g_raceTrace[s & (RACE_N - 1)];
        std::fprintf(stderr, "  seq=%u tid=0x%08x site=%u\n",
                     slot.seq, slot.tid, slot.site);
    }
    std::fprintf(stderr, "=== END RACE TRACE ===\n");
}

#else // !__EMSCRIPTEN__

// Non-Emscripten builds: keep the symbols so the same source compiles
// everywhere, but make them no-ops (this diagnostic only fires in WASM).
extern "C" void wasm_race_mark(unsigned) {}
extern "C" void wasm_dump_race_trace() {}

#endif

/* vim:set shiftwidth=4 softtabstop=4 expandtab: */

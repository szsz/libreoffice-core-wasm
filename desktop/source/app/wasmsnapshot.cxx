/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * This file is part of the LibreOffice project.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

#include <wasmsnapshot.hxx>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>

#include <com/sun/star/beans/PropertyValue.hpp>
#include <com/sun/star/frame/Desktop.hpp>
#include <com/sun/star/lang/XComponent.hpp>
#include <rtl/ustring.hxx>

#include <emscripten.h>

// Defined here so it lives in libsofficeapp and resolves for both LO Core's
// standalone soffice.js executable and Online's online.js. app.cxx and
// svmain.cxx reference it via extern. true on first visit (Desktop::Main
// returns early to allow snapshot save); reset to false by app.cxx after
// wasmshim::waitForSnapshot() returns; false on snapshot-restore visits
// (cleared by Online's leakSnapshotPolls path before main runs).
bool g_wasmSkipExecute = true;

namespace wasmshim::detail {
    std::mutex g_snapshotMutex;
    std::condition_variable g_snapshotCV;
    bool g_snapshotDone = false;
    // When JS disables snapshot save (killswitch), preloadDocumentModules
    // is pure overhead AND causes UI pollution: each module emits its
    // notebookbar/sidebar JSDialog over the fakesocket as soon as it
    // loads, and dispose() doesn't tell COOL JS to remove those buttons.
    // Result: a Writer doc shows leftover Calc tabs ("Formula") and a
    // duplicate Navigator. Default true (preload runs); JS sets false
    // via wasm_set_preload_disabled before main() if snapshot is killed.
    bool g_preloadDisabled = false;
    // Set by JS (wasm_set_warm_restored) right before callMain on snapshot
    // restore. C++ reads this synchronously instead of doing a
    // MAIN_THREAD_EM_ASM_INT proxy from a worker thread (which deadlocks
    // when the WASM main thread is past its return).
    std::atomic<int> g_warmRestored{ 0 };

    // True while wasmshim::warmupCoreFactories is loading-and-disposing
    // Writer/Calc/Impress factories. Online's kit/ChildSession reads this
    // (via extern "C" wasm_is_ui_emission_suppressed) and drops every
    // outbound frame to JS during the window — so the JSDialog/notebookbar/
    // sidebar payloads emitted while modules instantiate-and-dispose never
    // reach COOL JS, never paint into the DOM, and don't pollute the user's
    // first real-doc UI. After warmup returns the flag is cleared and the
    // user's actual doc-load proceeds normally with all factories warm.
    bool g_suppressUIEmission = false;

    // Phase-2 first-doc-painted handshake. wasmshim::firstDocPainted()
    // signals JS, then blocks on g_phase2CV until JS calls
    // wasm_first_doc_snapshot_resume(). One-shot: g_phase2Triggered
    // ensures only the first transition fires the snapshot.
    std::mutex g_phase2Mutex;
    std::condition_variable g_phase2CV;
    bool g_phase2ResumeRequested = false;
    std::atomic<bool> g_phase2Triggered{false};

    // Plan C — quiesce flag for warm-restore. Set by the kit thread
    // immediately before firstDocPainted; read by the COOLWSD main loop
    // at the top of every iteration. When set, COOLWSD joins its own
    // dependent SocketPolls (PrisonerPoll/AcceptPoll/WebServerPoll) and
    // parks on g_coolwsdResumeCV until the kit thread (cold) or JS
    // (warm) signals resume. Avoids the BLOCKER from review where the
    // kit thread killed PrisonerPoll while COOLWSD was actively poking
    // it on every wakeup. This first commit only plumbs the flag; the
    // actual park/join mechanism lands in a follow-up.
    std::atomic<int> g_quiesce{ 0 };
    std::mutex g_quiesceMutex;
    std::condition_variable g_coolwsdParkedCV;
    std::condition_variable g_coolwsdResumeCV;
    std::atomic<bool> g_coolwsdParked{false};
    std::atomic<bool> g_coolwsdResume{false};
}

namespace wasmshim {

void waitForSnapshot()
{
    using namespace std::chrono;
    std::unique_lock<std::mutex> lk(detail::g_snapshotMutex);
    // 60s timeout: converts a JS-side hang (closed tab, save error,
    // dispatch lost) from an unrecoverable C++ block into a slow
    // fallback. Better to enter Execute() without a snapshot saved
    // than to leave the user with a frozen page.
    bool ok = detail::g_snapshotCV.wait_for(
        lk, seconds(60),
        []{ return detail::g_snapshotDone; });
    if (!ok)
    {
        MAIN_THREAD_ASYNC_EM_ASM({
            console.warn('wasmshim::waitForSnapshot timed out — proceeding without snapshot save');
        });
        detail::g_snapshotDone = true;  // unstick any subsequent waiter
    }
}

void preloadDocumentModules(
    css::uno::Reference<css::uno::XComponentContext> const& xContext)
{
    if (detail::g_preloadDisabled)
    {
        MAIN_THREAD_ASYNC_EM_ASM({
            console.log('wasmshim:preload_skipped (disabled by JS)');
        });
        return;
    }
    auto xLoader = css::frame::Desktop::create(xContext);
    css::uno::Sequence<css::beans::PropertyValue> empty(0);
    const OUString factories[] = {
        u"private:factory/swriter"_ustr,
        u"private:factory/scalc"_ustr,
        u"private:factory/simpress"_ustr,
    };
    for (const auto& factory : factories)
    {
        auto xComp = xLoader->loadComponentFromURL(factory, u"_blank"_ustr, 0, empty);
        if (xComp.is())
            xComp->dispose();
    }
}

void warmupCoreFactories(
    css::uno::Reference<css::uno::XComponentContext> const& xContext)
{
    // NOTE: not gated by g_preloadDisabled. That flag was a snapshot-era
    // killswitch for the OLD preloadDocumentModules path that polluted the
    // UI. With g_suppressUIEmission below the warmup is silent, so it's
    // safe to run independently of whether a snapshot will be saved.
    using namespace std::chrono;
    auto t_start = steady_clock::now();

    MAIN_THREAD_ASYNC_EM_ASM({
        console.log('wasmshim:warmup_start (UI emission suppressed)');
    });

    // Inline the load-dispose loop here (don't call preloadDocumentModules
    // which is gated by g_preloadDisabled). With suppression on, running
    // unconditionally is the right behavior for Phase-1.4.
    detail::g_suppressUIEmission = true;
    try {
        auto xLoader = css::frame::Desktop::create(xContext);
        css::uno::Sequence<css::beans::PropertyValue> empty(0);
        const OUString factories[] = {
            u"private:factory/swriter"_ustr,
            u"private:factory/scalc"_ustr,
            u"private:factory/simpress"_ustr,
        };
        for (const auto& factory : factories)
        {
            auto xComp = xLoader->loadComponentFromURL(factory, u"_blank"_ustr, 0, empty);
            if (xComp.is())
                xComp->dispose();
        }
    }
    catch (const css::uno::Exception&)
    {
        MAIN_THREAD_ASYNC_EM_ASM({
            console.warn('wasmshim:warmup_threw (uno::Exception)');
        });
    }
    catch (...)
    {
        MAIN_THREAD_ASYNC_EM_ASM({
            console.warn('wasmshim:warmup_threw (unknown)');
        });
    }
    detail::g_suppressUIEmission = false;

    auto ms = duration_cast<milliseconds>(steady_clock::now() - t_start).count();
    MAIN_THREAD_ASYNC_EM_ASM({
        console.log('wasmshim:warmup_end ' + $0 + 'ms');
    }, static_cast<int>(ms));
}

bool isQuiesce()
{
    return detail::g_quiesce.load(std::memory_order_acquire) != 0;
}

void firstDocPainted(std::string_view docTypeHint)
{
    using namespace std::chrono;

    // One-shot. Atomic CAS ensures only the very first invocation
    // triggers the snapshot save; later doc opens (cross-module switch
    // on warm restore, second user file, etc.) are no-ops.
    bool expected = false;
    if (!detail::g_phase2Triggered.compare_exchange_strong(expected, true))
        return;

    // Snapshot the docType into a heap string the EM_ASM payload can
    // reference safely (it crosses to the JS main thread async).
    static std::string s_docType;
    s_docType.assign(docTypeHint.data(), docTypeHint.size());

    MAIN_THREAD_ASYNC_EM_ASM({
        if (Module && typeof Module.__firstDocLoaded === 'function') {
            try { Module.__firstDocLoaded(UTF8ToString($0)); }
            catch (e) { console.error('Module.__firstDocLoaded threw:', e); }
        } else {
            console.warn('wasmshim::firstDocPainted: no JS handler installed');
        }
    }, s_docType.c_str());

    // Block this thread until JS captures HEAPU8 and calls resume.
    // 120s ceiling: longer than the conservative Cache.put estimate so
    // even slow disks don't timeout, but short enough to recover from a
    // hung JS handler (closed tab, exception during capture).
    std::unique_lock<std::mutex> lk(detail::g_phase2Mutex);
    bool ok = detail::g_phase2CV.wait_for(
        lk, seconds(120),
        []{ return detail::g_phase2ResumeRequested; });
    if (!ok)
    {
        MAIN_THREAD_ASYNC_EM_ASM({
            console.warn('wasmshim::firstDocPainted: resume timeout, proceeding');
        });
    }
}

} // namespace wasmshim

extern "C" EMSCRIPTEN_KEEPALIVE void wasm_snapshot_complete()
{
    {
        std::lock_guard<std::mutex> lk(wasmshim::detail::g_snapshotMutex);
        wasmshim::detail::g_snapshotDone = true;
    }
    wasmshim::detail::g_snapshotCV.notify_all();
}

extern "C" EMSCRIPTEN_KEEPALIVE void wasm_set_preload_disabled(int disabled)
{
    wasmshim::detail::g_preloadDisabled = (disabled != 0);
}

/// Called from the deploy.sh-injected restore block on warm-snapshot
/// visits, after HEAPU8.set but before callMain. Lets C++ Desktop::Main
/// (running on the lokit_main worker thread later) read the warm-restore
/// state synchronously without a MAIN_THREAD_EM_ASM_INT proxy that would
/// deadlock against the long-returned WASM main thread.
extern "C" EMSCRIPTEN_KEEPALIVE void wasm_set_warm_restored(int restored)
{
    wasmshim::detail::g_warmRestored.store(restored != 0 ? 1 : 0,
                                            std::memory_order_release);
}

extern "C" EMSCRIPTEN_KEEPALIVE int wasm_is_warm_restored()
{
    return wasmshim::detail::g_warmRestored.load(std::memory_order_acquire);
}

/// Plan C — kit thread sets this before firstDocPainted to ask COOLWSD
/// to park itself; restore-side JS clears it before callMain.
extern "C" EMSCRIPTEN_KEEPALIVE void wasm_set_quiesce(int q)
{
    wasmshim::detail::g_quiesce.store(q ? 1 : 0, std::memory_order_release);
}

extern "C" EMSCRIPTEN_KEEPALIVE int wasm_is_quiesce()
{
    return wasmshim::detail::g_quiesce.load(std::memory_order_acquire);
}

/// COOLWSD thread calls this once it has joined its dependent polls and
/// is about to park. Wakes the kit thread which is waiting in
/// wasm_wait_coolwsd_parked.
extern "C" EMSCRIPTEN_KEEPALIVE void wasm_coolwsd_parked()
{
    {
        std::lock_guard<std::mutex> lk(wasmshim::detail::g_quiesceMutex);
        wasmshim::detail::g_coolwsdParked.store(true, std::memory_order_release);
    }
    wasmshim::detail::g_coolwsdParkedCV.notify_all();
}

/// Kit thread waits here for COOLWSD to ack-park before triggering the
/// snapshot. 5 second timeout so we never deadlock the cold-visit
/// session if the COOLWSD thread is unhealthy.
extern "C" EMSCRIPTEN_KEEPALIVE void wasm_wait_coolwsd_parked()
{
    using namespace std::chrono;
    std::unique_lock<std::mutex> lk(wasmshim::detail::g_quiesceMutex);
    wasmshim::detail::g_coolwsdParkedCV.wait_for(
        lk, seconds(5),
        []{ return wasmshim::detail::g_coolwsdParked.load(std::memory_order_acquire); });
}

/// Signals COOLWSD to leave its parked state and re-spawn its polls.
/// Called from kit thread after firstDocPainted returns (cold visit) or
/// from JS deploy.sh restore block (warm visit).
extern "C" EMSCRIPTEN_KEEPALIVE void wasm_coolwsd_resume()
{
    {
        std::lock_guard<std::mutex> lk(wasmshim::detail::g_quiesceMutex);
        wasmshim::detail::g_coolwsdResume.store(true, std::memory_order_release);
    }
    wasmshim::detail::g_coolwsdResumeCV.notify_all();
}

/// Online's kit/ChildSession reads this to drop UI-state messages while
/// wasmshim::warmupCoreFactories is loading-and-disposing module factories.
/// Returns 1 while suppression is active, 0 otherwise.
extern "C" EMSCRIPTEN_KEEPALIVE int wasm_is_ui_emission_suppressed()
{
    return wasmshim::detail::g_suppressUIEmission ? 1 : 0;
}

/// JS calls this after capturing HEAPU8 in response to Module.__firstDocLoaded.
/// Wakes the wasmshim::firstDocPainted() blocked thread.
extern "C" EMSCRIPTEN_KEEPALIVE void wasm_first_doc_snapshot_resume()
{
    {
        std::lock_guard<std::mutex> lk(wasmshim::detail::g_phase2Mutex);
        wasmshim::detail::g_phase2ResumeRequested = true;
    }
    wasmshim::detail::g_phase2CV.notify_all();
}

/// JS reports a snapshot-save failure. Records the reason in a static for
/// any future telemetry hook to retrieve, then unblocks the C++ side so
/// the user's session continues. Reasons (JS-side enum):
///   1 = JS exception during capture
///   2 = HEAPU8 unavailable
///   3 = Cache.put failed
///   4 = JS-side timeout (e.g. tab backgrounded)
extern "C" EMSCRIPTEN_KEEPALIVE void wasm_snapshot_failed(int reason)
{
    static std::atomic<int> s_lastReason{0};
    s_lastReason.store(reason);
    MAIN_THREAD_ASYNC_EM_ASM({
        console.warn('wasm_snapshot_failed: reason=' + $0);
    }, reason);
    // Unblock firstDocPainted's wait if it was the trigger.
    wasm_first_doc_snapshot_resume();
}

/* vim:set shiftwidth=4 softtabstop=4 expandtab: */

/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * This file is part of the LibreOffice project.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

#include <wasmsnapshot.hxx>

#include <condition_variable>
#include <mutex>

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

} // namespace wasmshim

extern "C" EMSCRIPTEN_KEEPALIVE void wasm_snapshot_complete()
{
    {
        std::lock_guard<std::mutex> lk(wasmshim::detail::g_snapshotMutex);
        wasmshim::detail::g_snapshotDone = true;
    }
    wasmshim::detail::g_snapshotCV.notify_all();
}

/* vim:set shiftwidth=4 softtabstop=4 expandtab: */

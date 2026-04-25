/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * This file is part of the LibreOffice project.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

#pragma once

#include <com/sun/star/uno/Reference.hxx>
#include <com/sun/star/uno/XComponentContext.hpp>

#include <string_view>

namespace wasmshim {

/// Block until JS has saved the heap snapshot. JS resumes us by calling the
/// extern "C" wasm_snapshot_complete() entry point exposed from wasmsnapshot.cxx.
///
/// DEPRECATED: this is the Phase-1 trigger fired from Desktop::Main BEFORE
/// any user document loads. The Phase-2 trigger is firstDocPainted() below.
void waitForSnapshot();

/// Open + dispose blank Writer/Calc/Impress to warm those modules into the
/// snapshot. Saves ~18s of lazy loadComponentFromURL on first doc open after
/// snapshot restore.
///
/// DEPRECATED: caused JSDialog notebookbar/sidebar pollution because dispose()
/// doesn't tell COOL JS to remove already-emitted UI frames. Phase-2 saves
/// the snapshot AFTER a real user doc has loaded, so module-warming becomes
/// unnecessary. Gated by g_preloadDisabled (set by JS via
/// wasm_set_preload_disabled).
void preloadDocumentModules(
    css::uno::Reference<css::uno::XComponentContext> const& xContext);

/// Phase-2 snapshot trigger. Online's ChildSession calls this exactly once,
/// the first time a real user document finishes loading on this LOK runtime
/// instance. Effects:
///   1. Signal JS via MAIN_THREAD_ASYNC_EM_ASM (Module.__firstDocLoaded).
///   2. Block this thread on a condition_variable until JS has captured
///      HEAPU8 and called wasm_first_doc_snapshot_resume().
///   3. Resume.
///
/// Subsequent calls are no-ops (one-shot guarded by atomic).
///
/// docTypeHint: "text" | "spreadsheet" | "presentation" — informs JS of
/// the first-loaded doc's type so cross-module switchdoc on warm restore
/// can be planned. Free-form string; JS treats unknown values as "text".
void firstDocPainted(std::string_view docTypeHint);

} // namespace wasmshim

/* vim:set shiftwidth=4 softtabstop=4 expandtab: */

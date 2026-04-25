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

namespace wasmshim {

/// Block until JS has saved the heap snapshot. JS resumes us by calling the
/// extern "C" wasm_snapshot_complete() entry point exposed from wasmsnapshot.cxx.
void waitForSnapshot();

/// Open + dispose blank Writer/Calc/Impress to warm those modules into the
/// snapshot. Saves ~18s of lazy loadComponentFromURL on first doc open after
/// snapshot restore.
void preloadDocumentModules(
    css::uno::Reference<css::uno::XComponentContext> const& xContext);

} // namespace wasmshim

/* vim:set shiftwidth=4 softtabstop=4 expandtab: */

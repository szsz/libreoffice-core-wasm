/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * This file is part of the LibreOffice project.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

#pragma once

#include <comphelper/lok.hxx>

namespace wasmshim {

/// True when LOK is rendering UI as HTML via jsdialog instead of VCL widgets.
/// Use this predicate to skip widget-construction paths that crash in WASM/Qt5
/// (font combo OOB, ToolbarUnoDispatcher Qt5 crash, SwTableAutoFormat copy-ctor
/// OOB). When the underlying upstream bugs are root-caused, delete the call
/// site rather than this predicate.
inline bool isJsDialogMode()
{
#ifdef __EMSCRIPTEN__
    return comphelper::LibreOfficeKit::isActive();
#else
    return false;
#endif
}

} // namespace wasmshim

/* vim:set shiftwidth=4 softtabstop=4 expandtab: */

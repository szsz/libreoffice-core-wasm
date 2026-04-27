/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * This file is part of the LibreOffice project.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * This file incorporates work covered by the following license notice:
 *
 *   Licensed to the Apache Software Foundation (ASF) under one or more
 *   contributor license agreements. See the NOTICE file distributed
 *   with this work for additional information regarding copyright
 *   ownership. The ASF licenses this file to you under the Apache
 *   License, Version 2.0 (the "License"); you may not use this file
 *   except in compliance with the License. You may obtain a copy of
 *   the License at http://www.apache.org/licenses/LICENSE-2.0 .
 */

#include <sal/config.h>

#include <comphelper/solarmutex.hxx>

#include <assert.h>
#include <cstdlib>
#include <new>

namespace comphelper {

namespace {
    SolarMutex* g_pSolarMutex = nullptr;
}

SolarMutex *SolarMutex::get()
{
    return g_pSolarMutex;
}

SolarMutex::SolarMutex()
    : m_nCount( 0 )
    , m_aBeforeReleaseHandler( nullptr )
{
    assert(!g_pSolarMutex);
    g_pSolarMutex = this;
}

SolarMutex::~SolarMutex()
{
    g_pSolarMutex = nullptr;
}

void SolarMutex::doAcquire( const sal_uInt32 nLockCount )
{
    for ( sal_uInt32 n = nLockCount; n ; --n )
        m_aMutex.acquire();
    m_nThreadId = std::this_thread::get_id();
    m_nCount += nLockCount;
}

#ifdef __EMSCRIPTEN__
extern "C" int wasm_is_warm_restored();
#endif

sal_uInt32 SolarMutex::doRelease( bool bUnlockAll )
{
#ifdef __EMSCRIPTEN__
    // Plan C warm-restore: the snapshot captured the SolarMutex held by
    // a cold-visit thread that no longer exists. The first VCL main-loop
    // iteration after restore calls doRelease() and would abort here.
    // Only short-circuit on warm — never on cold, so genuine bugs still
    // surface. Adopt thread ownership and skip the OS-mutex release
    // (the underlying m_aMutex was placement-new'd unlocked by
    // wasmWarmRestoreReset, so calling release() would underflow).
    if ( wasm_is_warm_restored() == 1 && (!IsCurrentThread() || m_nCount == 0) )
    {
        m_nThreadId = std::this_thread::get_id();
        return 0;
    }
#endif
    if ( !IsCurrentThread() )
        std::abort();
    if ( m_nCount == 0 )
        std::abort();

    const sal_uInt32 nCount = bUnlockAll ? m_nCount : 1;
    m_nCount -= nCount;

    if ( 0 == m_nCount )
    {
        if ( m_aBeforeReleaseHandler )
            m_aBeforeReleaseHandler();
        m_nThreadId = std::thread::id();
    }

    for ( sal_uInt32 n = nCount ; n ; --n )
        m_aMutex.release();

    return nCount;
}

bool SolarMutex::IsCurrentThread() const
{
    return m_nThreadId == std::this_thread::get_id();
}

bool SolarMutex::tryToAcquire()
{
    if ( m_aMutex.tryToAcquire() )
    {
        m_nThreadId = std::this_thread::get_id();
        m_nCount++;
        return true;
    }
    else
        return false;
}

#ifdef __EMSCRIPTEN__
// Plan C warm-restore — the SolarMutex captured in the snapshot has
// m_nThreadId pointing at a thread from the cold visit and m_nCount > 0.
// On warm visit a fresh thread tries to release it, fails the
// IsCurrentThread() check in doRelease(), and aborts. Forcefully clear
// the captured ownership state and reinit the underlying osl::Mutex via
// placement-new so the new threads see a clean unlocked mutex.
void SolarMutex::wasmWarmRestoreReset()
{
    m_nCount = 0;
    m_nThreadId.store(std::thread::id());
    new (&m_aMutex) osl::Mutex();
}
#endif

} // namespace comphelper

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
extern "C" EMSCRIPTEN_KEEPALIVE void wasm_warm_restore_solar_mutex_reset()
{
    auto* p = comphelper::SolarMutex::get();
    if (p) p->wasmWarmRestoreReset();
}
#endif

/* vim:set shiftwidth=4 softtabstop=4 expandtab: */

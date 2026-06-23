# -*- Mode: makefile-gmake; tab-width: 4; indent-tabs-mode: t -*-
#
# This file is part of the LibreOffice project.
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

include $(GBUILDDIR)/platform/unxgcc.mk

gb_RUN_CONFIGURE := $(SRCDIR)/solenv/bin/run-configure
# avoid -s SAFE_HEAP=1 - c.f. gh#8584 this breaks source maps
gb_EMSCRIPTEN_CPPFLAGS := -pthread -s USE_PTHREADS=1 -D_LARGEFILE64_SOURCE -D_LARGEFILE_SOURCE -s SUPPORT_LONGJMP=wasm
gb_EMSCRIPTEN_LDFLAGS := $(gb_EMSCRIPTEN_CPPFLAGS)

# Memory sizing.
#
# Initial size: 1 GiB. Most documents (sheet, doc, even simple presentations)
# fit comfortably under 600 MiB so the cold-start commitment stays modest.
#
# Hard cap: removed via -sALLOW_MEMORY_GROWTH=1. The previous fixed-cap
# build aborted with `Aborted(Cannot enlarge memory arrays to size
# 1236799488 bytes (OOM). Either (1) compile with -sINITIAL_MEMORY=X with
# X higher than the current value 1073741824, (2) compile with
# -sALLOW_MEMORY_GROWTH ...)` whenever the user opened the shape Area
# dialog in Writer / Impress. The Area dialog ctor + tab-page lazy load
# of XBitmapList / XGradientList / XPatternList preview bitmaps can push
# allocation past 1 GiB on top of an already-loaded doc (~80 MiB
# `Pictures/*` preset zip decoded into a stack of ~40 BitmapEx tiles of
# `m_aIconSize(60, 64)` plus the source GraphicObjects retained by the
# XBitmapEntry list). Growing on demand lets the dialog open; the
# initial 1 GiB keeps cold start identical to before for the 95% of
# sessions that never hit the cap. The remaining cost - every grow
# rehosts HEAP arrays at the wasm boundary and JS heap views must be
# refreshed - is paid only by sessions that exceed 1 GiB.
#
# User-approved 2026-06-02: prefer ALLOW_MEMORY_GROWTH over
# TOTAL_MEMORY=2GB to avoid charging tab memory + swap pressure on
# low-end devices.
#
# 2026-06-06: ALLOW_MEMORY_GROWTH=1 is a silent no-op under
# USE_PTHREADS without an explicit MAXIMUM_MEMORY. Emscripten emits
# the SharedArrayBuffer with maximum=initial, so the heap can't
# actually grow. Diagnostic confirmed via wasm import-section parse
# (env.memory{initial=maximum=16384 pages, shared}) and the runtime
# probe at ai/proposals/proposed/shape-area-unaligned-access-after-
# growth.md: Module.HEAPU8.byteLength stays at exactly 1 GiB and
# the Area dialog still trips the WASM bounds check on the next
# pixel write. Setting MAXIMUM_MEMORY=2GB makes growth actually
# engage.
gb_EMSCRIPTEN_LDFLAGS += -s TOTAL_MEMORY=1GB -s ALLOW_MEMORY_GROWTH=1 -s MAXIMUM_MEMORY=2GB

ifeq ($(ENABLE_EMSCRIPTEN_PROXY_TO_PTHREAD),)
gb_EMSCRIPTEN_LDFLAGS += -sPTHREAD_POOL_SIZE=7
endif

# Stack sizes — sized for spellcheck. Once dictionaries register and
# SpellOnline kicks in, Writer's autospell runs hunspell's word-check +
# suggestion routines, which recurse deeply (ngram / compound-word paths).
# That autospell work runs as IDLE processing on the *main* thread
# (DocumentTimerManager::DoIdleJobs → SwTextFrame::AutoSpell_). Under
# -sPROXY_TO_PTHREAD (enabled by default, configure.ac) the app's main()
# runs on the proxied-main pthread — and EMPIRICALLY (builds -87/-88) that
# thread's stack is governed by DEFAULT_PTHREAD_STACK_SIZE, NOT STACK_SIZE:
#  - build -87 (DEFAULT 1 MiB)  → overflow at cookie addr ~0x03d8cfe0.
#  - build -88 (STACK_SIZE 128K→4M, DEFAULT still 1 MiB) → SAME cookie addr,
#    SAME overflow. Bumping STACK_SIZE did not move the proxied-main stack;
#    bumping DEFAULT_PTHREAD_STACK_SIZE is what matters. 1 MiB still wasn't
#    enough for hunspell suggestion recursion in WASM (larger frames than
#    native). The overflow is caught by checkStackCookie at the
#    Browser_mainLoop_runner boundary. This is the same overflow that forced
#    the revert of the -51 dict-scan-precedence commit (64bb48e598bb).
# Give both knobs desktop-parity 8 MiB (native LO main stack is 8 MiB, which
# hunspell fits comfortably). Cost: 8 MiB per live pthread; with
# PROXY_TO_PTHREAD there is no pre-allocated pool (PTHREAD_POOL_SIZE unset),
# threads are created on demand, so total reserved stack stays modest vs the
# 1–2 GiB heap.
gb_EMSCRIPTEN_LDFLAGS += -sSTACK_SIZE=8388608 -sDEFAULT_PTHREAD_STACK_SIZE=8388608

# DIAGNOSTIC (spellcheck overflow, build #4) — REVERT before shipping.
# STACK_OVERFLOW_CHECK=2 aborts AT the overflowing call (not at the next
# main-loop boundary) and prints the actual stack pointer vs limit, so we
# learn the real stack size AND whether it's deep/infinite recursion.
# --profiling-funcs keeps wasm function names so the trace is readable.
gb_EMSCRIPTEN_LDFLAGS += -sSTACK_OVERFLOW_CHECK=2 --profiling-funcs

# To keep the link time (and memory) down, prevent all rewriting options from wasm-emscripten-finalize
# See emscripten.py, finalize_wasm, modify_wasm = True
# So we need WASM_BIGINT=1 and ASSERTIONS=1 (2 implies STACK_OVERFLOW_CHECK)
gb_EMSCRIPTEN_LDFLAGS += --bind -s FORCE_FILESYSTEM=1 -s WASM_BIGINT=1 -s ERROR_ON_UNDEFINED_SYMBOLS=1 -s FETCH=1 -s ASSERTIONS=1 -s EXIT_RUNTIME=0 -s EXPORTED_RUNTIME_METHODS=["UTF16ToString","stringToUTF16","UTF8ToString","ccall","cwrap","addOnPreMain","addOnPostRun","registerType","throwBindingError","ClassHandle","HEAPU16","HEAPU32"$(if $(ENABLE_QT6),$(COMMA)"FS"$(COMMA)"callMain"$(COMMA)"specialHTMLTargets")]
gb_EMSCRIPTEN_QTDEFS := -DQT_NO_LINKED_LIST -DQT_NO_JAVA_STYLE_ITERATORS -DQT_NO_EXCEPTIONS -DQT_NO_DEBUG -DQT_WIDGETS_LIB -DQT_GUI_LIB -DQT_CORE_LIB

ifeq ($(ENABLE_EMSCRIPTEN_JSPI),TRUE)
gb_EMSCRIPTEN_LDFLAGS += \
    -sJSPI \
    -sJSPI_EXPORTS=_emscripten_check_mailbox,_ZN10emscripten8internal13MethodInvokerINS0_3rvp11default_tagEMN7qstdweb13EventListenerEFvNS_3valEEvPS5_JS6_EE6invokeERKS8_S9_PNS_7_EM_VALE
endif

ifeq ($(ENABLE_EMSCRIPTEN_PROXY_POSIX_SOCKETS),TRUE)
gb_EMSCRIPTEN_LDFLAGS += -sPROXY_POSIX_SOCKETS -lwebsocket.js
endif

gb_Executable_EXT := .js
gb_EMSCRIPTEN_EXCEPT = -fwasm-exceptions -s SUPPORT_LONGJMP=wasm

gb_CXXFLAGS += $(gb_EMSCRIPTEN_CPPFLAGS)

# Here we don't use += because gb_LinkTarget_EXCEPTIONFLAGS from com_GCC_defs.mk contains -fexceptions and
# gb_EMSCRIPTEN_EXCEPT already has -fwasm-exceptions
gb_LinkTarget_EXCEPTIONFLAGS = $(gb_EMSCRIPTEN_EXCEPT)

gb_LinkTarget_CFLAGS += $(gb_EMSCRIPTEN_CPPFLAGS)
gb_LinkTarget_CXXFLAGS += $(gb_EMSCRIPTEN_CPPFLAGS) $(gb_EMSCRIPTEN_EXCEPT)
ifeq ($(ENABLE_QT5),TRUE)
gb_LinkTarget_CFLAGS += $(gb_EMSCRIPTEN_QTDEFS)
gb_LinkTarget_CXXFLAGS += $(gb_EMSCRIPTEN_QTDEFS)
endif
gb_LinkTarget_LDFLAGS += $(gb_EMSCRIPTEN_LDFLAGS) $(gb_EMSCRIPTEN_CPPFLAGS) \
    $(gb_EMSCRIPTEN_EXCEPT) -sEXPORT_EXCEPTION_HANDLING_HELPERS

# Depending on emsdk version being used, might enable standard library features that would otherwise
# be hidden:
gb_LinkTarget_CXXFLAGS += -fexperimental-library

ifeq ($(ENABLE_OPTIMIZED),TRUE)
ifneq ($(ENABLE_SYMBOLS_FOR),)
gb_LinkTarget__emscripten_warnings_ldflags := -Wno-limited-postlink-optimizations
endif
endif

# Linker and compiler optimize + debug flags are handled in LinkTarget.mk
gb_LINKEROPTFLAGS :=
gb_LINKERSTRIPDEBUGFLAGS :=
# This maps to g3, no source maps, but DWARF with current emscripten!
# https://developer.chrome.com/blog/wasm-debugging-2020/
gb_DEBUGINFO_FLAGS = -g

ifeq ($(HAVE_EXTERNAL_DWARF),TRUE)
gb_DEBUGINFO_FLAGS += -gseparate-dwarf -gsplit-dwarf -gpubnames
endif

gb_COMPILEROPTFLAGS := -O3

# We need at least code elimination, otherwise linking OOMs even with 64GB.
# So we "fake" -Og support to mean -O1 for Emscripten and always enable it for debug in configure.
gb_COMPILERDEBUGOPTFLAGS := -O1
gb_COMPILERNOOPTFLAGS := -O1 -fstrict-aliasing -fstrict-overflow

# cleanup addition JS and wasm files for binaries
define gb_Executable_Executable_platform
$(call gb_LinkTarget_add_auxtargets,$(2),\
        $(patsubst %.lib,%.linkdeps,$(3)) \
        $(patsubst %.lib,%.wasm,$(3)) \
        $(if $(EMSCRIPTEN_WORKERJS),$(patsubst %.lib,%.worker.js,$(3))) \
        $(patsubst %.lib,%.wasm.debug.wasm,$(3)) \
        $(patsubst %.lib,%.wasm.debug.wasm.dwp,$(3)) \
)

endef

define gb_CppunitTest_CppunitTest_platform
$(call gb_LinkTarget_add_auxtargets,$(2),\
        $(patsubst %.lib,%.linkdeps,$(3)) \
        $(patsubst %.lib,%.wasm,$(3)) \
        $(if $(EMSCRIPTEN_WORKERJS),$(patsubst %.lib,%.worker.js,$(3))) \
        $(patsubst %.lib,%.wasm.debug.wasm,$(3)) \
        $(patsubst %.lib,%.wasm.debug.wasm.dwp,$(3)) \
)

endef

define gb_Library_get_rpath
endef

define gb_Executable_get_rpath
endef

# vim: set noet sw=4 ts=4

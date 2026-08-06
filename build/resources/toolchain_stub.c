/*
 * Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
 * All rights reserved.
 * This file is a part of the Tebako project.
 *
 * Toolchain-link stub for the tebako runtime entry driver.
 *
 * The pre-patched ruby source (tfs-ruby-<version>-src) has the tebako
 * entry hook in main.c from the start, so the *toolchain* ruby built
 * during 'make install' references the driver symbols (tebako_main & co.)
 * and, in pass2 of the gem flow, the io shims reference the legacy libtfs
 * API. The real driver library (libtebako-fs.a, the modern tebako_fs_*
 * driver + the embedded filesystem image) can only be built after the
 * toolchain environment exists -- the image is made out of it.
 *
 * This stub breaks the cycle: it provides the driver entry symbols as
 * pass-throughs, so the toolchain ruby links and behaves like a plain
 * interpreter (tebako_main() returns success without mounting anything).
 * It is archived as libtebako-fs.a into the deps lib dir, which the ruby
 * link flags search before the CMake binary dir; build_pass.rb 'toolchain'
 * removes it after the toolchain build, so the final relink of the ruby
 * program picks up the real libtebako-fs.a.
 */

/* The stub's definitions are WEAK: in the shared build (issue #40) the
 * real driver TU rides the ruby DLL and exports the same entry points;
 * weak lets the DLL's strong definitions win silently, while the static
 * build (stub-only) links the weak copies unchanged. A whole-archive
 * pull of this stub in the MAINLIBS shape must never produce a
 * multiple-definition failure against the DLL's import archive.
 */

#ifndef TEBAKO_STUB_MOUNT_POINT
#error "TEBAKO_STUB_MOUNT_POINT must be defined (the memfs mount point)"
#endif

#include <sys/types.h>

/* The v2 (Rust driver) link builds the exe against the ruby DLL's import
   library and miniruby against the driver archive directly (the driver's
   own tebako_main carries the miniruby argv0 pass-through): every other
   stub symbol would duplicate a definition that side already has (the ld
   multiple-definition failures on the 3.3.12/4.0.6 legs -- first the
   compat getters, then tebako_mount_point). TEBAKO_STUB_MINIMAL (v2 only)
   reduces the stub to the one symbol the toolchain exe needs from it:
   tebako_main, the plain-interpreter pass-through. The v1 link keeps the
   full stub: no import library and no driver archive exists there. */
#ifdef TEBAKO_STUB_MINIMAL
int tebako_main(int *argc, char ***argv)
{
    (void)argc;
    (void)argv;
    return 0;
}
#else
int tebako_main(int *argc, char ***argv)
{
    (void)argc;
    (void)argv;
    return 0;
}

__attribute__((weak)) const char *tebako_mount_point(void)
{
    return TEBAKO_STUB_MOUNT_POINT;
}

__attribute__((weak)) int tebako_is_running_miniruby(void)
{
    return 0;
}

__attribute__((weak)) const char *tebako_original_pwd(void)
{
    return "";
}
#endif

/* Referenced by the ruby < 3.3 msys builds (the real driver provides it
   under RB_W32_PRE_33); ruby >= 3.3 defines it in win32.c, so it is
   compiled in only for the older lines */
#ifdef RB_W32_PRE_33
ssize_t rb_w32_pread(int fd, void *buf, size_t size, size_t offset)
{
    (void)fd;
    (void)buf;
    (void)size;
    (void)offset;
    return -1;
}
#endif

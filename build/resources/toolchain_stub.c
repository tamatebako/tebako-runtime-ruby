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

#ifndef TEBAKO_STUB_MOUNT_POINT
#error "TEBAKO_STUB_MOUNT_POINT must be defined (the memfs mount point)"
#endif

#include <sys/types.h>

int tebako_main(int *argc, char ***argv)
{
    (void)argc;
    (void)argv;
    return 0;
}

const char *tebako_mount_point(void)
{
    return TEBAKO_STUB_MOUNT_POINT;
}

/* The v2 (Rust driver) link builds the exe against the ruby DLL's import
   library, which exports the driver's own tebako_original_pwd and
   tebako_is_running_miniruby: a stub that also defines them collides in
   the toolchain link (the ld multiple-definition failure on the
   3.3.12/4.0.6 legs). TEBAKO_STUB_MINIMAL (build_pass.rb, v2 only) drops
   the two getters -- the exe binds them from the import library, miniruby
   from the driver archive (TEBAKO_MINILIBS). The v1 link keeps the full
   stub: no import library exists there. */
#ifndef TEBAKO_STUB_MINIMAL
int tebako_is_running_miniruby(void)
{
    return 0;
}

const char *tebako_original_pwd(void)
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

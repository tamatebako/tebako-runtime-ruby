/* native_open_ext.c — an UNPATCHED ruby C extension whose native code
 * opens a VFS path through plain libc IO (open/read), never through
 * ruby's tebako-patched File API. This is the tebako#1125 shape: a
 * third-party native extension — leptris' libxml2 fopen()ing its
 * in-image RelaxNG schema (metanorma-standoc#1416) — whose libc calls
 * the interpreter's own patches never touch. The ONLY thing that can
 * serve such a call is the spec-22 preload shim's interposed open();
 * when the shim never loaded — a hardened-runtime macOS exe signed
 * without com.apple.security.cs.allow-dyld-environment-variables strips
 * DYLD_INSERT_LIBRARIES at the driver's re-exec, the
 * tebako-runtime-r#5 class — the raw open() of the mount root dies
 * ENOENT on the host filesystem while every ruby-level check stays
 * green (the published 0.17.15 darwin-23 incident).
 *
 * The extension itself LOADS shimless (the driver materializes the
 * .bundle for dln_load — loader interposition, proven by probe_ext's
 * self-dlopen leg); what fails without the shim is the file IO inside
 * the call. That split is the probe's whole point.
 *
 * NOT part of the tamatebako/ruby ci/spec22 mirror set: the dln-interpose
 * fixtures (vfsdep/vfsprobe/probe_ext) live there; this file is the ruby
 * factory's own IO-surface probe. The API surface it uses (rb_define_*,
 * StringValueCStr, rb_str_new, rb_sys_fail) is stable across every ruby
 * line the factory ships, so the acceptance legs compile it against
 * whatever ruby headers the runner provides. */

#include <ruby.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

/* NativeOpenExt.read_file(path) -> String
 *
 * open(2) + read(2) only — no stdio, no ruby IO objects, so the call
 * rides exactly the interpose surface the shim covers. A failed syscall
 * raises the kernel's own Errno (rb_sys_fail), so the in-runtime probe
 * names the stripping verdict (ENOENT on a shimless boot) instead of a
 * generic load error. */
static VALUE
native_open_read_file(VALUE self, VALUE path)
{
    char buffer[16384];
    ssize_t total = 0;
    ssize_t n = 0;
    int fd;
    const char *cpath = StringValueCStr(path);

    fd = open(cpath, O_RDONLY);
    if (fd < 0)
        rb_sys_fail(cpath);
    while (total < (ssize_t)sizeof(buffer) &&
           (n = read(fd, buffer + total, sizeof(buffer) - (size_t)total)) > 0)
        total += n;
    if (n < 0) {
        int saved_errno = errno;
        close(fd);
        errno = saved_errno;
        rb_sys_fail(cpath);
    }
    close(fd);
    return rb_str_new(buffer, total);
}

void
Init_native_open_ext(void)
{
    VALUE mod = rb_define_module("NativeOpenExt");

    rb_define_singleton_method(mod, "read_file", native_open_read_file, 1);
}

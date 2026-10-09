/*
 * The magnus boot-smoke fixture's bindgen-time fallback for C23
 * <stdckdint.h> (issue #192). Ruby 4.0's ruby/internal/stdckdint.h
 * angles-includes it when the runtime's configure found it
 * (HAVE_STDCKDINT_H in the leg's ruby/config.h), but the boot smoke's
 * bindgen replays those headers against the SMOKE host's libclang —
 * a different toolchain generation than the leg's build compiler, whose
 * resource dir may not carry the C23 header (the linux-gnu legs).
 * This directory rides BINDGEN_EXTRA_CLANG_ARGS as -idirafter, i.e. it
 * is searched strictly AFTER every system/compiler path: a toolchain
 * that ships the real header never sees this file.
 *
 * The macro semantics mirror ruby's own fallback branch in
 * ruby/internal/stdckdint.h (the __builtin_*_overflow spelling), so the
 * parsed declarations are identical whichever provider wins.
 */
#ifndef TEBAKO_SMOKE_BINDGEN_STDCKDINT_SHIM_H
#define TEBAKO_SMOKE_BINDGEN_STDCKDINT_SHIM_H

#define __STDC_VERSION_STDCKDINT_H__ 202311L
#define ckd_add(x, y, z) __builtin_add_overflow((y), (z), (x))
#define ckd_sub(x, y, z) __builtin_sub_overflow((y), (z), (x))
#define ckd_mul(x, y, z) __builtin_mul_overflow((y), (z), (x))

#endif /* TEBAKO_SMOKE_BINDGEN_STDCKDINT_SHIM_H */

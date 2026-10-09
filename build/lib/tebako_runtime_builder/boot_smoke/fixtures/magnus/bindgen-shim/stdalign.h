/*
 * The magnus boot-smoke fixture's bindgen-time fallback for C11
 * <stdalign.h> (issue #192, windows x86_64 legs). Ruby 4.0's
 * ruby/defines.h angle-includes it, and the fixture's bindgen libclang
 * resolves without a resource dir that carries the freestanding header.
 * This directory rides BINDGEN_EXTRA_CLANG_ARGS as -idirafter, i.e. it
 * is searched strictly AFTER every system/compiler path: a toolchain
 * that ships the real header never sees this file.
 *
 * Parse-only: the macros mirror the standard's freestanding spelling.
 */
#ifndef TEBAKO_SMOKE_BINDGEN_STDALIGN_SHIM_H
#define TEBAKO_SMOKE_BINDGEN_STDALIGN_SHIM_H

#define alignas _Alignas
#define __alignas_is_defined 1

#endif /* TEBAKO_SMOKE_BINDGEN_STDALIGN_SHIM_H */

/*
 * The magnus boot-smoke fixture's bindgen-time fallback for
 * <mm_malloc.h> (issue #192, windows x86_64 legs). msys2's ucrt64
 * malloc.h angle-includes mm_malloc.h, which mingw-w64 does not ship
 * in its include dir — the msys clang finds it in its own resource
 * include, but the build script's bindgen libclang resolves without
 * that resource dir and dies at parse. This directory rides
 * BINDGEN_EXTRA_CLANG_ARGS as -idirafter, i.e. it is searched
 * strictly AFTER every system/compiler path: a toolchain that ships
 * the real header never sees this file.
 *
 * Parse-only: bindgen needs the declarations to resolve; the fixture
 * never calls the aligned-malloc API, and the definitions are the
 * platform C runtime's at link time.
 */
#ifndef TEBAKO_SMOKE_BINDGEN_MM_MALLOC_SHIM_H
#define TEBAKO_SMOKE_BINDGEN_MM_MALLOC_SHIM_H

#include <stddef.h>

void *_mm_malloc(size_t size, size_t alignment);
void _mm_free(void *ptr);

#endif /* TEBAKO_SMOKE_BINDGEN_MM_MALLOC_SHIM_H */

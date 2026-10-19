/*
 * The magnus boot-smoke fixture's bindgen-time fallback for C99
 * <stdbool.h> (issues #192/#287). Ruby 3.2's headers use the C99 bool
 * spelling (`bool`/`true`/`false` via ruby/backward/2/bool.h and
 * ruby/internal/special_consts.h), but the boot smoke's bindgen replays
 * those headers against the SMOKE host's libclang — whose parse may
 * run without the freestanding resource include carrying stdbool.h,
 * so `bool` surfaces as an unknown type and `true` as an undeclared
 * identifier (the ruby 3.2.11 windows x86_64 leg's first publish run).
 * This directory rides BINDGEN_EXTRA_CLANG_ARGS as -idirafter, i.e. it
 * is searched strictly AFTER every system/compiler path: a toolchain
 * that ships the real header never sees this file.
 *
 * The content is the C99 standard's entire stdbool.h.
 */
#ifndef __STDBOOL_H_SHIM__
#define __STDBOOL_H_SHIM__

#define bool  _Bool
#define true  1
#define false 0

#define __bool_true_false_are_defined 1

#endif

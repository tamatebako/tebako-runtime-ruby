# Copyright (c) 2021-2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of the Tebako project.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# ...................................................................
# Tebako runtime build project (tebako-runtime-ruby)
#
# Vendored from the tebako gem's CMakeLists.txt (tamatebako/tebako,
# runtime 'press -m runtime' driver) and adapted to build from the
# PRE-PATCHED ruby source published by tamatebako/ruby as the
# tfs-ruby-<version>-src.tar.gz release assets:
#  - the gem's pass1/pass1a/pass2 patch steps are gone; the source
#    tree arrives with the tebako patch set already applied
#  - the consumer-side substitutions the patched tree expects are
#    performed by build/tools/build_pass.rb (over build/lib):
#      * '@TEBAKO_MLIBS@' in template/Makefile.in  -> the platform
#        static library list (gem: PatchLibraries.mlibs)
#      * S["MAINLIBS"] in the generated config.status (post-configure)
#  - the entry driver is the modern tebako_fs_* C API one
#    (src/tebako-main.cpp, vendored from the gem)
#  - a stub libtebako-fs.a (tools/runtime entry symbols only) lets the
#    toolchain ruby link and run as a plain interpreter during
#    'make install'; it is removed after the toolchain build and the
#    final relink (tools/build_runtime, after this project builds)
#    picks up the real libtebako-fs.a with the embedded filesystem
#
# Expected on the cmake command line:
#   -DTEBAKO_VERSION:STRING=x.y.z   (runtime contract version)
#   -DRUBY_VER:STRING=x.y.z         (ruby version)
#   -DRUBY_TARBALL:STRING=<path|file:// URL of tfs-ruby-<v>-src.tar.gz>
#   -DRUBY_HASH:STRING=<sha256 of the tarball>
#   -DRUNTIME_NAME:STRING=<runtime package base name, for stub.rb>
#   [-DDEPS:STRING=<deps folder>]   (default: <binary dir>/deps)
#   [-DLOG_LEVEL:STRING=error]
#   [-DREMOVE_GLIBC_PRIVATE=ON]     (linux-gnu: build patchelf)

cmake_minimum_required (VERSION 3.20)
# Version 3.20 for cmake_path

# For project( ... VERSION ... )
cmake_policy(SET CMP0048 NEW)
# DOWNLOAD_EXTRACT_TIMESTAMP option default = true
if(${CMAKE_VERSION} VERSION_GREATER "3.23.10")
  cmake_policy(SET CMP0135 NEW)
endif()

if ("-${TEBAKO_VERSION}" STREQUAL "-")
  message(FATAL_ERROR "Tebako version is not specified.")
endif()

project(tebako_runtime VERSION ${TEBAKO_VERSION})

include(ExternalProject)
# This is the default that will be overwritten for MacOS and MSys
set(GNU_BASH "bash")

include(${CMAKE_SOURCE_DIR}/cmake-scripts/macos-environment.cmake)
include(${CMAKE_SOURCE_DIR}/cmake-scripts/msys-environment.cmake)
include(${CMAKE_SOURCE_DIR}/cmake-scripts/def-external-project.cmake)

if(NOT LOG_LEVEL)
  set(LOG_LEVEL "error")
endif()

execute_process(
  COMMAND "${GNU_BASH}"
          "-c"
          "echo \$OSTYPE"
  RESULT_VARIABLE OSTYPE_RES
  OUTPUT_VARIABLE OSTYPE_TXT
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(OSTYPE_RES EQUAL 0)
  message(STATUS "OSTYPE: '${OSTYPE_TXT}'")
else(OSTYPE_RES EQUAL 0)
  message(FATAL_ERROR "Failed to detect OSTYPE: ${OSTYPE_TXT}")
endif(OSTYPE_RES EQUAL 0)

# The ruby interpreter running the build tooling (build_pass.rb)
find_program(RUBY_INTERP NAMES ruby)
if(NOT RUBY_INTERP)
  message(FATAL_ERROR "ruby interpreter not found (needed to run the build tooling)")
endif()
message(STATUS "Build tooling ruby: ${RUBY_INTERP}")

set(IS_GNU OFF)
set(IS_MUSL OFF)
set(IS_MSYS OFF)
set(IS_DARWIN OFF)
set(RB_W32 OFF)
set(RUBY_WITHOUT_EXT "dbm,win32,win32ole,-test-/*")
option(DWARFS_PRELOAD "Deploy the prebuilt libtfs package from the GitHub release (OFF builds libtfs from source with the vcpkg toolchain)" ON)
if(DEFINED ENV{DWARFS_PRELOAD})
  set(DWARFS_PRELOAD $ENV{DWARFS_PRELOAD} CACHE BOOL "Deploy the prebuilt libtfs package from the GitHub release" FORCE)
endif()
set(WITH_PATCHELF OFF)

if("${OSTYPE_TXT}" MATCHES "^linux-gnu.*")
  set(IS_GNU ON)
  if(REMOVE_GLIBC_PRIVATE)
    set(WITH_PATCHELF ON)
  endif(REMOVE_GLIBC_PRIVATE)
elseif("${OSTYPE_TXT}" MATCHES "^linux-musl.*")
  set(IS_MUSL ON)
elseif("${OSTYPE_TXT}" MATCHES "^msys*" OR "${OSTYPE_TXT}" MATCHES "^cygwin*")
  set(IS_MSYS ON)
  set(RB_W32 ON)
  set(RUBY_WITHOUT_EXT "dbm,syslog,pty,gdbm,readline,-test-/*")
elseif("${OSTYPE_TXT}" MATCHES "^darwin.*")
  set(IS_DARWIN ON)
endif()

if(${RUBY_VER} VERSION_LESS "3.1.0")
  set(OPENSSL_VER "1.1")
else(${RUBY_VER} VERSION_LESS "3.1.0")
  set(OPENSSL_VER "3")
endif(${RUBY_VER} VERSION_LESS "3.1.0")


if(IS_DARWIN)
  execute_process(
    COMMAND "sysctl" "-n" "hw.ncpu"
    RESULT_VARIABLE NCORES_RES
    OUTPUT_VARIABLE NCORES
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
else(IS_DARWIN)
  execute_process(
    COMMAND "nproc" "--all"
    RESULT_VARIABLE NCORES_RES
    OUTPUT_VARIABLE NCORES
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
endif(IS_DARWIN)

if(NCORES_RES EQUAL 0)
  message(STATUS "NCORES: ${NCORES}")
else(NCORES_RES EQUAL 0)
  set(NCORES 4)
  message(WARNING "Failed to detect NCORES, resetting to ${NCORES} (default)")
endif(NCORES_RES EQUAL 0)

# Various locations for external projects
set(DEPS ${CMAKE_CURRENT_BINARY_DIR}/deps CACHE STRING "Dependencies' folder'")
set(DEPS_INCLUDE_DIR ${DEPS}/include)
set(DEPS_SRC_DIR ${DEPS}/src)
set(DEPS_LIB_DIR ${DEPS}/lib)
set(DEPS_BIN_DIR ${DEPS}/bin)
set(DEPS_SBIN_DIR ${DEPS}/sbin)

# Generated files (tebako-version.h, tebako-fs.cpp, local/stub.rb)
set(GEN_DIR ${CMAKE_CURRENT_BINARY_DIR}/gen)

# ...................................................................
# External projects

if ("-${RUBY_VER}" STREQUAL "-" OR "-${RUBY_HASH}" STREQUAL "-" OR "-${RUBY_TARBALL}" STREQUAL "-")
  message(FATAL_ERROR "Ruby version, source tarball and its SHA256 must be specified (RUBY_VER, RUBY_TARBALL, RUBY_HASH)")
endif()

set(RUBY_PRJ _ruby_${RUBY_VER})
set(RUBY_SOURCE_DIR ${DEPS}/src/${RUBY_PRJ})
set(RUBY_BINARY_DIR ${DEPS}/src/${RUBY_PRJ})
set(RUBY_STASH_DIR ${DEPS}/stash_${RUBY_VER})

string(SUBSTRING ${RUBY_VER} 0 3 RUBY_VER_BASE)
string(CONCAT RUBY_API_VER ${RUBY_VER_BASE} ".0")

# libtfs (former libdwarfs-wr): DWARFS_WR_TAG selects the libtfs git tag for
# the source build and the matching GitHub release for the prebuilt package
def_ext_prj_g(DWARFS_WR "v0.12.10")

# Provisions libtfs (prebuilt package or vcpkg toolchain for the source
# build), the prebuilt mkdwarfs, and -- for the prebuilt path -- the
# transitive static dependencies the libtfs package does not ship.
# Sets LIBTFS_* variables summarized below.
include(${CMAKE_SOURCE_DIR}/cmake/tebako-libtfs.cmake)

# incbin (graphitemaster/incbin): single-header asset embedding used by
# include/tebako/tebako-fs.h and the generated tebako-fs.cpp. It was deployed
# into ${DEPS_INCLUDE_DIR} by the libdwarfs-wr package; libtfs does not carry
# it, so tebako provisions it directly.
def_ext_prj_g(INCBIN "6e576cae5ab5810f25e2631f2e0b80cbe7dc8cbf")
set(INCBIN_HEADER "${DEPS_INCLUDE_DIR}/incbin/incbin.h")
set(INCBIN_SHA256 "70995329299ec55d414ad6df6929ddcfe0a43a40102cf6c05ff3c74ddd2765cb")
set(__INCBIN_DOWNLOAD ON)
if(EXISTS "${INCBIN_HEADER}")
  file(SHA256 "${INCBIN_HEADER}" __INCBIN_CURRENT)
  if(__INCBIN_CURRENT STREQUAL INCBIN_SHA256)
    set(__INCBIN_DOWNLOAD OFF)
  endif()
endif()
if(__INCBIN_DOWNLOAD)
  message(STATUS "incbin: fetching incbin.h @ ${INCBIN_TAG}")
  file(MAKE_DIRECTORY "${DEPS_INCLUDE_DIR}/incbin")
  file(DOWNLOAD "https://raw.githubusercontent.com/graphitemaster/incbin/${INCBIN_TAG}/incbin.h"
       "${INCBIN_HEADER}" EXPECTED_HASH "SHA256=${INCBIN_SHA256}"
       STATUS __INCBIN_STATUS)
  list(GET __INCBIN_STATUS 0 __INCBIN_CODE)
  list(GET __INCBIN_STATUS 1 __INCBIN_MSG)
  if(NOT __INCBIN_CODE EQUAL 0)
    file(REMOVE "${INCBIN_HEADER}")
    message(FATAL_ERROR "incbin: failed to download incbin.h: ${__INCBIN_MSG}")
  endif()
  message(STATUS "incbin: SHA256 verified (${INCBIN_SHA256})")
endif()

def_ext_prj_g(PATCHELF "65e14792061c298f1d2bc44becd48a10cbf0bc81")

set(LIBYAML_RUBY_OPTION "")
set(RUBY_LIBS "")
if(${RUBY_VER} VERSION_LESS "3.2.0")
  set(LIBYAML_RUBY_OPTION "--enable-bundled-libyaml")
endif(${RUBY_VER} VERSION_LESS "3.2.0")

message("Configuration summary:")
message(STATUS "ruby: v${RUBY_VER} at ${RUBY_SOURCE_DIR}")
message(STATUS "ruby source tarball: ${RUBY_TARBALL}")

if(DWARFS_PRELOAD)
  message(STATUS "libtfs: v${LIBTFS_VERSION} prebuilt package (${LIBTFS_PLATFORM}) at ${LIBTFS_LIB_DIR}")
else(DWARFS_PRELOAD)
  message(STATUS "libtfs: source build @${DWARFS_WR_TAG} at ${DWARFS_WR_SOURCE_DIR}")
endif(DWARFS_PRELOAD)
message(STATUS "libtfs headers: ${LIBTFS_INCLUDE_DIR}")
message(STATUS "mkdwarfs: ${LIBTFS_MKDWARFS}")
if(LIBTFS_VCPKG_TRIPLET_DIR)
  message(STATUS "libtfs transitive dependencies (vcpkg): ${LIBTFS_VCPKG_TRIPLET_DIR}")
else()
  message(STATUS "libtfs transitive dependencies (vcpkg): ${LIBTFS_VCPKG_INSTALLED_DIR}/<triplet> (resolved during the libtfs build)")
endif()

# ...................................................................
# Filesystem locations

# DATA_SRC_DIR folder is used to collect all files that need to be packaged
set(DATA_SRC_DIR  ${CMAKE_CURRENT_BINARY_DIR}/s)
# DATA_PRE_DIR folder is used to build gems  that need to be packaged
set(DATA_PRE_DIR  ${CMAKE_CURRENT_BINARY_DIR}/r)
# DATA_BIN_DIR folder is used to create packaged filesystem
set(DATA_BIN_DIR  ${CMAKE_CURRENT_BINARY_DIR}/p)
# DATA_BIN_FILE is packaged filesystem itself
set(DATA_BIN_FILE ${DATA_BIN_DIR}/fs.bin)
# Target binary directory
set (TBD ${DATA_SRC_DIR}/bin)
# Target library directory
set (TLIBD ${DATA_SRC_DIR}/lib)
# Target 'local' directory
set (TLD ${DATA_SRC_DIR}/local)
# TGD folder is used to install gems
set (TGD ${DATA_SRC_DIR}/lib/ruby/gems/${RUBY_API_VER})
# This is actually a constant that shall match libdwarfs-wr TEBAKO_MOUNT_POINT at tebako-common.h
if(${IS_MSYS})
  set(FS_MOUNT_POINT "A:/__tebako_memfs__")
else(${IS_MSYS})
  set(FS_MOUNT_POINT "/__tebako_memfs__")
endif(${IS_MSYS})

message(STATUS "DATA_SRC_DIR: ${DATA_SRC_DIR}")
message(STATUS "DATA_PRE_DIR: ${DATA_PRE_DIR}")
message(STATUS "DATA_BIN_DIR: ${DATA_BIN_DIR}")
message(STATUS "DATA_BIN_FILE: ${DATA_BIN_FILE}")
message(STATUS "Target binary directory: ${TBD}")
message(STATUS "Target library directory: ${TLIBD}")
message(STATUS "Target local directory: ${TLD}")
message(STATUS "Target Gem directory: ${TGD}")
message(STATUS "FS_MOUNT_POINT: ${FS_MOUNT_POINT}")
message(STATUS "Building for Win32 Ruby (RB_W32): ${RB_W32}")
message(STATUS "Removing GLIBC_PRIVATE reference: ${WITH_PATCHELF}")

# ...................................................................
# Other options

message(STATUS "Not building Ruby extensions: ${RUBY_WITHOUT_EXT}")

# ...................................................................
# Generated files (the runtime-mode subset of the gem's codegen:
# tebako-version.h, the stub filesystem translation unit, stub.rb)

string(REPLACE "." ";" __TEBAKO_VPARTS ${TEBAKO_VERSION})
list(GET __TEBAKO_VPARTS 0 TEBAKO_VERSION_MAJOR)
list(GET __TEBAKO_VPARTS 1 TEBAKO_VERSION_MINOR)
list(GET __TEBAKO_VPARTS 2 TEBAKO_VERSION_TEENY)

if ("-${RUNTIME_NAME}" STREQUAL "-")
  set(RUNTIME_NAME "tebako-runtime")
endif()

configure_file(${CMAKE_SOURCE_DIR}/resources/tebako-version.h.in ${GEN_DIR}/tebako-version.h @ONLY)
configure_file(${CMAKE_SOURCE_DIR}/resources/tebako-fs.cpp.in ${GEN_DIR}/tebako-fs.cpp @ONLY)
configure_file(${CMAKE_SOURCE_DIR}/resources/stub.rb.in ${GEN_DIR}/local/stub.rb @ONLY)

# ...................................................................
# DwarFS-based tebako filesystem library (libtfs)

# ...................................................................
# The libraries provided by libtfs (prebuilt package or source build):
# libtfs.a plus its pure-C dirent helper. These forward-declarations and
# BUILD_BYPRODUCTS are required to support 'Ninja'
# Otherwise add_dependencies would be enough for 'Unix makefiles' generator

set(__LIBTFS "${DEPS_LIB_DIR}/libtfs.a")
set(__LIBTFS_HELPER "${DEPS_LIB_DIR}/libtebako_dirent_helper_c.a")

if(DWARFS_PRELOAD)
  # Everything for the prebuilt path (download, SHA256 verification,
  # deployment to ${DEPS}, vcpkg transitive dependencies) was done at
  # configure time by cmake/tebako-libtfs.cmake; the target only keeps the
  # dependency graph (ruby, setup) intact.
  add_custom_target(${DWARFS_WR_PRJ}
    COMMAND ${CMAKE_COMMAND} -E echo "libtfs v${LIBTFS_VERSION} prebuilt package [${LIBTFS_PLATFORM}] deployed to ${DEPS}"
  )
else(DWARFS_PRELOAD)
  ExternalProject_Add(${DWARFS_WR_PRJ}
    GIT_SHALLOW true
    PREFIX ${DEPS}
    GIT_REPOSITORY https://github.com/tamatebako/libtfs.git
    GIT_TAG ${DWARFS_WR_TAG}
    SOURCE_DIR ${DWARFS_WR_SOURCE_DIR}
    BINARY_DIR ${DWARFS_WR_BINARY_DIR}
    UPDATE_COMMAND ""
    BUILD_COMMAND ${CMAKE_COMMAND} --build ${DWARFS_WR_BINARY_DIR} --parallel ${NCORES}
    CMAKE_ARGS -DCMAKE_INSTALL_PREFIX=${DEPS}
               -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
               -DWITH_TESTS:BOOL=OFF
               -DWITH_ASAN:BOOL=OFF
               -DWITH_COVERAGE:BOOL=OFF
               -DWITH_LEGACY_TEBAKO_API:BOOL=ON
               # SquashFS adapter stays off in tebako builds (LGPL; tebako
               # packages use the dwarfs/zip backends only)
               -DWITH_SQUASHFS:BOOL=OFF
               -DMKDWARFS=${DEPS_BIN_DIR}/mkdwarfs
               -DTEBAKO_BUILD_SCOPE=LIB
               -DOPENSSL_VERSION=${OPENSSL_VER}
               -DRB_W32=${RB_W32}
               -DCMAKE_TOOLCHAIN_FILE=${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake
               -DVCPKG_INSTALLED_DIR=${LIBTFS_VCPKG_INSTALLED_DIR}
               ${LIBTFS_VCPKG_EP_TRIPLET_ARG}
               -GNinja
    BUILD_BYPRODUCTS ${__LIBTFS}
                     ${__LIBTFS_HELPER}
  )
endif(DWARFS_PRELOAD)

if(IS_GNU)
  ExternalProject_Add(${PATCHELF_PRJ}
    GIT_SHALLOW true
    PREFIX ${DEPS}
    GIT_REPOSITORY https://github.com/chitao1234/patchelf.git
    GIT_TAG ${PATCHELF_WR_TAG}
    SOURCE_DIR ${PATCHELF_SOURCE_DIR}
    BINARY_DIR ${PATCHELF_BINARY_DIR}
    UPDATE_COMMAND ""
    CONFIGURE_COMMAND ${CMAKE_COMMAND} -E chdir ${PATCHELF_SOURCE_DIR} ./bootstrap.sh
              COMMAND ${PATCHELF_SOURCE_DIR}/configure
                  --srcdir=${PATCHELF_SOURCE_DIR}
                  --prefix=${DEPS}
    TEST_COMMAND ""
  )
endif(IS_GNU)

# ...................................................................
# Ruby (pre-patched source, tfs-ruby-<version>-src.tar.gz)

set(RUBY_L_FLAGS "-L${DEPS_LIB_DIR} -L${CMAKE_CURRENT_BINARY_DIR}")
if(LIBTFS_VCPKG_TRIPLET_DIR)
  # Transitive static deps of libtfs (dwarfs reader set, flatbuffers, zip,
  # codecs) live in the vcpkg install tree; referenced as -l:lib<name>.a in
  # the patched ruby MAINLIBS (build_pass.rb 'prepare', Mlibs)
  string(CONCAT RUBY_L_FLAGS ${RUBY_L_FLAGS} " -L${LIBTFS_VCPKG_TRIPLET_DIR}/lib")
endif(LIBTFS_VCPKG_TRIPLET_DIR)
set(RUBY_C_FLAGS "-fPIC -I${DEPS_INCLUDE_DIR} -I${CMAKE_CURRENT_SOURCE_DIR}/include -Wno-incompatible-pointer-types")
if(LIBTFS_VCPKG_TRIPLET_DIR)
  # The transitive deps' headers (deployed from the libtfs-deps package or
  # installed by vcpkg) live in the triplet include dir. Baked into rbconfig
  # via the ruby build, this -I lets mkmf-driven gem native extensions
  # (e.g. the brotli gem) resolve headers like <brotli/encode.h> when the
  # packaged build runs gem install.
  string(CONCAT RUBY_C_FLAGS ${RUBY_C_FLAGS} " -I${LIBTFS_VCPKG_TRIPLET_DIR}/include")
endif(LIBTFS_VCPKG_TRIPLET_DIR)

if(${RUBY_VER} VERSION_LESS "3.2.0" AND CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL "15.0.0" AND "${CMAKE_CXX_COMPILER_ID}" STREQUAL "GNU")
  string(CONCAT RUBY_C_FLAGS ${RUBY_C_FLAGS} " -std=gnu17")
endif(${RUBY_VER} VERSION_LESS "3.2.0" AND CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL "15.0.0" AND "${CMAKE_CXX_COMPILER_ID}" STREQUAL "GNU")

# Shadow
# https://github.com/deivid-rodriguez/byebug/issues/825
# (it happens under some conditions though it is hard to explain when)
if (CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  string(CONCAT RUBY_C_FLAGS ${RUBY_C_FLAGS} " -fdeclspec")
endif()

set(C_FLAGS_DEST cflags)

if(IS_DARWIN)
  string(CONCAT RUBY_C_FLAGS ${RUBY_C_FLAGS} " -I${BREW_PREFIX}/opt/openssl@${OPENSSL_VER}/include -I${BREW_PREFIX}/opt/zlib/include -I${BREW_PREFIX}/include")
  string(CONCAT RUBY_L_FLAGS ${RUBY_L_FLAGS} " -L${BREW_PREFIX}/opt/openssl@${OPENSSL_VER}/lib -L${BREW_PREFIX}/opt/zlib/lib  -L${BREW_PREFIX}/lib")
  set(OPENSSL_RUBY_OPTION "--with-openssl-dir=${BREW_PREFIX}/opt/openssl@${OPENSSL_VER}")
else(IS_DARWIN)
  if(IS_MUSL)
    string(CONCAT RUBY_C_FLAGS ${RUBY_C_FLAGS} " -DENABLE_PATH_CHECK=0")
    if("${OPENSSL_VER}" EQUAL "1.1")
      set(OPENSSL_RUBY_OPTION "--with-openssl-dir=${DEPS}")
    endif("${OPENSSL_VER}" EQUAL "1.1")
  endif(IS_MUSL)

  if(RB_W32)
    string(CONCAT RUBY_C_FLAGS ${RUBY_C_FLAGS} " -DRB_W32=1")
    string(CONCAT RUBY_L_FLAGS ${RUBY_L_FLAGS} " -l:libstdc++.a -L${TLIBD}")
    # vcpkg's static libcrypto.a (the CAPI engine, e_capi.obj) references
    # the CryptoAPI certificate store (CertFreeCertificateContext & co.),
    # but ruby's default mingw $LIBS lack -lcrypt32, so every ext/openssl
    # have_func link probe failed with undefined Cert* references and the
    # OpenSSL-1.1.0 accessor fallbacks in openssl_missing.c compiled
    # against opaque 3.x structs (tebako#345). mkmf appends $LIBS after
    # -lssl/-lcrypto, so LIBS here lands in the right order for static
    # linking; advapi32/user32 cover the rest of the usual static-openssl
    # system-lib tail.
    set(RUBY_LIBS "-lcrypt32 -ladvapi32 -luser32")
    set(C_FLAGS_DEST cppflags)
  endif(RB_W32)

  # Ruby 2.7 configure script error
  if(${RUBY_VER} VERSION_LESS "3.0.0")
    set(C_FLAGS_DEST cppflags)
  endif()
endif(IS_DARWIN)

message(STATUS "Ruby build ${C_FLAGS_DEST}='${RUBY_C_FLAGS}'")
message(STATUS "Ruby build LDFLAGS='${RUBY_L_FLAGS}'")
message(STATUS "openssl Ruby option='${OPENSSL_RUBY_OPTION}'")
message(STATUS "libyaml Ruby option='${LIBYAML_RUBY_OPTION}'")

# The build-pass tooling (build/tools/build_pass.rb over build/lib) runs the
# consumer-side steps the pre-patched source tree expects:
#   prepare       -- substitute @TEBAKO_MLIBS@ in template/Makefile.in and
#                    build the stub libtebako-fs.a for the toolchain link
#   postconfigure -- substitute S["MAINLIBS"] in the generated config.status
#   toolchain     -- make + make install, stash the pristine environment,
#                    drop the stub libtebako-fs.a
ExternalProject_Add(${RUBY_PRJ}
  PREFIX ${DEPS}
  URL ${RUBY_TARBALL}
  URL_HASH SHA256=${RUBY_HASH}
  DOWNLOAD_NO_PROGRESS true
  SOURCE_DIR ${RUBY_SOURCE_DIR}
  BUILD_IN_SOURCE true
  CONFIGURE_COMMAND ""
  BUILD_COMMAND ${RUBY_INTERP} ${CMAKE_SOURCE_DIR}/tools/build_pass.rb prepare ${OSTYPE_TXT} ${RUBY_SOURCE_DIR} ${DEPS_LIB_DIR} ${RUBY_VER} ${FS_MOUNT_POINT} "${CMAKE_C_COMPILER}"
  # Make it for MacOS otherwise LDFLAGS are invalid
  # COMMAND ${CMAKE_COMMAND} -E make_directory ${DEPS_LIB_DIR}
  COMMAND ${GNU_BASH} -c "${RUBY_SOURCE_DIR}/configure  ${OPENSSL_RUBY_OPTION} ${LIBYAML_RUBY_OPTION} \
                                                        --without-gmp                         \
                                                        --disable-dtrace                      \
                                                        --disable-debug-env                   \
                                                        --disable-shared                      \
                                                        --disable-install-doc                 \
                                                        --with-static-linked-ext              \
                                                        --with-out-ext=${RUBY_WITHOUT_EXT}    \
                                                        --prefix=${DATA_SRC_DIR}              \
                                                        ${C_FLAGS_DEST}=\"${RUBY_C_FLAGS}\"   \
                                                        LDFLAGS=\"${RUBY_L_FLAGS}\"              \
                                                        LIBS=\"${RUBY_LIBS}\""
  COMMAND ${RUBY_INTERP} ${CMAKE_SOURCE_DIR}/tools/build_pass.rb postconfigure ${OSTYPE_TXT} ${RUBY_SOURCE_DIR} ${DEPS_LIB_DIR} ${RUBY_VER}
  COMMAND ${RUBY_INTERP} ${CMAKE_SOURCE_DIR}/tools/build_pass.rb toolchain ${RUBY_SOURCE_DIR} ${DATA_SRC_DIR} ${RUBY_STASH_DIR} ${DEPS_LIB_DIR}
  INSTALL_COMMAND  ""
)

add_dependencies(${RUBY_PRJ} ${DWARFS_WR_PRJ})

add_custom_target(setup
  ${CMAKE_COMMAND} -E echo "Tebako runtime setup has completed"
  DEPENDS ${DWARFS_WR_PRJ} ${RUBY_PRJ}
)
if(IS_GNU)
  add_dependencies(setup ${PATCHELF_PRJ})
endif(IS_GNU)

set(CMAKE_CXX_STANDARD      20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS   OFF)

# ...................................................................
# Packaged filesystem

add_custom_target(packaged_filesystem
  COMMAND ${RUBY_INTERP} ${CMAKE_SOURCE_DIR}/tools/build_pass.rb deploy ${RUBY_VER} ${RUBY_STASH_DIR} ${DATA_SRC_DIR} ${DATA_PRE_DIR} ${DATA_BIN_FILE} ${GEN_DIR}/local ${DEPS_BIN_DIR}
  DEPENDS setup
  BYPRODUCTS ${DATA_BIN_FILE}
)

set(CMAKE_CXX_FLAGS "${RUBY_C_FLAGS} -I${GEN_DIR}")

add_library(tebako-fs STATIC
  ${CMAKE_CURRENT_SOURCE_DIR}/src/tebako-main.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/include/tebako/tebako-main.h
  ${GEN_DIR}/tebako-fs.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/include/tebako/tebako-fs.h
  ${GEN_DIR}/tebako-version.h
)

if(${RUBY_VER} VERSION_LESS "3.3.0" AND ("${OSTYPE_TXT}" MATCHES "^msys*" OR "${OSTYPE_TXT}" MATCHES "^cygwin*"))
  target_compile_definitions(tebako-fs PUBLIC RB_W32_PRE_33)
endif(${RUBY_VER} VERSION_LESS "3.3.0" AND ("${OSTYPE_TXT}" MATCHES "^msys*" OR "${OSTYPE_TXT}" MATCHES "^cygwin*"))

add_dependencies(tebako-fs packaged_filesystem)

add_custom_target(tebako COMMAND ${CMAKE_COMMAND} -E true)
add_dependencies(tebako setup tebako-fs)

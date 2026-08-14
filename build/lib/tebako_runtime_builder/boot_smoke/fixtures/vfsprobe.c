/* vfsprobe.c — the VFS-resident native library the loader-interpose
 * scenario loads through fiddle AND through the probe C extension's own
 * dlopen. Links libvfsdep (recorded as @rpath/libvfsdep.dylib resp.
 * DT_NEEDED libvfsdep.so with an @loader_path/$ORIGIN runpath) so the
 * load only succeeds when the materialization extracted the dependency
 * closure, not just one file.
 *
 * Mirrors tamatebako/ruby ci/spec22/fixtures/vfsprobe.c. */
extern int vfsdep_value(void);

int
probe_answer(void)
{
    return vfsdep_value() + 1;
}

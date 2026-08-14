/* vfsdep.c — leaf dependency of libvfsprobe: exists so the spec-22
 * loader-interpose scenario exercises the Mach-O/ELF dependency-closure
 * walk of tebako_fs_dlmap2file (libvfsprobe links this library; the
 * closure walk must extract BOTH next to each other in the exec cache
 * for the real dlopen to resolve it).
 *
 * Mirrors tamatebako/ruby ci/spec22/fixtures/vfsdep.c (the same probe
 * family; the two homes are separate release chains — keep the sources
 * and the verdict strings in lockstep). */
int
vfsdep_value(void)
{
    return 41;
}

// Spec 22 class-E proof fixture (§3.3): the boot-smoke probe spawns
// `java -jar /probe/lib/probe.jar` — the jar is VFS-resident data, so the
// marker line below proves the spawned JVM read it through the interposed
// surface (the inherited preload shim + TEBAKO_TFS_MOUNTS), never through
// a host-side copy. See probe.jar.README for the regeneration note.
public class ProbeJar {
    public static void main(String[] args) {
        System.out.println("CLASS-E-EXEC-OK " + ProbeJar.class
                .getProtectionDomain().getCodeSource().getLocation());
    }
}

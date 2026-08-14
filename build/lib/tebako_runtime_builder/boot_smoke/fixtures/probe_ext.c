/* probe_ext.c — a ruby C extension that SELF-DLOPENS a VFS-resident
 * library from Init (bypassing ruby's dln_load entirely). This is the
 * load class the per-gem adapters used to paper over: without the spec-22
 * loader interposition the raw dlopen of "/probe/lib/..." fails on the
 * host; with it, the call is routed through the libtfs materialization
 * and the real file loads. dlsym runs unmodified against the returned
 * real handle (dlsym is deliberately not interposed). No Ruby adapter can
 * mask this leg: no adapter wraps a C extension's own dlopen.
 *
 * Mirrors tamatebako/ruby ci/spec22/fixtures/probe_ext.c. */

#include <ruby.h>
#include <dlfcn.h>
#include <stdio.h>

static VALUE probe_ext_answer(VALUE self);

void
Init_probe_ext(void)
{
    static int (*answer_fn)(void);
    void *handle;

    handle = dlopen(PROBE_LIB_PATH, RTLD_LAZY | RTLD_LOCAL);
    if (handle == NULL) {
        rb_raise(rb_eLoadError, "probe_ext self-dlopen of %s failed: %s",
                 PROBE_LIB_PATH, dlerror());
    }
    answer_fn = (int (*)(void))dlsym(handle, "probe_answer");
    if (answer_fn == NULL) {
        rb_raise(rb_eLoadError, "probe_ext: probe_answer missing in %s",
                 PROBE_LIB_PATH);
    }
    {
        VALUE mod = rb_define_module("ProbeExt");
        rb_iv_set(mod, "@answer_fn", SIZET2NUM((size_t)answer_fn));
        rb_define_singleton_method(mod, "answer", probe_ext_answer, 0);
    }
}

static VALUE
probe_ext_answer(VALUE self)
{
    VALUE packed = rb_iv_get(self, "@answer_fn");
    int (*answer_fn)(void) = (int (*)(void))NUM2SIZET(packed);
    return INT2NUM(answer_fn());
}

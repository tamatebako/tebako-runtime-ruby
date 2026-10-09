//! Boot-smoke fixture (issue #192): a magnus-built extension gated on the
//! `ruby_thread_has_gvl_p` export surface. The function is an internal
//! CRuby declaration (internal/thread.h through the 3.4 line, public on
//! master) that the ruby-rust gem family binds; upstream owes the symbol
//! nothing, so a ruby-line bump could silently drop it. The fixture makes
//! every leg prove the three platform resolution contracts instead:
//! Linux dlopen-from-exe, macOS bundle_loader dynamic lookup, and the
//! Windows import-lib link.

use magnus::{function, Error, Ruby};

// Internal API — no installed header declares it through 3.4, so the
// declaration is the fixture's own; the link/load gate is the point.
extern "C" {
    fn ruby_thread_has_gvl_p() -> i32;
}

fn gvl_held() -> bool {
    unsafe { ruby_thread_has_gvl_p() != 0 }
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("TebakoBootSmoke")?;
    module.define_module_function("gvl_held?", function!(gvl_held, 0))?;
    Ok(())
}

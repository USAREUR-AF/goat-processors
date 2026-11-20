//! The kinds a correlate pack can name: its test kinds (`gate`, `confirm`,
//! `hold` lines; `pair_tests.rs`) and its methods (`method` line;
//! `method.rs`). `Registry::builtin()` is the spec's; a caller may register
//! more and parse a pack with them (`pack::parse_pack_with`).

use super::method::{MethodKind, BUILTIN_METHODS};
use super::pair_tests::{TestKind, BUILTIN_TESTS};

#[derive(Debug, Clone)]
pub struct Registry {
    pub tests: Vec<TestKind>,
    pub methods: Vec<MethodKind>,
}

impl Registry {
    /// The tests of correlate.md Tests and the methods `confirm` and `assign`.
    pub fn builtin() -> Registry {
        Registry { tests: BUILTIN_TESTS.to_vec(), methods: BUILTIN_METHODS.to_vec() }
    }

    /// Adds a test kind; it replaces a registered kind of the same name.
    pub fn register_test(&mut self, kind: TestKind) -> &mut Registry {
        self.tests.retain(|k| k.name != kind.name);
        self.tests.push(kind);
        self
    }

    /// The method named `name`.
    pub fn method(&self, name: &str) -> Option<MethodKind> {
        self.methods.iter().find(|m| m.name == name).copied()
    }
}

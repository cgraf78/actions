//! Minimal crate used to exercise the shared Rust CI defaults.
//!
//! The fixture intentionally satisfies the default missing-docs policy rather
//! than overriding it, so this repository tests the same contract consumers
//! receive.

/// Return the fixed smoke-test result.
pub fn smoke() -> bool {
    true
}

#[cfg(test)]
mod tests {
    #[test]
    fn smoke_passes() {
        assert!(super::smoke());
    }
}

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

//! The engine's JSON, with a limit on nesting depth for everything the
//! runner reads.
//!
//! The engine's parser descends one call per `[` or `{`. Without a limit, one
//! UDP datagram, fabric sample or request body holding tens of thousands of
//! open brackets overflows the thread's stack and aborts the whole runner.
//! Every parse in the runner goes through `parse` here, which refuses text
//! nested deeper than `MAX_DEPTH` before the engine's parser sees it.

pub use goat_correlator::json::{Json, Map};

/// Deeper than any report, request or reply the runner reads.
pub const MAX_DEPTH: usize = 64;

pub fn parse(text: &str) -> Result<Json, String> {
    let (mut depth, mut in_string, mut escaped) = (0usize, false, false);
    for b in text.bytes() {
        if in_string {
            match b {
                _ if escaped => escaped = false,
                b'\\' => escaped = true,
                b'"' => in_string = false,
                _ => {}
            }
            continue;
        }
        match b {
            b'"' => in_string = true,
            b'[' | b'{' => {
                depth += 1;
                if depth > MAX_DEPTH {
                    return Err(format!("nested deeper than {MAX_DEPTH} levels"));
                }
            }
            b']' | b'}' => depth = depth.saturating_sub(1),
            _ => {}
        }
    }
    goat_correlator::json::parse(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deep_nesting_is_refused_before_the_parser_sees_it() {
        assert!(parse(&"[".repeat(200_000)).unwrap_err().contains("nested deeper"));
        let ok = format!("{}1{}", "[".repeat(MAX_DEPTH), "]".repeat(MAX_DEPTH));
        assert!(parse(&ok).is_ok());
        let over = format!("{}1{}", "[".repeat(MAX_DEPTH + 1), "]".repeat(MAX_DEPTH + 1));
        assert!(parse(&over).is_err());
        // Brackets inside strings do not count, nor do escaped quotes end them.
        let s = format!("{{\"a\":\"{}\\\"{}\"}}", "[".repeat(500), "{".repeat(500));
        assert!(parse(&s).is_ok());
        assert!(parse("{\"lat\":1.5,\"members\":[\"a\",\"b\"]}").is_ok());
    }
}


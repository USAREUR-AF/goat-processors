//! The command-line runner of tools/perf/README.md, "Runner contract":
//!
//! ```text
//! runner --function <correlate|filter|fuse|quality> --pack <dir> --steps <file>
//!        [--events <file>] [--trace]
//! ```
//!
//! Standard output is one line of counters; diagnostics go to standard error.
//! The work is `goat_correlator::io`.

use std::process::ExitCode;

use goat_correlator::io::{run, Args};

fn main() -> ExitCode {
    match Args::parse(std::env::args().skip(1)).and_then(|args| run(&args)) {
        Ok(counters) => {
            println!("{}", counters);
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("runner: {}", e);
            ExitCode::FAILURE
        }
    }
}

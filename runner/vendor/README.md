# Vendored crates

One crate, replaced through `[patch.crates-io]` in `runner/Cargo.toml`.

| Crate | Base | Change | Remove when |
|---|---|---|---|
| `zenoh-link-tls` | 1.9.0 from crates.io | [eclipse-zenoh/zenoh#2910](https://github.com/eclipse-zenoh/zenoh/pull/2910), commit `169d9182cb4d2b947741226370ab9b9ac5cc60d9`, applied to `src/unicast.rs`; its test `src/concurrent_io_tests.rs`; the `zenoh-runtime` dependency it no longer uses removed. Nothing else | `runner/Cargo.toml` moves to the first zenoh release that carries #2910 |

Without the change the TLS link lets its read task and its write task enter
one rustls connection at the same time, which rustls does not support: a
process can crash, or a burst of input can stall.

License: EPL-2.0 OR Apache-2.0, with upstream's `LICENSE` and `NOTICE.md`.
The test of the change:

```sh
cargo test --locked --manifest-path runner/Cargo.toml -p zenoh-link-tls
```

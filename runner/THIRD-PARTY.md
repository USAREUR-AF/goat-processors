<!-- Written by runner/packaging/third-party.py from Cargo.lock. Do not edit. -->
# Third-party crates in the runner

The runner (`runner/`) is built from these crates, each at the exact version
`runner/Cargo.lock` pins. The engines use none of them. `cargo deny check`
(`runner/deny.toml`) and `cargo audit` run on them in CI.

250 crates, for the Linux targets x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu.

| Crate | Version | License | Source |
|---|---|---|---|
| adler2 | 2.0.1 | 0BSD OR MIT OR Apache-2.0 | https://github.com/oyvindln/adler2 |
| aes | 0.8.4 | MIT OR Apache-2.0 | https://github.com/RustCrypto/block-ciphers |
| ahash | 0.8.12 | MIT OR Apache-2.0 | https://github.com/tkaitchuck/ahash |
| allocator-api2 | 0.2.21 | MIT OR Apache-2.0 | https://github.com/zakarumych/allocator-api2 |
| anyhow | 1.0.104 | MIT OR Apache-2.0 | https://github.com/dtolnay/anyhow |
| ar_archive_writer | 0.5.5 | Apache-2.0 WITH LLVM-exception | https://github.com/rust-lang/ar_archive_writer |
| arc-swap | 1.9.5 | MIT OR Apache-2.0 | https://github.com/vorner/arc-swap |
| array-init | 2.1.0 | MIT OR Apache-2.0 | https://github.com/Manishearth/array-init/ |
| asn1-rs | 0.7.2 | MIT OR Apache-2.0 | https://github.com/rusticata/asn1-rs.git |
| asn1-rs-derive | 0.6.0 | MIT OR Apache-2.0 | https://github.com/rusticata/asn1-rs.git |
| asn1-rs-impl | 0.2.0 | MIT/Apache-2.0 | https://github.com/rusticata/asn1-rs.git |
| async-trait | 0.1.92 | MIT OR Apache-2.0 | https://github.com/dtolnay/async-trait |
| autocfg | 1.5.1 | Apache-2.0 OR MIT | https://github.com/cuviper/autocfg |
| base64 | 0.22.1 | MIT OR Apache-2.0 | https://github.com/marshallpierce/rust-base64 |
| bitflags | 2.13.2 | MIT OR Apache-2.0 | https://github.com/bitflags/bitflags |
| block-buffer | 0.10.4 | MIT OR Apache-2.0 | https://github.com/RustCrypto/utils |
| bytes | 1.12.2 | MIT | https://github.com/tokio-rs/bytes |
| cc | 1.11.2 | MIT OR Apache-2.0 | https://github.com/rust-lang/cc-rs |
| cfg-if | 1.0.5 | MIT OR Apache-2.0 | https://github.com/rust-lang/cfg-if |
| cipher | 0.4.4 | MIT OR Apache-2.0 | https://github.com/RustCrypto/traits |
| const_format | 0.2.37 | Zlib | https://github.com/rodrimati1992/const_format_crates/ |
| const_format_proc_macros | 0.2.37 | Zlib | https://github.com/rodrimati1992/const_format_crates/ |
| cpufeatures | 0.2.17 | MIT OR Apache-2.0 | https://github.com/RustCrypto/utils |
| crc32fast | 1.5.5 | MIT OR Apache-2.0 | https://github.com/srijs/rust-crc32fast |
| crossbeam | 0.8.5 | MIT OR Apache-2.0 | https://github.com/crossbeam-rs/crossbeam |
| crossbeam-channel | 0.5.17 | MIT OR Apache-2.0 | https://github.com/crossbeam-rs/crossbeam |
| crossbeam-deque | 0.8.8 | MIT OR Apache-2.0 | https://github.com/crossbeam-rs/crossbeam |
| crossbeam-epoch | 0.9.21 | MIT OR Apache-2.0 | https://github.com/crossbeam-rs/crossbeam |
| crossbeam-queue | 0.3.14 | MIT OR Apache-2.0 | https://github.com/crossbeam-rs/crossbeam |
| crossbeam-utils | 0.8.23 | MIT OR Apache-2.0 | https://github.com/crossbeam-rs/crossbeam |
| crypto-common | 0.1.7 | MIT OR Apache-2.0 | https://github.com/RustCrypto/traits |
| darling | 0.24.1 | MIT | https://github.com/TedDriggs/darling |
| darling_core | 0.24.1 | MIT | https://github.com/TedDriggs/darling |
| darling_macro | 0.24.1 | MIT | https://github.com/TedDriggs/darling |
| data-encoding | 2.11.1 | MIT | https://github.com/ia0/data-encoding |
| der-parser | 10.0.0 | MIT OR Apache-2.0 | https://github.com/rusticata/der-parser.git |
| deranged | 0.5.9 | MIT OR Apache-2.0 | https://github.com/jhpratt/deranged |
| digest | 0.10.7 | MIT OR Apache-2.0 | https://github.com/RustCrypto/traits |
| dirs | 6.0.0 | MIT OR Apache-2.0 | https://github.com/soc/dirs-rs |
| dirs-sys | 0.5.0 | MIT OR Apache-2.0 | https://github.com/dirs-dev/dirs-sys-rs |
| displaydoc | 0.2.7 | MIT OR Apache-2.0 | https://github.com/yaahc/displaydoc |
| dyn-clone | 1.0.20 | MIT OR Apache-2.0 | https://github.com/dtolnay/dyn-clone |
| either | 1.19.0 | MIT OR Apache-2.0 | https://github.com/rayon-rs/either |
| equivalent | 1.0.3 | Apache-2.0 OR MIT | https://github.com/indexmap-rs/equivalent |
| event-listener | 5.4.2 | Apache-2.0 OR MIT | https://github.com/smol-rs/event-listener |
| fastrand | 2.5.0 | Apache-2.0 OR MIT | https://github.com/smol-rs/fastrand |
| find-msvc-tools | 0.1.15 | MIT OR Apache-2.0 | https://github.com/rust-lang/cc-rs |
| fixedbitset | 0.5.9 | MIT OR Apache-2.0 | https://github.com/petgraph/fixedbitset |
| flate2 | 1.1.11 | MIT OR Apache-2.0 | https://github.com/rust-lang/flate2-rs |
| flume | 0.11.1 | Apache-2.0/MIT | https://github.com/zesterer/flume |
| foldhash | 0.1.5 | Zlib | https://github.com/orlp/foldhash |
| foldhash | 0.2.0 | Zlib | https://github.com/orlp/foldhash |
| futures | 0.3.34 | MIT OR Apache-2.0 | https://github.com/rust-lang/futures-rs |
| futures-channel | 0.3.34 | MIT OR Apache-2.0 | https://github.com/rust-lang/futures-rs |
| futures-core | 0.3.34 | MIT OR Apache-2.0 | https://github.com/rust-lang/futures-rs |
| futures-executor | 0.3.34 | MIT OR Apache-2.0 | https://github.com/rust-lang/futures-rs |
| futures-io | 0.3.34 | MIT OR Apache-2.0 | https://github.com/rust-lang/futures-rs |
| futures-macro | 0.3.34 | MIT OR Apache-2.0 | https://github.com/rust-lang/futures-rs |
| futures-sink | 0.3.34 | MIT OR Apache-2.0 | https://github.com/rust-lang/futures-rs |
| futures-task | 0.3.34 | MIT OR Apache-2.0 | https://github.com/rust-lang/futures-rs |
| futures-util | 0.3.34 | MIT OR Apache-2.0 | https://github.com/rust-lang/futures-rs |
| generic-array | 0.14.7 | MIT | https://github.com/fizyk20/generic-array.git |
| getrandom | 0.2.17 | MIT OR Apache-2.0 | https://github.com/rust-random/getrandom |
| getrandom | 0.3.4 | MIT OR Apache-2.0 | https://github.com/rust-random/getrandom |
| git-version | 0.3.9 | BSD-2-Clause | https://github.com/fusion-engineering/rust-git-version |
| git-version-macro | 0.3.9 | BSD-2-Clause | https://github.com/fusion-engineering/rust-git-version |
| hashbrown | 0.14.5 | MIT OR Apache-2.0 | https://github.com/rust-lang/hashbrown |
| hashbrown | 0.15.5 | MIT OR Apache-2.0 | https://github.com/rust-lang/hashbrown |
| hashbrown | 0.16.1 | MIT OR Apache-2.0 | https://github.com/rust-lang/hashbrown |
| hashbrown | 0.17.1 | MIT OR Apache-2.0 | https://github.com/rust-lang/hashbrown |
| hmac | 0.12.1 | MIT OR Apache-2.0 | https://github.com/RustCrypto/MACs |
| home | 0.5.12 | MIT OR Apache-2.0 | https://github.com/rust-lang/cargo |
| humantime | 2.4.0 | MIT OR Apache-2.0 | https://github.com/chronotope/humantime |
| ident_case | 1.0.1 | MIT/Apache-2.0 | https://github.com/TedDriggs/ident_case |
| indexmap | 2.14.2 | Apache-2.0 OR MIT | https://github.com/indexmap-rs/indexmap |
| inout | 0.1.4 | MIT OR Apache-2.0 | https://github.com/RustCrypto/utils |
| ipnetwork | 0.20.0 | MIT OR Apache-2.0 | https://github.com/achanda/ipnetwork |
| itertools | 0.14.0 | MIT OR Apache-2.0 | https://github.com/rust-itertools/itertools |
| itoa | 1.0.19 | MIT OR Apache-2.0 | https://github.com/dtolnay/itoa |
| json5 | 0.4.1 | ISC | https://github.com/callum-oakley/json5-rs |
| keccak | 0.1.6 | Apache-2.0 OR MIT | https://github.com/RustCrypto/sponges/tree/master/keccak |
| keyed-set | 1.1.0 | EPL-2.0 OR Apache-2.0 | https://github.com/p-avital/keyed-set-rs |
| konst | 0.2.20 | Zlib | https://github.com/rodrimati1992/konst/ |
| konst_macro_rules | 0.2.19 | Zlib | https://github.com/rodrimati1992/konst/ |
| lazy_static | 1.5.1 | MIT OR Apache-2.0 | https://github.com/rust-lang-nursery/lazy-static.rs |
| libc | 0.2.191 | MIT OR Apache-2.0 | https://github.com/rust-lang/libc |
| libloading | 0.8.9 | ISC | https://github.com/nagisa/rust_libloading/ |
| lock_api | 0.4.14 | MIT OR Apache-2.0 | https://github.com/Amanieu/parking_lot |
| log | 0.4.35 | MIT OR Apache-2.0 | https://github.com/rust-lang/log |
| lz4_flex | 0.10.0 | MIT | https://github.com/pseitz/lz4_flex |
| matchers | 0.2.0 | MIT | https://github.com/hawkw/matchers |
| memchr | 2.8.3 | Unlicense OR MIT | https://github.com/BurntSushi/memchr |
| minimal-lexical | 0.2.1 | MIT/Apache-2.0 | https://github.com/Alexhuszagh/minimal-lexical |
| miniz_oxide | 0.9.1 | MIT OR Zlib OR Apache-2.0 | https://github.com/Frommi/miniz_oxide/tree/master/miniz_oxide |
| mio | 1.2.5 | MIT | https://github.com/tokio-rs/mio |
| nanorand | 0.7.0 | Zlib | https://github.com/Absolucy/nanorand-rs |
| no-std-net | 0.6.0 | MIT | https://github.com/dunmatt/no-std-net |
| nom | 7.1.3 | MIT | https://github.com/Geal/nom |
| nonempty-collections | 0.3.1 | MIT | https://github.com/fosskers/nonempty-collections |
| nu-ansi-term | 0.50.3 | MIT | https://github.com/nushell/nu-ansi-term |
| num-bigint | 0.4.8 | MIT OR Apache-2.0 | https://github.com/rust-num/num-bigint |
| num-conv | 0.2.2 | MIT OR Apache-2.0 | https://github.com/jhpratt/num-conv |
| num-integer | 0.1.47 | MIT OR Apache-2.0 | https://github.com/rust-num/num-integer |
| num-traits | 0.2.19 | MIT OR Apache-2.0 | https://github.com/rust-num/num-traits |
| num_cpus | 1.17.0 | MIT OR Apache-2.0 | https://github.com/seanmonstar/num_cpus |
| object | 0.39.1 | Apache-2.0 OR MIT | https://github.com/gimli-rs/object |
| oid-registry | 0.8.1 | MIT OR Apache-2.0 | https://github.com/rusticata/oid-registry.git |
| once_cell | 1.21.4 | MIT OR Apache-2.0 | https://github.com/matklad/once_cell |
| option-ext | 0.2.0 | MPL-2.0 | https://github.com/soc/option-ext.git |
| parking | 2.2.1 | Apache-2.0 OR MIT | https://github.com/smol-rs/parking |
| paste | 1.0.15 | MIT OR Apache-2.0 | https://github.com/dtolnay/paste |
| pest | 2.9.6 | MIT OR Apache-2.0 | https://github.com/pest-parser/pest |
| pest_derive | 2.9.6 | MIT OR Apache-2.0 | https://github.com/pest-parser/pest |
| pest_generator | 2.9.6 | MIT OR Apache-2.0 | https://github.com/pest-parser/pest |
| pest_meta | 2.9.6 | MIT OR Apache-2.0 | https://github.com/pest-parser/pest |
| pest_stack_guard | 1.0.1 | MIT OR Apache-2.0 | https://github.com/pest-parser/pest_stack_guard |
| petgraph | 0.8.3 | MIT OR Apache-2.0 | https://github.com/petgraph/petgraph |
| phf | 0.13.1 | MIT | https://github.com/rust-phf/rust-phf |
| phf_generator | 0.13.1 | MIT | https://github.com/rust-phf/rust-phf |
| phf_macros | 0.13.1 | MIT | https://github.com/rust-phf/rust-phf |
| phf_shared | 0.13.1 | MIT | https://github.com/rust-phf/rust-phf |
| pin-project-lite | 0.2.18 | Apache-2.0 OR MIT | https://github.com/taiki-e/pin-project-lite |
| pnet_base | 0.35.0 | MIT OR Apache-2.0 | https://github.com/libpnet/libpnet |
| pnet_datalink | 0.35.0 | MIT OR Apache-2.0 | https://github.com/libpnet/libpnet |
| pnet_sys | 0.35.0 | MIT OR Apache-2.0 | https://github.com/libpnet/libpnet |
| portable-atomic | 1.15.0 | Apache-2.0 OR MIT | https://github.com/taiki-e/portable-atomic |
| powerfmt | 0.2.1 | MIT OR Apache-2.0 | https://github.com/jhpratt/powerfmt |
| ppv-lite86 | 0.2.21 | MIT OR Apache-2.0 | https://github.com/cryptocorrosion/cryptocorrosion |
| proc-macro-crate | 3.5.0 | MIT OR Apache-2.0 | https://github.com/bkchr/proc-macro-crate |
| proc-macro2 | 1.0.107 | MIT OR Apache-2.0 | https://github.com/dtolnay/proc-macro2 |
| psm | 0.1.32 | MIT OR Apache-2.0 | https://github.com/rust-lang/stacker/ |
| quote | 1.0.47 | MIT OR Apache-2.0 | https://github.com/dtolnay/quote |
| rand | 0.8.8 | MIT OR Apache-2.0 | https://github.com/rust-random/rand |
| rand_chacha | 0.3.1 | MIT OR Apache-2.0 | https://github.com/rust-random/rand |
| rand_core | 0.6.4 | MIT OR Apache-2.0 | https://github.com/rust-random/rand |
| ref-cast | 1.0.27 | MIT OR Apache-2.0 | https://github.com/dtolnay/ref-cast |
| ref-cast-impl | 1.0.27 | MIT OR Apache-2.0 | https://github.com/dtolnay/ref-cast |
| regex-automata | 0.4.19 | MIT OR Apache-2.0 | https://github.com/rust-lang/regex |
| regex-syntax | 0.8.12 | MIT OR Apache-2.0 | https://github.com/rust-lang/regex |
| ring | 0.17.14 | Apache-2.0 AND ISC | https://github.com/briansmith/ring |
| ringbuffer-spsc | 0.1.15 | EPL-2.0 OR Apache-2.0 | https://github.com/Mallets/ringbuffer-spsc |
| ron | 0.12.3 | MIT OR Apache-2.0 | https://github.com/ron-rs/ron |
| rustc_version | 0.4.1 | MIT OR Apache-2.0 | https://github.com/djc/rustc-version-rs |
| rusticata-macros | 4.1.0 | MIT/Apache-2.0 | https://github.com/rusticata/rusticata-macros.git |
| rustls | 0.23.46 | Apache-2.0 OR ISC OR MIT | https://github.com/rustls/rustls |
| rustls-pemfile | 2.2.0 | Apache-2.0 OR ISC OR MIT | https://github.com/rustls/pemfile |
| rustls-pki-types | 1.16.0 | MIT OR Apache-2.0 | https://github.com/rustls/pki-types |
| rustls-webpki | 0.103.17 | ISC | https://github.com/rustls/webpki |
| rustversion | 1.0.23 | MIT OR Apache-2.0 | https://github.com/dtolnay/rustversion |
| ryu | 1.0.23 | Apache-2.0 OR BSL-1.0 | https://github.com/dtolnay/ryu |
| schemars | 1.2.3 | MIT | https://github.com/GREsau/schemars |
| schemars_derive | 1.2.3 | MIT | https://github.com/GREsau/schemars |
| scopeguard | 1.2.0 | MIT OR Apache-2.0 | https://github.com/bluss/scopeguard |
| secrecy | 0.8.0 | Apache-2.0 OR MIT | https://github.com/iqlusioninc/crates/tree/main/secrecy |
| semver | 1.0.28 | MIT OR Apache-2.0 | https://github.com/dtolnay/semver |
| serde | 1.0.228 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_core | 1.0.228 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_derive | 1.0.228 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_derive_internals | 0.30.0 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_json | 1.0.154 | MIT OR Apache-2.0 | https://github.com/serde-rs/json |
| serde_norway | 0.9.42 | MIT OR Apache-2.0 | https://github.com/cafkafk/serde-yaml |
| serde_with | 3.25.0 | MIT OR Apache-2.0 | https://github.com/jonasbb/serde_with/ |
| serde_with_macros | 3.25.0 | MIT OR Apache-2.0 | https://github.com/jonasbb/serde_with/ |
| serde_yaml | 0.9.34+deprecated | MIT OR Apache-2.0 | https://github.com/dtolnay/serde-yaml |
| sha2-const-stable | 0.1.0 | MIT OR Apache-2.0 | https://github.com/saleemrashid/sha2-const |
| sha3 | 0.10.9 | MIT OR Apache-2.0 | https://github.com/RustCrypto/hashes |
| sharded-slab | 0.1.7 | MIT | https://github.com/hawkw/sharded-slab |
| shellexpand | 3.1.2 | MIT/Apache-2.0 | https://gitlab.com/ijackson/rust-shellexpand |
| shlex | 2.0.1 | MIT OR Apache-2.0 | https://github.com/comex/rust-shlex |
| simd-adler32 | 0.3.10 | MIT | https://github.com/mcountryman/simd-adler32 |
| siphasher | 1.0.4 | MIT OR Apache-2.0 | https://github.com/jedisct1/rust-siphash |
| slab | 0.4.12 | MIT | https://github.com/tokio-rs/slab |
| smallvec | 1.16.6 | MIT OR Apache-2.0 | https://github.com/smallvec/smallvec |
| socket2 | 0.5.10 | MIT OR Apache-2.0 | https://github.com/rust-lang/socket2 |
| socket2 | 0.6.5 | MIT OR Apache-2.0 | https://github.com/rust-lang/socket2 |
| spin | 0.10.1 | MIT | https://github.com/mvdnes/spin-rs.git |
| spin | 0.9.9 | MIT | https://github.com/mvdnes/spin-rs.git |
| stabby | 72.1.16 | EPL-2.0 OR Apache-2.0 | https://github.com/ZettaScaleLabs/stabby |
| stabby-abi | 72.1.16 | EPL-2.0 OR Apache-2.0 | https://github.com/ZettaScaleLabs/stabby |
| stabby-macros | 72.1.16 | EPL-2.0 OR Apache-2.0 | https://github.com/ZettaScaleLabs/stabby |
| stacker | 0.1.25 | MIT OR Apache-2.0 | https://github.com/rust-lang/stacker |
| static_assertions | 1.1.0 | MIT OR Apache-2.0 | https://github.com/nvzqz/static-assertions-rs |
| strsim | 0.11.1 | MIT | https://github.com/rapidfuzz/strsim-rs |
| subtle | 2.6.1 | BSD-3-Clause | https://github.com/dalek-cryptography/subtle |
| syn | 2.0.119 | MIT OR Apache-2.0 | https://github.com/dtolnay/syn |
| syn | 3.0.10 | MIT OR Apache-2.0 | https://github.com/dtolnay/syn |
| synstructure | 0.13.2 | MIT | https://github.com/mystor/synstructure |
| thiserror | 2.0.21 | MIT OR Apache-2.0 | https://github.com/dtolnay/thiserror |
| thiserror-impl | 2.0.21 | MIT OR Apache-2.0 | https://github.com/dtolnay/thiserror |
| thread_local | 1.1.10 | MIT OR Apache-2.0 | https://github.com/Amanieu/thread_local-rs |
| time | 0.3.55 | MIT OR Apache-2.0 | https://github.com/time-rs/time |
| time-core | 0.1.9 | MIT OR Apache-2.0 | https://github.com/time-rs/time |
| time-macros | 0.2.32 | MIT OR Apache-2.0 | https://github.com/time-rs/time |
| tls-listener | 0.11.2 | Apache-2.0 | https://github.com/tmccombs/tls-listener |
| token-cell | 2.1.1 | EPL-2.0 OR Apache-2.0 | https://github.com/p-avital/token-cell-rs |
| tokio | 1.54.1 | MIT | https://github.com/tokio-rs/tokio |
| tokio-macros | 2.7.2 | MIT | https://github.com/tokio-rs/tokio |
| tokio-rustls | 0.26.6 | MIT OR Apache-2.0 | https://github.com/rustls/tokio-rustls |
| tokio-util | 0.7.20 | MIT | https://github.com/tokio-rs/tokio |
| toml_datetime | 1.1.3+spec-1.1.0 | MIT OR Apache-2.0 | https://github.com/toml-rs/toml |
| toml_edit | 0.25.19+spec-1.1.0 | MIT OR Apache-2.0 | https://github.com/toml-rs/toml |
| toml_parser | 1.1.5+spec-1.1.0 | MIT OR Apache-2.0 | https://github.com/toml-rs/toml |
| tracing | 0.1.44 | MIT | https://github.com/tokio-rs/tracing |
| tracing-attributes | 0.1.31 | MIT | https://github.com/tokio-rs/tracing |
| tracing-core | 0.1.36 | MIT | https://github.com/tokio-rs/tracing |
| tracing-log | 0.2.0 | MIT | https://github.com/tokio-rs/tracing |
| tracing-serde | 0.2.0 | MIT | https://github.com/tokio-rs/tracing |
| tracing-subscriber | 0.3.23 | MIT | https://github.com/tokio-rs/tracing |
| twox-hash | 1.6.3 | MIT | https://github.com/shepmaster/twox-hash |
| typeid | 1.0.3 | MIT OR Apache-2.0 | https://github.com/dtolnay/typeid |
| typenum | 1.20.1 | MIT OR Apache-2.0 | https://github.com/paholg/typenum |
| ucd-trie | 0.1.8 | MIT OR Apache-2.0 | https://github.com/BurntSushi/ucd-generate |
| uhlc | 0.8.2 | EPL-2.0 OR Apache-2.0 | https://github.com/atolab/uhlc-rs |
| unicode-ident | 1.0.27 | (MIT OR Apache-2.0) AND Unicode-3.0 | https://github.com/dtolnay/unicode-ident |
| unicode-xid | 0.2.6 | MIT OR Apache-2.0 | https://github.com/unicode-rs/unicode-xid |
| unsafe-libyaml | 0.2.11 | MIT | https://github.com/dtolnay/unsafe-libyaml |
| unsafe-libyaml-norway | 0.2.15 | MIT | https://github.com/cafkafk/unsafe-libyaml-norway |
| untrusted | 0.9.0 | ISC | https://github.com/briansmith/untrusted |
| unzip-n | 0.1.4 | MIT OR Apache-2.0 | https://github.com/mexus/unzip-n |
| validated_struct | 2.2.0 | EPL-2.0 OR Apache-2.0 | https://github.com/p-avital/validated-struct-rs |
| validated_struct_macros | 2.2.0 | EPL-2.0 OR Apache-2.0 | https://github.com/p-avital/validated-struct-macros-rs |
| vec_map | 0.8.2 | MIT/Apache-2.0 | https://github.com/contain-rs/vec-map |
| version_check | 0.9.5 | MIT/Apache-2.0 | https://github.com/SergioBenitez/version_check |
| webpki-roots | 1.0.12 | CDLA-Permissive-2.0 | https://github.com/rustls/webpki-roots |
| winnow | 1.0.5 | MIT | https://github.com/winnow-rs/winnow |
| x509-parser | 0.18.1 | MIT OR Apache-2.0 | https://github.com/rusticata/x509-parser.git |
| zenoh | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-buffers | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-codec | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-collections | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-config | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-core | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-crypto | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-keyexpr | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-link | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-link-commons | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-link-tcp | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-link-tls | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-macros | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-plugin-trait | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-protocol | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-result | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-runtime | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-sync | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-task | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-transport | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zenoh-util | 1.9.0 | EPL-2.0 OR Apache-2.0 | https://github.com/eclipse-zenoh/zenoh |
| zerocopy | 0.8.63 | BSD-2-Clause OR Apache-2.0 OR MIT | https://github.com/google/zerocopy |
| zeroize | 1.9.2 | Apache-2.0 OR MIT | https://github.com/RustCrypto/utils |
| zmij | 1.0.23 | MIT | https://github.com/dtolnay/zmij |

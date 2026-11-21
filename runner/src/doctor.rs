//! `goat-processors doctor`: reads the host and the service and reports what
//! is wrong. It changes nothing.

use std::collections::BTreeMap;
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::process::Command;
use std::time::Duration;

use crate::json::{self, Json};

use crate::config::{self, Config};

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Ok,
    Warn,
    Fail,
}

impl Level {
    fn name(self) -> &'static str {
        match self {
            Level::Ok => "ok",
            Level::Warn => "warn",
            Level::Fail => "FAIL",
        }
    }
}

pub struct Finding {
    pub check: String,
    pub level: Level,
    pub detail: String,
    pub fix: String,
}

fn f(check: &str, level: Level, detail: impl Into<String>, fix: impl Into<String>) -> Finding {
    Finding { check: check.into(), level, detail: detail.into(), fix: fix.into() }
}

pub const SERVICE: &str = "goat-processors";

pub fn run(config_path: &Path) -> Vec<Finding> {
    let mut out = Vec::new();
    let c = match config::load(config_path) {
        Ok(c) => {
            out.push(f("config", Level::Ok, format!("{} is valid", config_path.display()), ""));
            for w in config::warnings(&c) {
                out.push(f("config", Level::Warn, w, format!("edit {}, then restart the service", config_path.display())));
            }
            for s in &c.pipeline {
                out.push(f("pack", Level::Ok, format!("{} pack {} loads from {}", s.function, s.pack, c.pack_dir(s).display()), ""));
            }
            c
        }
        Err(problems) => {
            for p in problems {
                out.push(f("config", Level::Fail, p, format!("edit {}, then run `goat-processors config check`", config_path.display())));
            }
            // Without a config only the service can still be checked.
            out.extend(service_checks(None));
            return out;
        }
    };
    out.extend(certificate_checks(&c));
    out.extend(fabric_checks(&c));
    out.extend(file_checks(&c));
    out.extend(c.api.mesh.as_ref().and_then(|m| m.crl.as_deref()).and_then(crl_check));
    out.extend(service_checks(Some(&c)));
    out
}

fn certificate_checks(c: &Config) -> Vec<Finding> {
    let mut out = Vec::new();
    let Some(tls) = c.fabric.as_ref().and_then(|f| f.tls.as_ref()) else {
        if c.fabric.is_some() {
            out.push(f("certificates", Level::Warn, "the fabric section has no tls: the connection is not encrypted", "add fabric.tls with root_ca, certificate and private_key for a mesh connection"));
        }
        return out;
    };
    let user = service_user();
    for (what, path, marker) in [
        ("root_ca", &tls.root_ca, "-----BEGIN CERTIFICATE-----"),
        ("certificate", &tls.certificate, "-----BEGIN CERTIFICATE-----"),
        ("private_key", &tls.private_key, "PRIVATE KEY-----"),
    ] {
        let check = format!("certificates: {what}");
        let place = format!(
            "sudo install -m 0640 -g {SERVICE} <the file> {} (INSTALL.md, step 5)",
            path.display()
        );
        let text = match std::fs::read_to_string(path) {
            Err(e) => {
                out.push(f(&check, Level::Fail, format!("{} cannot be read ({e})", path.display()), place));
                continue;
            }
            Ok(t) => t,
        };
        if !text.contains(marker) {
            out.push(f(&check, Level::Fail, format!("{} is not a PEM file", path.display()), "copy the PEM form of the file, whose first line starts with -----BEGIN"));
            continue;
        }
        // The service reads the file as its own user, not as whoever runs doctor.
        if let Some(u) = &user {
            if let Err(why) = readable_by(path, u) {
                out.push(f(&check, Level::Fail, format!("the service user {SERVICE} cannot read {}: {why}", path.display()), place));
                continue;
            }
        }
        match parses(what, path) {
            Some(false) => {
                out.push(f(&check, Level::Fail, format!("{} does not parse", path.display()), "ask the site's certificate authority for the file again, in PEM form"));
                continue;
            }
            _ => {}
        }
        let detail = if user.is_some() { format!("{} is readable by the service and parses", path.display()) } else { format!("{} is present", path.display()) };
        out.push(f(&check, Level::Ok, detail, ""));
        if what == "private_key" {
            out.extend(key_mode(path));
        } else {
            out.extend(expiry(&check, path));
        }
    }
    out
}

/// The service user's uid, primary gid and every group it is in, from
/// /etc/passwd and /etc/group. None when the user does not exist (not installed).
pub struct User {
    uid: u32,
    gids: Vec<u32>,
}

fn service_user() -> Option<User> {
    let passwd = std::fs::read_to_string("/etc/passwd").ok()?;
    let line = passwd.lines().find(|l| l.split(':').next() == Some(SERVICE))?;
    let fields: Vec<&str> = line.split(':').collect();
    let uid = fields.get(2)?.parse().ok()?;
    let mut gids = vec![fields.get(3)?.parse().ok()?];
    if let Ok(group) = std::fs::read_to_string("/etc/group") {
        for l in group.lines() {
            let g: Vec<&str> = l.split(':').collect();
            if g.len() >= 4 && g[3].split(',').any(|m| m == SERVICE) {
                if let Ok(id) = g[2].parse() {
                    gids.push(id);
                }
            }
        }
    }
    Some(User { uid, gids })
}

/// Whether `user` may read `path`: execute on every directory above it, read on the file.
#[cfg(unix)]
fn readable_by(path: &Path, user: &User) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    let allowed = |m: &std::fs::Metadata, bit: u32| -> bool {
        let mode = m.mode();
        if user.uid == 0 {
            return true;
        }
        if m.uid() == user.uid {
            mode & (bit << 6) != 0
        } else if user.gids.contains(&m.gid()) {
            mode & (bit << 3) != 0
        } else {
            mode & bit != 0
        }
    };
    let mut dirs: Vec<&Path> = path.ancestors().skip(1).filter(|p| !p.as_os_str().is_empty()).collect();
    dirs.reverse();
    for d in dirs {
        let m = std::fs::metadata(d).map_err(|e| format!("{}: {e}", d.display()))?;
        if !allowed(&m, 0o1) {
            return Err(format!("the directory {} is closed to it (owner {}, group {}, mode {:o})", d.display(), m.uid(), m.gid(), m.mode() & 0o777));
        }
    }
    let m = std::fs::metadata(path).map_err(|e| e.to_string())?;
    if !allowed(&m, 0o4) {
        return Err(format!("owner {}, group {}, mode {:o}; it needs group {SERVICE} and mode 0640", m.uid(), m.gid(), m.mode() & 0o777));
    }
    Ok(())
}

#[cfg(not(unix))]
fn readable_by(_: &Path, _: &User) -> Result<(), String> {
    Ok(())
}

/// Whether the file reads as a certificate (every one in it) or a private
/// key, with the same libraries the service uses: no openssl needed, so the
/// check also runs in the container image.
fn parses(what: &str, path: &Path) -> Option<bool> {
    use rustls_pki_types::pem::PemObject;
    if what == "private_key" {
        return Some(rustls_pki_types::PrivateKeyDer::from_pem_file(path).is_ok());
    }
    Some(certificates(path).is_some_and(|c| !c.is_empty() && c.iter().all(|d| x509_parser::parse_x509_certificate(d.as_ref()).is_ok())))
}

fn certificates(path: &Path) -> Option<Vec<rustls_pki_types::CertificateDer<'static>>> {
    use rustls_pki_types::pem::PemObject;
    rustls_pki_types::CertificateDer::pem_file_iter(path).ok()?.collect::<Result<Vec<_>, _>>().ok()
}

#[cfg(unix)]
fn key_mode(path: &Path) -> Option<Finding> {
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(path).ok()?.permissions().mode();
    (mode & 0o007 != 0).then(|| f("certificates: private_key", Level::Warn, format!("{} can be read by every user (mode {:o})", path.display(), mode & 0o777), format!("sudo chmod 0640 {}", path.display())))
}

/// The earliest end date of the certificates in the file: a warning within
/// 14 days, a failure once it has passed.
fn expiry(check: &str, path: &Path) -> Option<Finding> {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64;
    let end = certificates(path)?
        .iter()
        .filter_map(|d| x509_parser::parse_x509_certificate(d.as_ref()).ok().map(|(_, x)| x.validity().not_after.timestamp()))
        .min()?;
    let fix = "request a new certificate for this runner from the site's certificate authority";
    if end <= now {
        Some(f(check, Level::Fail, format!("{} has expired", path.display()), fix))
    } else if end - now <= 14 * 86_400 {
        Some(f(check, Level::Warn, format!("{} expires within 14 days", path.display()), fix))
    } else {
        None
    }
}

fn fabric_checks(c: &Config) -> Vec<Finding> {
    let mut out = Vec::new();
    let Some(fab) = &c.fabric else { return out };
    for loc in &fab.connect {
        let Ok((proto, host, port)) = config::parse_locator(loc) else { continue };
        if proto == "quic" {
            out.push(f("fabric", Level::Warn, format!("{loc}: doctor cannot test a QUIC locator"), ""));
            continue;
        }
        let addrs: Vec<_> = match (host.as_str(), port).to_socket_addrs() {
            Ok(a) => a.collect(),
            Err(e) => {
                out.push(f("fabric", Level::Fail, format!("{loc}: the name {host} does not resolve ({e})"), "check the router name in fabric.connect, and this host's DNS or /etc/hosts"));
                continue;
            }
        };
        let reached = addrs.iter().any(|a| TcpStream::connect_timeout(a, Duration::from_secs(3)).is_ok());
        if reached {
            out.push(f("fabric", Level::Ok, format!("{loc}: TCP port open (the TLS handshake is tested by the service)"), ""));
        } else {
            out.push(f("fabric", Level::Fail, format!("{loc}: no TCP connection within 3 s"), "check that the router runs, that the mesh is up on this host, and that no firewall blocks the port"));
        }
    }
    out.extend(output_peer_check(c));
    out
}

/// The output prefix `volatile/<peer>/...` is writable only when `<peer>` is
/// the identity the fabric grants this runner, which is usually its
/// certificate's common name. A router drops a write it does not allow
/// without telling the writer, so say so here.
pub fn output_peer_check(c: &Config) -> Option<Finding> {
    c.outputs.fabric.as_ref()?;
    let prefix = c.output_prefix();
    let peer = prefix.strip_prefix("volatile/")?.split('/').next()?.to_string();
    let certs = c.fabric.as_ref()?.tls.as_ref().and_then(|t| certificates(&t.certificate)).unwrap_or_default();
    let cn = certs.first().and_then(|d| {
        let (_, x) = x509_parser::parse_x509_certificate(d.as_ref()).ok()?;
        let cn = x.subject().iter_common_name().next()?.as_str().ok()?.to_string();
        Some(cn)
    });
    Some(match cn {
        Some(cn) if cn == peer => f("output prefix", Level::Ok, format!("publishes under {prefix}; the certificate's name is {cn}"), ""),
        // peer not set: it is the site only by default, which is wrong for
        // this certificate (typically a config kept from 0.5.0). Set by hand
        // to another name: the operator chose it, so warn.
        Some(cn) => {
            let chosen = c.outputs.fabric.as_ref().is_some_and(|f| f.peer.is_some());
            f(
                "output prefix",
                if chosen { Level::Warn } else { Level::Fail },
                format!("publishes under {prefix}, but the certificate's name is {cn}: a fabric that grants this runner writes only under volatile/{cn}/** drops, without an error, everything it publishes, and readers see nothing"),
                format!("add `peer: {cn}` under outputs: fabric: in the config (or the identity the fabric's access rules grant this runner), then `sudo systemctl restart goat-processors`"),
            )
        }
        None => f("output prefix", Level::Ok, format!("publishes under {prefix}"), ""),
    })
}

/// Reads the status file the service writes after every tick.
/// `api.mesh.crl`: it must read as a revocation list; one past its next
/// update still applies, but the CA has likely issued a newer one.
fn crl_check(path: &Path) -> Option<Finding> {
    use rustls_pki_types::pem::PemObject;
    let check = "certificates: api.mesh.crl";
    let fix = "copy the CA's current revocation list (PEM) to the path in api.mesh.crl; the service reads it again on its own";
    let ders = rustls_pki_types::CertificateRevocationListDer::pem_file_iter(path).ok().and_then(|i| i.collect::<Result<Vec<_>, _>>().ok()).unwrap_or_default();
    let lists: Vec<_> = ders.iter().filter_map(|d| x509_parser::parse_x509_crl(d.as_ref()).ok().map(|(_, c)| c)).collect();
    if lists.is_empty() || lists.len() != ders.len() {
        return Some(f(check, Level::Fail, format!("{} does not read as a certificate revocation list (PEM)", path.display()), fix));
    }
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64;
    if lists.iter().any(|c| c.next_update().is_some_and(|t| t.timestamp() < now)) {
        return Some(f(check, Level::Warn, format!("{} is past its next update; the CA has likely issued a newer list", path.display()), fix));
    }
    let revoked: usize = lists.iter().map(|c| c.iter_revoked_certificates().count()).sum();
    Some(f(check, Level::Ok, format!("{} reads; it revokes {revoked} certificate(s)", path.display()), ""))
}

/// A file the service appends to without a size limit that has grown past
/// 1 GiB, and a disk holding one of those files that is 90% full or more.
fn file_checks(c: &Config) -> Vec<Finding> {
    let mut files: Vec<(&Path, Option<u64>, &str)> = vec![(&c.api.audit_file, c.api.audit_max_mb, "api.audit_max_mb")];
    if let Some(f) = &c.outputs.file {
        files.push((&f.path, f.max_mb, "outputs.file.max_mb"));
    }
    if let Some(r) = &c.record {
        files.push((&r.path, r.max_mb, "record.max_mb"));
    }
    let mut out = Vec::new();
    let mut disks_seen = Vec::new();
    for (path, max, key) in files {
        let Ok(m) = std::fs::metadata(path) else { continue };
        if max.is_none() && m.len() > 1 << 30 {
            out.push(f("files", Level::Warn, format!("{} is {} MiB and has no size limit", path.display(), m.len() >> 20), format!("set {key} (and how many copies to keep) in the config, then restart the service")));
        }
        if let Some((mount, pct)) = disk_use(path) {
            if pct >= 90 && !disks_seen.contains(&mount) {
                out.push(f("files", Level::Warn, format!("the disk holding {} ({mount}) is {pct}% full", path.display()), "free space there, or set size limits on the files the service writes (max_mb)"));
                disks_seen.push(mount);
            }
        }
    }
    out
}

/// The mount point and percentage used of the disk holding `path`, from
/// `df`. None where `df` is missing (the container image).
fn disk_use(path: &Path) -> Option<(String, u32)> {
    let o = Command::new("df").args(["--output=target,pcent"]).arg(path).output().ok()?;
    let text = String::from_utf8_lossy(&o.stdout);
    let line = text.lines().nth(1)?;
    let mut parts = line.split_whitespace();
    let (target, pct) = (parts.next()?, parts.next()?);
    Some((target.to_string(), pct.trim_end_matches('%').parse().ok()?))
}

pub fn read_status(path: &Path) -> Option<Json> {
    json::parse(&std::fs::read_to_string(path).ok()?).ok()
}

fn service_checks(c: Option<&Config>) -> Vec<Finding> {
    let mut out = Vec::new();
    if let Ok(o) = Command::new("systemctl").args(["is-active", SERVICE]).output() {
        let state = String::from_utf8_lossy(&o.stdout).trim().to_string();
        if state == "active" {
            out.push(f("service", Level::Ok, "systemd reports the service active", ""));
        } else if state == "activating" {
            out.push(f("service", Level::Fail, "systemd reports the service activating: it failed and systemd is restarting it", format!("sudo journalctl -u {SERVICE} -n 50 shows why it failed")));
        } else if !state.is_empty() {
            out.push(f("service", Level::Fail, format!("systemd reports the service {state}"), format!("sudo journalctl -u {SERVICE} -n 50 shows why it stopped; after the fix, sudo systemctl restart {SERVICE}")));
        }
    }
    let Some(c) = c else { return out };
    let Some(st) = read_status(&c.status_file) else {
        out.push(f("service", Level::Fail, format!("no status at {}", c.status_file.display()), format!("the service writes it after its first tick; check sudo journalctl -u {SERVICE} -n 50")));
        return out;
    };
    let int = |k: &str| st.get(k).and_then(|v| v.as_i64());
    let age = int("written_ms").map(|w| crate::service::wall_ms() - w);
    let limit = 3 * c.tick_ms + 5000;
    match age {
        Some(a) if c.clock == config::Clock::Wall && a > limit => out.push(f("service", Level::Fail, format!("the status is {} s old: the service is not ticking", a / 1000), format!("sudo systemctl restart {SERVICE}; sudo journalctl -u {SERVICE} -n 50"))),
        Some(a) => out.push(f("service", Level::Ok, format!("ticking; status written {} ms ago", a.max(0)), "")),
        None => out.push(f("service", Level::Fail, "the status file has no written_ms", "the status file is damaged; restart the service")),
    }
    let counters = st.get("counters");
    let cnt = |k: &str| counters.and_then(|m| m.get(k)).and_then(|v| v.as_i64()).unwrap_or(0);
    if c.fabric.is_some() && c.outputs.fabric.is_some() {
        match int("fabric_routers") {
            Some(0) => out.push(f("fabric", Level::Fail, "the service is connected to no router", format!("check fabric.connect and the certificate lines above (readable by the service, signed by the router's CA); sudo journalctl -u {SERVICE} -n 50 shows the TLS error"))),
            Some(n) => out.push(f("fabric", Level::Ok, format!("the service is connected to {n} router(s)"), "")),
            None => {}
        }
    }
    let rin = cnt("reports_in");
    if rin == 0 {
        out.push(f("input", Level::Warn, "no report read yet", "check inputs.fabric.keys against what the site publishes, for example with the fabric's own tools"));
    } else {
        out.push(f("input", Level::Ok, format!("{rin} reports read, {} passed every stage", cnt("reports_out")), ""));
    }
    let journal = format!("sudo journalctl -u {SERVICE} names the first ones");
    let behind = "the inputs sent faster than the pipeline ran: check the host's load, and the rate of the sources (goat-processors metrics)".to_string();
    for (k, why, fix) in [
        ("unreadable", "inputs that were not a report, or held a value out of range", &journal),
        ("output_errors", "outputs that could not be written or published", &journal),
        ("dropped_backlog", "reports dropped because the service was behind its inputs", &behind),
    ] {
        let n = cnt(k);
        if n > 0 {
            out.push(f("service", Level::Warn, format!("{n} {why}"), fix.clone()));
        }
    }
    if c.api.enabled {
        match crate::http::call(&c.api.listen, "GET", "/v1/health", None, None) {
            Ok((200, _)) => out.push(f("api", Level::Ok, format!("the API answers on {}", c.api.listen), "")),
            Ok((503, b)) => {
                let detail = json::parse(&String::from_utf8_lossy(&b)).ok().and_then(|v| v.get("detail").and_then(|d| d.as_str()).map(str::to_string)).unwrap_or_default();
                let fix = if detail.starts_with("paused") { "sudo goat-processors start".to_string() } else { format!("sudo journalctl -u {SERVICE} -n 50") };
                out.push(f("api", Level::Fail, format!("the API says the service is not healthy: {detail}"), fix));
            }
            Ok((code, _)) => out.push(f("api", Level::Warn, format!("the API answered {code} on /v1/health"), format!("sudo journalctl -u {SERVICE} -n 50"))),
            Err(e) => out.push(f("api", Level::Fail, format!("the API does not answer on {}: {e}", c.api.listen), format!("sudo systemctl restart {SERVICE}; sudo journalctl -u {SERVICE} -n 50"))),
        }
    }
    let pipeline_now: Vec<(String, String)> = match st.get("pipeline") {
        Some(Json::Arr(v)) => v.iter().filter_map(|s| Some((s.get("function")?.as_str()?.to_string(), s.get("pack")?.as_str()?.to_string()))).collect(),
        _ => vec![],
    };
    let want: Vec<(String, String)> = c.pipeline.iter().map(|s| (s.function.clone(), s.pack.clone())).collect();
    if pipeline_now != want {
        out.push(f("service", Level::Warn, "the running pipeline differs from the config file", format!("sudo systemctl restart {SERVICE} to apply the file")));
    }
    out
}

pub fn worst(findings: &[Finding]) -> Level {
    findings.iter().map(|x| x.level).max().unwrap_or(Level::Ok)
}

pub fn to_json(findings: &[Finding]) -> Json {
    Json::Arr(
        findings
            .iter()
            .map(|x| {
                let mut m = BTreeMap::new();
                m.insert("check".into(), Json::Str(x.check.clone()));
                m.insert("level".into(), Json::Str(x.level.name().to_lowercase()));
                m.insert("detail".into(), Json::Str(x.detail.clone()));
                m.insert("fix".into(), Json::Str(x.fix.clone()));
                Json::Obj(m)
            })
            .collect(),
    )
}

pub fn to_text(findings: &[Finding]) -> String {
    let mut s = String::new();
    for x in findings {
        s.push_str(&format!("{:<4}  {:<26} {}\n", x.level.name(), x.check, x.detail));
        if !x.fix.is_empty() && x.level != Level::Ok {
            s.push_str(&format!("      {:<26} fix: {}\n", "", x.fix));
        }
    }
    let w = worst(findings);
    s.push_str(match w {
        Level::Ok => "\nhealthy\n",
        Level::Warn => "\nrunning, with warnings\n",
        Level::Fail => "\nNOT HEALTHY: fix each FAIL line above, then run doctor again\n",
    });
    s
}

#[cfg(test)]
mod certificate_tests {
    use super::*;

    // Test certificates, made once with openssl and kept here so the test
    // needs no openssl: one that ended on 2 January 2020, one valid to 2099.
    const ENDED: &str = "-----BEGIN CERTIFICATE-----
MIIBgzCCASmgAwIBAgIUe4HkrnGj9vnrIxP/4WJAOXjDNoswCgYIKoZIzj0EAwIw
FzEVMBMGA1UEAwwMZXhwaXJlZC10ZXN0MB4XDTIwMDEwMTAwMDAwMFoXDTIwMDEw
MjAwMDAwMFowFzEVMBMGA1UEAwwMZXhwaXJlZC10ZXN0MFkwEwYHKoZIzj0CAQYI
KoZIzj0DAQcDQgAERN2bzn0XDxIFLJd+4OJVvlcVYOn14n8OZDDGt77LNSPBYo7c
3vrCsYbRID/T9AJWemKafdb5XepuRzzMUi8v6aNTMFEwHQYDVR0OBBYEFGi9UihO
pW0GYa7LG57JB03Y750OMB8GA1UdIwQYMBaAFGi9UihOpW0GYa7LG57JB03Y750O
MA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIgZp43aCp93AR9khB9
bntIc0kteRRurHPz2lY7r8G6O3cCIQD3CREwhBierDan5IsBpP346I2ZDJ0W5vgX
8DdtP6tB3g==
-----END CERTIFICATE-----\n";
    const VALID: &str = "-----BEGIN CERTIFICATE-----
MIIBgjCCASegAwIBAgIUdU0eS2vzi4PBlVPsgIeWavr8aHQwCgYIKoZIzj0EAwIw
FTETMBEGA1UEAwwKdmFsaWQtdGVzdDAgFw0yNTAxMDEwMDAwMDBaGA8yMDk5MTIz
MTAwMDAwMFowFTETMBEGA1UEAwwKdmFsaWQtdGVzdDBZMBMGByqGSM49AgEGCCqG
SM49AwEHA0IABETdm859Fw8SBSyXfuDiVb5XFWDp9eJ/DmQwxre+yzUjwWKO3N76
wrGG0SA/0/QCVnpimn3W+V3qbkc8zFIvL+mjUzBRMB0GA1UdDgQWBBRovVIoTqVt
BmGuyxueyQdN2O+dDjAfBgNVHSMEGDAWgBRovVIoTqVtBmGuyxueyQdN2O+dDjAP
BgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQDRUP24505QTQrGdYuP
G5zlVOH0KpWH97n+C6srELNv1QIhANEgDVBNPe07tgMKWsNyhfoHrSEwiayBjwRM
q5EKZ2Py
-----END CERTIFICATE-----\n";

    fn file(name: &str, text: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("doctor-cert-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let p = d.join(name);
        std::fs::write(&p, text).unwrap();
        p
    }

    #[test]
    fn certificates_are_read_without_openssl() {
        let (ended, valid) = (file("ended.pem", ENDED), file("valid.pem", VALID));
        let bad = file("bad.pem", "-----BEGIN CERTIFICATE-----\nbm90IGEgY2VydGlmaWNhdGU=\n-----END CERTIFICATE-----\n");
        assert_eq!(parses("certificate", &valid), Some(true));
        assert_eq!(parses("certificate", &bad), Some(false));
        assert_eq!(parses("private_key", &valid), Some(false));
        assert!(expiry("certificates: certificate", &valid).is_none());
        let e = expiry("certificates: certificate", &ended).expect("an ended certificate is reported");
        assert!(matches!(e.level, Level::Fail), "{:?}", e.detail);
        assert!(e.detail.contains("has expired"));
    }
}

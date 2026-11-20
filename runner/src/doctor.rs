//! `goat-processors doctor`: reads the host and the service and reports what
//! is wrong. It changes nothing.

use std::collections::BTreeMap;
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::process::Command;
use std::time::Duration;

use goat_correlator::json::{self, Json};

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
                out.push(f(&check, Level::Fail, format!("{} does not parse (openssl cannot read it)", path.display()), "ask the site's certificate authority for the file again, in PEM form"));
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

/// Whether openssl reads the file as a certificate or a private key. None without openssl.
fn parses(what: &str, path: &Path) -> Option<bool> {
    let args: &[&str] = if what == "private_key" { &["pkey", "-noout", "-in"] } else { &["x509", "-noout", "-in"] };
    let out = Command::new("openssl").args(args).arg(path).output().ok()?;
    Some(out.status.success())
}

#[cfg(unix)]
fn key_mode(path: &Path) -> Option<Finding> {
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(path).ok()?.permissions().mode();
    (mode & 0o007 != 0).then(|| f("certificates: private_key", Level::Warn, format!("{} can be read by every user (mode {:o})", path.display(), mode & 0o777), format!("sudo chmod 0640 {}", path.display())))
}

/// Uses `openssl`, when the host has it, to read the certificate's end date.
fn expiry(check: &str, path: &Path) -> Option<Finding> {
    let out = Command::new("openssl").args(["x509", "-noout", "-checkend", "1209600", "-in"]).arg(path).output().ok()?;
    if out.status.success() {
        return None;
    }
    let ended = Command::new("openssl").args(["x509", "-noout", "-checkend", "0", "-in"]).arg(path).output().ok()?;
    Some(if ended.status.success() {
        f(check, Level::Warn, format!("{} expires within 14 days", path.display()), "request a new certificate for this runner from the site's certificate authority")
    } else {
        f(check, Level::Fail, format!("{} has expired, or openssl cannot read it", path.display()), "request a new certificate for this runner from the site's certificate authority")
    })
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
    out
}

/// Reads the status file the service writes after every tick.
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
    for (k, why) in [("unreadable", "inputs that were not a report"), ("output_errors", "outputs that could not be written or published")] {
        let n = cnt(k);
        if n > 0 {
            out.push(f("service", Level::Warn, format!("{n} {why}"), format!("sudo journalctl -u {SERVICE} names the first ones")));
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
                m.insert("check".to_string(), Json::Str(x.check.clone()));
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

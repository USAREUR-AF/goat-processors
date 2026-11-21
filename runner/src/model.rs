//! Calls to a model endpoint (agents.endpoints): an OpenAI-compatible chat
//! completions request over http or https, after the data-level check.
//!
//! The check: every call names the data level of what it sends. The runner
//! picks an endpoint whose declared level is at least that level, and refuses
//! the call when there is none. Nothing is sent to an endpoint declared for a
//! lower level.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

use crate::json::{self, Json};

use crate::config::{Agents, Endpoint};

/// The endpoint a call at `level` may use: the first one listed whose
/// declared level is at least `level`; `name` restricts it to one endpoint.
pub fn choose<'a>(agents: &'a Agents, level: &str, name: Option<&str>) -> Result<&'a Endpoint, String> {
    let need = agents.rank(level).ok_or_else(|| format!("{level:?} is not a data level of this site ({})", agents.data_levels.join(", ")))?;
    let candidates: Vec<&Endpoint> = agents.endpoints.iter().filter(|e| name.map_or(true, |n| e.name == n)).collect();
    if candidates.is_empty() {
        return Err(match name {
            Some(n) => format!("no model endpoint named {n:?} in agents.endpoints"),
            None => "no model endpoint is configured (agents.endpoints)".into(),
        });
    }
    candidates
        .iter()
        .find(|e| agents.rank(&e.data_level).is_some_and(|r| r >= need))
        .copied()
        .ok_or_else(|| {
            format!(
                "refused: this call sends {level} data, and no endpoint{} is declared for it ({})",
                name.map(|n| format!(" named {n:?}")).unwrap_or_default(),
                candidates.iter().map(|e| format!("{}: {}", e.name, e.data_level)).collect::<Vec<_>>().join(", ")
            )
        })
}

struct Url {
    tls: bool,
    host: String,
    port: u16,
    path: String,
}

fn parse_url(u: &str) -> Result<Url, String> {
    let (tls, rest) = if let Some(r) = u.strip_prefix("https://") {
        (true, r)
    } else if let Some(r) = u.strip_prefix("http://") {
        (false, r)
    } else {
        return Err(format!("{u}: not an http or https URL"));
    };
    let (hostport, path) = rest.split_once('/').map(|(h, p)| (h, format!("/{p}"))).unwrap_or((rest, "/".into()));
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) if !h.ends_with(']') || h.starts_with('[') => (h.trim_matches(|c| c == '[' || c == ']').to_string(), p.parse().map_err(|_| format!("{u}: bad port"))?),
        _ => (hostport.to_string(), if tls { 443 } else { 80 }),
    };
    Ok(Url { tls, host, port, path })
}

fn tls_client(e: &Endpoint) -> Result<Arc<rustls::ClientConfig>, String> {
    use rustls_pki_types::pem::PemObject;
    use rustls_pki_types::CertificateDer;
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    if let Some(ca) = &e.ca_file {
        for c in CertificateDer::pem_file_iter(ca).map_err(|x| format!("{}: {x}", ca.display()))? {
            roots.add(c.map_err(|x| format!("{}: {x}", ca.display()))?).map_err(|x| x.to_string())?;
        }
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let cfg = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|x| x.to_string())?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(Arc::new(cfg))
}

/// One POST of a JSON body; returns the status and the response body.
pub fn post_json(e: &Endpoint, body: &str) -> Result<(u16, String), String> {
    let u = parse_url(&e.url)?;
    let addrs: Vec<_> = (u.host.as_str(), u.port).to_socket_addrs().map_err(|x| format!("{}: {x}", e.url))?.collect();
    let timeout = Duration::from_millis(e.timeout_ms);
    // A name may resolve to several addresses (IPv6 and IPv4): try each in turn.
    let mut last = String::from("no address");
    let mut tcp = None;
    for a in &addrs {
        match TcpStream::connect_timeout(a, timeout) {
            Ok(t) => {
                tcp = Some(t);
                break;
            }
            Err(x) => last = x.to_string(),
        }
    }
    let tcp = tcp.ok_or_else(|| format!("cannot reach the model endpoint {} ({}): {last}", e.name, e.url))?;
    tcp.set_read_timeout(Some(timeout)).ok();
    tcp.set_write_timeout(Some(timeout)).ok();
    let key = match &e.key_file {
        Some(k) => Some(std::fs::read_to_string(k).map_err(|x| format!("{}: {x}", k.display()))?.trim().to_string()),
        None => None,
    };
    let mut req = format!(
        "POST {} HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n",
        u.path,
        u.host,
        body.len()
    );
    if let Some(k) = key {
        req.push_str(&format!("Authorization: Bearer {k}\r\n"));
    }
    req.push_str("\r\n");
    req.push_str(body);
    let mut raw = Vec::new();
    if u.tls {
        let name = rustls_pki_types::ServerName::try_from(u.host.clone()).map_err(|x| x.to_string())?;
        let conn = rustls::ClientConnection::new(tls_client(e)?, name).map_err(|x| x.to_string())?;
        let mut s = rustls::StreamOwned::new(conn, tcp);
        s.write_all(req.as_bytes()).map_err(|x| format!("send to {}: {x}", e.name))?;
        match s.read_to_end(&mut raw) {
            Ok(_) => {}
            // A server that closes without close_notify still sent its whole reply.
            Err(x) if x.kind() == std::io::ErrorKind::UnexpectedEof && !raw.is_empty() => {}
            Err(x) => return Err(format!("read from {}: {x}", e.name)),
        }
    } else {
        let mut s = tcp;
        s.write_all(req.as_bytes()).map_err(|x| format!("send to {}: {x}", e.name))?;
        s.read_to_end(&mut raw).map_err(|x| format!("read from {}: {x}", e.name))?;
    }
    let end = raw.windows(4).position(|w| w == b"\r\n\r\n").ok_or("the model's reply has no header end")?;
    let head = String::from_utf8_lossy(&raw[..end]).to_string();
    let status = head.split(' ').nth(1).and_then(|c| c.parse().ok()).ok_or("the model's reply has no status")?;
    let mut body = raw[end + 4..].to_vec();
    if head.to_ascii_lowercase().contains("transfer-encoding: chunked") {
        body = dechunk(&body);
    }
    Ok((status, String::from_utf8_lossy(&body).to_string()))
}

fn dechunk(b: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(nl) = b[i..].windows(2).position(|w| w == b"\r\n") {
        let size = usize::from_str_radix(String::from_utf8_lossy(&b[i..i + nl]).trim(), 16).unwrap_or(0);
        i += nl + 2;
        if size == 0 || i + size > b.len() {
            break;
        }
        out.extend_from_slice(&b[i..i + size]);
        i += size + 2;
    }
    out
}

/// A chat request with one system and one user message; returns the reply text.
pub fn chat(e: &Endpoint, system: &str, user: &str) -> Result<String, String> {
    let mut msgs = Vec::new();
    for (role, content) in [("system", system), ("user", user)] {
        let mut m = std::collections::BTreeMap::new();
        m.insert("role".into(), Json::Str(role.into()));
        m.insert("content".into(), Json::Str(content.into()));
        msgs.push(Json::Obj(m));
    }
    let mut req = std::collections::BTreeMap::new();
    req.insert("messages".into(), Json::Arr(msgs));
    req.insert("temperature".into(), Json::Int(0));
    if let Some(m) = &e.model {
        req.insert("model".into(), Json::Str(m.clone()));
    }
    let (status, body) = post_json(e, &Json::Obj(req).to_string())?;
    if !(200..300).contains(&status) {
        return Err(format!("the model endpoint {} answered {status}: {}", e.name, body.chars().take(300).collect::<String>()));
    }
    let v = json::parse(&body).map_err(|x| format!("the model's reply is not JSON: {x}"))?;
    v.get("choices")
        .and_then(|c| c.as_array())
        .and_then(|c| c.first())
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(|t| t.as_str())
        .map(str::to_string)
        .ok_or_else(|| "the model's reply has no choices[0].message.content".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agents() -> Agents {
        let mut a = Agents::default();
        a.data_levels = vec!["public".into(), "site".into()];
        a.endpoints = vec![
            Endpoint { name: "hosted".into(), url: "https://h/v1".into(), kind: "hosted".into(), data_level: "public".into(), model: None, key_file: None, timeout_ms: 1000, ca_file: None },
            Endpoint { name: "local".into(), url: "http://127.0.0.1:1/v1".into(), kind: "local".into(), data_level: "site".into(), model: None, key_file: None, timeout_ms: 1000, ca_file: None },
        ];
        a
    }

    #[test]
    fn chooses_by_level() {
        let a = agents();
        assert_eq!(choose(&a, "public", None).unwrap().name, "hosted");
        assert_eq!(choose(&a, "site", None).unwrap().name, "local");
        assert!(choose(&a, "site", Some("hosted")).unwrap_err().starts_with("refused"));
        assert!(choose(&a, "secret", None).is_err());
        let u = parse_url("https://api.example:8443/v1/chat/completions").unwrap();
        assert!(u.tls && u.port == 8443 && u.path == "/v1/chat/completions");
        assert_eq!(parse_url("http://h/x").unwrap().port, 80);
        assert_eq!(dechunk(b"3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"), b"abcde");
    }
}

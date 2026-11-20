//! A small HTTP/1.1 server and client for the API: one request per
//! connection (`Connection: close`), a body only with `Content-Length`,
//! limits on header and body size, and a read timeout. Mutual TLS through
//! rustls for the mesh listener.

use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

pub const MAX_HEADER: usize = 16 * 1024;
pub const MAX_BODY: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub query: BTreeMap<String, String>,
    pub headers: BTreeMap<String, String>,
    pub body: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct Response {
    pub status: u16,
    pub content_type: &'static str,
    pub body: Vec<u8>,
}

impl Response {
    pub fn json(status: u16, body: String) -> Response {
        Response { status, content_type: "application/json", body: body.into_bytes() }
    }
    pub fn text(status: u16, content_type: &'static str, body: String) -> Response {
        Response { status, content_type, body: body.into_bytes() }
    }
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "",
    }
}

/// Percent-decoding of one path segment or query value.
pub fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Percent-encoding of one path segment.
pub fn encode(s: &str) -> String {
    s.bytes()
        .map(|c| if c.is_ascii_alphanumeric() || b"-_.~".contains(&c) { (c as char).to_string() } else { format!("%{c:02X}") })
        .collect()
}

pub fn read_request(stream: &mut impl Read) -> Result<Request, (u16, String)> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let header_end = loop {
        if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break p;
        }
        if buf.len() > MAX_HEADER {
            return Err((413, "the request headers are too large".into()));
        }
        let n = stream.read(&mut chunk).map_err(|e| (400, format!("read: {e}")))?;
        if n == 0 {
            return Err((400, "the connection closed before the request ended".into()));
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    let head = std::str::from_utf8(&buf[..header_end]).map_err(|_| (400, "the headers are not UTF-8".to_string()))?;
    let mut lines = head.split("\r\n");
    let first = lines.next().unwrap_or("");
    let mut parts = first.split(' ');
    let (method, target) = match (parts.next(), parts.next(), parts.next()) {
        (Some(m), Some(t), Some(v)) if v.starts_with("HTTP/1.") => (m.to_string(), t.to_string()),
        _ => return Err((400, format!("not an HTTP/1 request line: {first:?}"))),
    };
    let mut headers = BTreeMap::new();
    for l in lines {
        if let Some((k, v)) = l.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    let len: usize = match headers.get("content-length") {
        Some(v) => v.parse().map_err(|_| (400, "Content-Length is not a number".to_string()))?,
        None => 0,
    };
    if len > MAX_BODY {
        return Err((413, format!("the body is over {} MiB", MAX_BODY / 1024 / 1024)));
    }
    if headers.get("transfer-encoding").is_some_and(|t| !t.eq_ignore_ascii_case("identity")) {
        return Err((400, "send the body with Content-Length, not chunked".into()));
    }
    let mut body = buf[header_end + 4..].to_vec();
    while body.len() < len {
        let n = stream.read(&mut chunk).map_err(|e| (400, format!("read: {e}")))?;
        if n == 0 {
            return Err((400, "the connection closed before the body ended".into()));
        }
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(len);
    let (path, q) = target.split_once('?').unwrap_or((&target, ""));
    let query = q.split('&').filter(|p| !p.is_empty()).map(|p| {
        let (k, v) = p.split_once('=').unwrap_or((p, ""));
        (decode(k), decode(v))
    }).collect();
    Ok(Request { method, path: path.to_string(), query, headers, body })
}

pub fn write_response(stream: &mut impl Write, r: &Response) -> std::io::Result<()> {
    let head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n",
        r.status,
        reason(r.status),
        r.content_type,
        r.body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(&r.body)?;
    stream.flush()
}

/// A plain HTTP call, for the CLI on the same host.
pub fn call(addr: &str, method: &str, path: &str, token: Option<&str>, body: Option<&[u8]>) -> Result<(u16, Vec<u8>), String> {
    let sock = addr.to_socket_addrs().map_err(|e| format!("{addr}: {e}"))?.next().ok_or(format!("{addr}: no address"))?;
    let mut s = TcpStream::connect_timeout(&sock, Duration::from_secs(3))
        .map_err(|e| format!("cannot reach the runner's API at {addr} ({e}); is the service running? sudo systemctl status goat-processors"))?;
    s.set_read_timeout(Some(Duration::from_secs(120))).ok();
    let body = body.unwrap_or(b"");
    let mut req = format!("{method} {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\nContent-Length: {}\r\n", body.len());
    if let Some(t) = token {
        req.push_str(&format!("Authorization: Bearer {t}\r\n"));
    }
    req.push_str("\r\n");
    s.write_all(req.as_bytes()).and_then(|_| s.write_all(body)).map_err(|e| format!("send: {e}"))?;
    let mut raw = Vec::new();
    s.read_to_end(&mut raw).map_err(|e| format!("read: {e}"))?;
    let end = raw.windows(4).position(|w| w == b"\r\n\r\n").ok_or("the reply has no header end")?;
    let head = String::from_utf8_lossy(&raw[..end]);
    let status: u16 = head.split(' ').nth(1).and_then(|c| c.parse().ok()).ok_or("the reply has no status")?;
    Ok((status, raw[end + 4..].to_vec()))
}

/// The server side of mutual TLS: the runner's certificate, and the CA whose
/// signature a client certificate must carry.
pub fn tls_config(root_ca: &Path, certificate: &Path, private_key: &Path) -> Result<Arc<rustls::ServerConfig>, String> {
    use rustls_pki_types::pem::PemObject;
    use rustls_pki_types::{CertificateDer, PrivateKeyDer};
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut roots = rustls::RootCertStore::empty();
    for c in CertificateDer::pem_file_iter(root_ca).map_err(|e| format!("{}: {e}", root_ca.display()))? {
        roots.add(c.map_err(|e| format!("{}: {e}", root_ca.display()))?).map_err(|e| format!("{}: {e}", root_ca.display()))?;
    }
    let verifier = rustls::server::WebPkiClientVerifier::builder_with_provider(Arc::new(roots), provider.clone())
        .build()
        .map_err(|e| format!("client verifier: {e}"))?;
    let chain: Vec<CertificateDer<'static>> = CertificateDer::pem_file_iter(certificate)
        .map_err(|e| format!("{}: {e}", certificate.display()))?
        .collect::<Result<_, _>>()
        .map_err(|e| format!("{}: {e}", certificate.display()))?;
    let key = PrivateKeyDer::from_pem_file(private_key).map_err(|e| format!("{}: {e}", private_key.display()))?;
    let cfg = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| e.to_string())?
        .with_client_cert_verifier(verifier)
        .with_single_cert(chain, key)
        .map_err(|e| format!("the API certificate and key: {e}"))?;
    Ok(Arc::new(cfg))
}

/// The common name (CN) of a verified client certificate.
pub fn peer_name(conn: &rustls::ServerConnection) -> Option<String> {
    let cert = conn.peer_certificates()?.first()?;
    let (_, x) = x509_parser::parse_x509_certificate(cert.as_ref()).ok()?;
    let cn = x.subject().iter_common_name().next()?.as_str().ok()?.to_string();
    Some(cn)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_request() {
        let raw = b"PUT /v1/pipeline/correlate?x=a%20b HTTP/1.1\r\nContent-Length: 4\r\nAuthorization: Bearer t\r\n\r\nabcd";
        let r = read_request(&mut &raw[..]).unwrap();
        assert_eq!(r.method, "PUT");
        assert_eq!(r.path, "/v1/pipeline/correlate");
        assert_eq!(r.query["x"], "a b");
        assert_eq!(r.headers["authorization"], "Bearer t");
        assert_eq!(r.body, b"abcd");
        assert!(read_request(&mut &b"GARBAGE\r\n\r\n"[..]).is_err());
        assert_eq!(encode("a/b c"), "a%2Fb%20c");
        assert_eq!(decode("a%2Fb%20c"), "a/b c");
    }
}

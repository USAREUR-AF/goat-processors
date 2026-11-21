//! The operator page, Fieldkit Processors (runner/fieldkit/processors.html).
//!
//! One HTML file, built into the binary, served at GET /ui. It carries its
//! own copy of the Bleating Edge design system and makes no request outside
//! the actions it declares, each of which is a CLI verb and an API route
//! (runner/fieldkit/check-scope.py checks this in CI). The page holds no
//! authority: every action is answered by the API with the caller's role.

use crate::http::Response;

const PAGE: &str = include_str!("../fieldkit/processors.html");

/// The page, with headers that keep it to itself: no outside source of any
/// kind, no framing, no referrer.
pub fn page() -> Response {
    Response::text(200, "text/html; charset=utf-8", PAGE.to_string())
}

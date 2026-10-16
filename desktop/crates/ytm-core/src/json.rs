//! A lightweight, forgiving view over decoded JSON.
//!
//! InnerTube responses are huge, deeply nested and change shape often, so instead of strict
//! serde models we navigate them dynamically and fall back gracefully: a missing key is just an
//! empty view, never an error.

use serde_json::{Map, Value};

#[derive(Clone, Copy, Debug, Default)]
pub struct J<'a>(pub Option<&'a Value>);

impl<'a> J<'a> {
    pub const NULL: J<'static> = J(None);

    pub fn new(value: &'a Value) -> Self {
        J(Some(value))
    }

    pub fn get(self, key: &str) -> J<'a> {
        J(self.0.and_then(Value::as_object).and_then(|o| o.get(key)))
    }

    pub fn idx(self, index: usize) -> J<'a> {
        J(self.0.and_then(Value::as_array).and_then(|a| a.get(index)))
    }

    /// Follows a path of object keys, e.g. `j.at(&["browseEndpoint", "browseId"])`.
    pub fn at(self, path: &[&str]) -> J<'a> {
        path.iter().fold(self, |current, key| current.get(key))
    }

    pub fn exists(self) -> bool {
        matches!(self.0, Some(v) if !v.is_null())
    }

    pub fn str(self) -> Option<&'a str> {
        self.0.and_then(Value::as_str)
    }

    pub fn string(self) -> Option<String> {
        self.str().map(str::to_owned)
    }

    pub fn bool(self) -> Option<bool> {
        self.0.and_then(Value::as_bool)
    }

    pub fn int(self) -> Option<i64> {
        match self.0? {
            Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
            Value::String(s) => s.parse().ok(),
            _ => None,
        }
    }

    pub fn double(self) -> Option<f64> {
        match self.0? {
            Value::Number(n) => n.as_f64(),
            Value::String(s) => s.parse().ok(),
            _ => None,
        }
    }

    pub fn array(self) -> Vec<J<'a>> {
        self.0
            .and_then(Value::as_array)
            .map(|a| a.iter().map(J::new).collect())
            .unwrap_or_default()
    }

    pub fn object(self) -> Option<&'a Map<String, Value>> {
        self.0.and_then(Value::as_object)
    }

    /// First key of an object: renderer wrappers are single-key objects like
    /// `{"musicShelfRenderer": {...}}`.
    pub fn first_key(self) -> Option<&'a str> {
        self.object().and_then(|o| o.keys().next()).map(String::as_str)
    }

    pub fn runs(self) -> Vec<J<'a>> {
        self.get("runs").array()
    }

    /// Joined text of a `{runs: [...]}` or `{simpleText: ...}` object.
    pub fn text(self) -> Option<String> {
        if let Some(simple) = self.get("simpleText").str() {
            return Some(simple.to_owned());
        }
        let parts: Vec<&str> = self.runs().into_iter().filter_map(|r| r.get("text").str()).collect();
        if parts.is_empty() {
            None
        } else {
            Some(parts.concat())
        }
    }

    /// Depth-first search for every value stored under `key`, in document order (arrays keep
    /// order; object keys are visited in a stable priority order). Doesn't descend into matches.
    pub fn find_all(self, key: &str) -> Vec<J<'a>> {
        self.find_limit(key, usize::MAX)
    }

    pub fn find_limit(self, key: &str, limit: usize) -> Vec<J<'a>> {
        let mut results = Vec::new();
        if let Some(value) = self.0 {
            collect(value, key, &mut results, limit);
        }
        results
    }

    pub fn first(self, key: &str) -> Option<J<'a>> {
        self.find_limit(key, 1).into_iter().next()
    }
}

const KEY_PRIORITY: [&str; 6] = ["header", "tabs", "contents", "content", "secondaryContents", "continuationContents"];

/// An object's keys with the page-structure keys first, then alphabetically.
pub fn ordered_keys(map: &Map<String, Value>) -> Vec<&str> {
    let mut keys: Vec<&str> = map.keys().map(String::as_str).collect();
    let rank = |k: &str| KEY_PRIORITY.iter().position(|p| *p == k).unwrap_or(usize::MAX);
    keys.sort_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| a.cmp(b)));
    keys
}

fn collect<'a>(node: &'a Value, key: &str, results: &mut Vec<J<'a>>, limit: usize) {
    if results.len() >= limit {
        return;
    }
    match node {
        Value::Object(map) => {
            for k in ordered_keys(map) {
                if results.len() >= limit {
                    return;
                }
                let value = &map[k];
                if k == key {
                    results.push(J::new(value));
                    continue;
                }
                collect(value, key, results, limit);
            }
        }
        Value::Array(items) => {
            for value in items {
                if results.len() >= limit {
                    return;
                }
                collect(value, key, results, limit);
            }
        }
        _ => {}
    }
}

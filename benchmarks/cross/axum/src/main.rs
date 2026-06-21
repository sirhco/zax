//! Cross-framework benchmark server — axum (Rust).
//! Routes match the zax and Go std-lib servers 1:1:
//!   GET  /            -> "hello"
//!   GET  /users/{id}  -> the captured id
//!   POST /echo        -> JSON echo of {"msg": "..."}
//!   GET  /large       -> buffered ~PAYLOAD_KB KB JSON body
//! Run: `cargo run --release` (listens on :8082).

use axum::{
    extract::Path,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Serialize, Deserialize)]
struct Msg {
    msg: String,
}

async fn hello() -> &'static str {
    "hello"
}

async fn user(Path(id): Path<String>) -> String {
    id
}

async fn echo(Json(m): Json<Msg>) -> Json<Msg> {
    Json(m)
}

#[tokio::main]
async fn main() {
    let kb: usize = std::env::var("PAYLOAD_KB")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(64);
    let n = (kb * 1024).max(16);
    let mut body = String::with_capacity(n);
    body.push_str("{\"data\":\"");
    body.extend(std::iter::repeat('x').take(n - 11));
    body.push_str("\"}");
    let large_body = Arc::new(body);

    let lb = large_body.clone();
    let app = Router::new()
        .route("/", get(hello))
        .route("/users/{id}", get(user))
        .route("/echo", post(echo))
        .route(
            "/large",
            get(move || {
                let lb = lb.clone();
                async move {
                    ([("content-type", "application/json")], (*lb).clone())
                }
            }),
        );

    let addr = "127.0.0.1:8082";
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    println!("axum bench server on http://{addr}");
    axum::serve(listener, app).await.unwrap();
}

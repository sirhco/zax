//! Cross-framework benchmark server — axum (Rust).
//! Routes match the zax and Go std-lib servers 1:1:
//!   GET  /            -> "hello"
//!   GET  /users/{id}  -> the captured id
//!   POST /echo        -> JSON echo of {"msg": "..."}
//! Run: `cargo run --release` (listens on :8082).

use axum::{
    extract::Path,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};

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
    let app = Router::new()
        .route("/", get(hello))
        .route("/users/{id}", get(user))
        .route("/echo", post(echo));

    let addr = "127.0.0.1:8082";
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    println!("axum bench server on http://{addr}");
    axum::serve(listener, app).await.unwrap();
}

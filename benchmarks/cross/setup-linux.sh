#!/usr/bin/env bash
# Install the cross-bench toolchains natively on a fresh Linux host (Ubuntu/Debian),
# for the bare-metal run in benchmarks/cross/baremetal-linux.md (Option B).
# Installs: zig 0.16.0, go, rust + oha. Idempotent-ish; safe to re-run.
set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
GO_VERSION="${GO_VERSION:-1.22.5}"

# Detect arch → zig/go naming.
case "$(uname -m)" in
  x86_64)  ZARCH=x86_64;  GOARCH=amd64 ;;
  aarch64|arm64) ZARCH=aarch64; GOARCH=arm64 ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac

sudo apt-get update
sudo apt-get install -y --no-install-recommends curl xz-utils ca-certificates build-essential git

mkdir -p "$HOME/.local/bin"

# --- Zig 0.16 ---
if ! command -v zig >/dev/null 2>&1 || [ "$(zig version 2>/dev/null)" != "$ZIG_VERSION" ]; then
  echo "== installing zig $ZIG_VERSION ($ZARCH) =="
  curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz
  sudo rm -rf /opt/zig && sudo mkdir -p /opt/zig
  sudo tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
  sudo ln -sf /opt/zig/zig /usr/local/bin/zig
  rm -f /tmp/zig.tar.xz
fi
zig version

# --- Go ---
if ! command -v go >/dev/null 2>&1; then
  echo "== installing go $GO_VERSION ($GOARCH) =="
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -o /tmp/go.tgz
  sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz
  sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
  rm -f /tmp/go.tgz
fi
go version

# --- Rust + oha (load generator) ---
if ! command -v cargo >/dev/null 2>&1; then
  echo "== installing rust (rustup) =="
  curl -fsSL https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
fi
. "$HOME/.cargo/env" 2>/dev/null || true
if ! command -v oha >/dev/null 2>&1; then
  echo "== installing oha (cargo) =="
  cargo install oha --locked
fi
oha --version

echo
echo "== toolchains ready. Now run the bench: =="
echo "   cd benchmarks/cross && BACKEND=both PIN=1 DURATION=30s CONNS=64 ./run.sh"
echo "   (oha is in ~/.cargo/bin — ensure it's on PATH: source \$HOME/.cargo/env)"

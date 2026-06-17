# Linux cross-framework bench container for zax (E5 + PIN=1 cross-framework).
# Build context = repo ROOT (the bench's zax is a path dependency on ../../..).
#   docker build -f benchmarks/cross/docker/Dockerfile -t zax-linux-bench .
#   docker run --rm zax-linux-bench
# Native arm64 on an Apple-silicon host (no emulation). Docker runs a real Linux
# kernel in a VM — exactly what E5 needs to test "is the ~35ms a macOS artifact?".
FROM rust:1-bookworm

ARG ZIG_VERSION=0.16.0
ARG GO_VERSION=1.22.5
# Target arch of the image (arm64 on Apple silicon). Override for amd64.
ARG ARCH=aarch64
ARG GOARCH=arm64

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl xz-utils ca-certificates util-linux procps \
    && rm -rf /var/lib/apt/lists/*

# Zig 0.16.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && ln -s /opt/zig/zig /usr/local/bin/zig && rm /tmp/zig.tar.xz \
    && zig version

# Go
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -o /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz && ln -s /usr/local/go/bin/go /usr/local/bin/go \
    && rm /tmp/go.tgz && go version

# oha (load generator) — compiled from the rust base
RUN cargo install oha --locked && oha --version

# Repo + pre-build all three release servers so `docker run` is offline + fast.
WORKDIR /zax
COPY . /zax
RUN cd /zax/benchmarks/cross \
    && ( cd zax   && zig build -Doptimize=ReleaseFast ) \
    && ( cd axum  && cargo build --release ) \
    && ( cd go    && go build -o go-bench . ) \
    && ( cd httpz && zig build -Doptimize=ReleaseFast )

CMD ["bash", "/zax/benchmarks/cross/docker/run-linux-bench.sh"]

# =============================================================================
# Multi-stage build — Rust 1.85 (2024 edition)
# Stage 1: builder  — compile release binary
# Stage 2: runtime  — minimal debian-slim image
# =============================================================================

# ── Stage 1: Build ───────────────────────────────────────────────────────────
FROM rust:1.85-slim AS builder

WORKDIR /app

# Install build dependencies (needed for sqlx native-tls + openssl)
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Cache dependency compilation:
#   1. Copy manifests only
#   2. Build a dummy main.rs → downloads + compiles all crates
#   3. Replace with real source → only re-compiles changed code
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main(){}' > src/main.rs
RUN cargo build --release --locked
RUN rm -rf src

# Copy real source and rebuild
COPY src ./src
# Touch main.rs so Cargo detects the change
RUN touch src/main.rs
RUN cargo build --release --locked

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

WORKDIR /app

# CA certificates for TLS connections to PostgreSQL / MongoDB
RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Non-root user for security
RUN useradd -m -u 1000 appuser
USER appuser

COPY --from=builder /app/target/release/odsperf-demo .

EXPOSE 8080

# Default to JSON logging in container environments
ENV RUST_LOG=info
ENV RUST_LOG_FORMAT=json
ENV PORT=8080

ENTRYPOINT ["./odsperf-demo"]

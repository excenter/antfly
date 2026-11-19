# Stage 1: Build
# Patch-level toolchain pin: Go stdlib CVEs are fixed in point releases, so a
# floating `1.26-alpine` tag silently ships whatever was cached at build time.
FROM --platform=$BUILDPLATFORM golang:1.26.11-alpine@sha256:ecb67f987aa1a57794c91d19ade7ae0209f2f0f5496aaef9e6ae85ddf92d02ab AS builder

WORKDIR /app

COPY go.mod go.sum ./
COPY termite /app/termite
COPY cmd/antfly /app/cmd/antfly
COPY pkg /app/pkg

RUN go mod download

COPY . .

# Declare build arguments for multi-arch support (automatically provided by Docker Buildx)
ARG TARGETOS
ARG TARGETARCH

# Build the applications as static binaries for the target platform.
# This makes them portable and suitable for minimal container images.
RUN GOEXPERIMENT=simd CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -a -installsuffix cgo -o antfly ./cmd/antfly

# Stage 2: busybox source for the operator shim below.
FROM gcr.io/distroless/static:debug-nonroot@sha256:7df9fac2f5d3927260696af33fc2391da26366825838a47337088ed78f854a0c AS busybox

# Stage 3: Runtime. Distroless static carries no OS package set (no openssl,
# no apk), so base-image CVEs stop accruing; CA certs and tzdata are included.
FROM gcr.io/distroless/static:nonroot@sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931

LABEL org.opencontainers.image.source=https://github.com/antflydb/antfly
LABEL org.opencontainers.image.description="AntflyDB - Distributed document database with vector search for AI applications"
LABEL org.opencontainers.image.licenses=Elastic-2.0

# The antfly-operator (pkg/operator <= v0.1.1-rc.4) launches every server
# container as `/bin/sh -c "exec /antfly ..."` (deriving the node ID from the
# pod hostname) and the AntflyBackup CronJob as
# `/bin/sh -c "/antfly backup ... --backup-id <name>-$(date +%Y%m%d%H%M%S)"`.
# Ship busybox as exactly those two applets so the unmodified operator works.
COPY --from=busybox /busybox/busybox /bin/sh
COPY --from=busybox /busybox/busybox /bin/date

# Copy the built binary from the builder stage
COPY --from=builder /app/antfly /antfly

# Same UID/GID as the previous alpine image (adduser -S → 100:101). Existing
# PVC data was written by this UID without group-write, so changing it would
# leave current clusters unable to write their own data directories.
USER 100:101

# No passwd entry for 100 in distroless, so HOME would resolve to `/` and the
# default ~/.antfly storage would fail for plain `docker run`. Kubernetes
# deployments pass --config and mount /antflydb, so this only affects local use.
ENV HOME=/tmp

# No HEALTHCHECK: the old one shelled out to wget, which no longer exists, and
# Kubernetes ignores Dockerfile HEALTHCHECK anyway (the operator wires HTTP probes).

EXPOSE 8080 11433 4200

ENTRYPOINT ["/antfly"]

# Default to single-node swarm mode for easy local usage.
# Override with a different subcommand (e.g., "metadata", "store", "termite")
# via Kubernetes Pod args or docker run arguments.
CMD ["swarm"]

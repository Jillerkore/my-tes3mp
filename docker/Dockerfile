# TES3MP dedicated server (Morrowind multiplayer) in a small, non-root image.
#
# Build from the repository root (the build context is tiny, see .dockerignore):
#
#   docker build -f docker/Dockerfile -t my-tes3mp-server:0.8.1 .
#
# or simply `docker compose build` / `docker compose up -d`.
#
# Needs BuildKit (the default builder since Docker 23) for the RUN heredocs,
# and Docker 25+ for HEALTHCHECK --start-interval.
#
# Layout of the result:
#   /opt/tes3mp   read-only TES3MP install plus a pristine copy of CoreScripts
#   /data         the one volume: world, players, scripts, server config
#                 (seeded on first start - see docker/entrypoint.sh)

# ---- Pinned inputs -----------------------------------------------------------
# Everything that decides what ends up in the image is pinned here. To move to
# another TES3MP release, change these four values together.
#
# Base image: Debian stable. The release binary was built on Debian, bundles its
# own Boost and otherwise only needs glibc, libstdc++ and LuaJIT, all of which
# Debian's "slim" image provides in ~75 MB. For fully reproducible builds append
# a digest, e.g. --build-arg DEBIAN_IMAGE=debian:trixie-slim@sha256:...
ARG DEBIAN_IMAGE=debian:trixie-slim

ARG TES3MP_VERSION=0.8.1
ARG TES3MP_TARBALL_URL=https://github.com/TES3MP/TES3MP/releases/download/tes3mp-0.8.1/tes3mp-server-GNU%2BLinux-x86_64-release-0.8.1-68954091c5-6da3fdea59.tar.gz
# The same release asset through the GitHub API. github.com release downloads
# occasionally answer 504 for minutes at a time; the API endpoint is served by
# different infrastructure and is used as a fallback.
ARG TES3MP_TARBALL_FALLBACK_URL=https://api.github.com/repos/TES3MP/TES3MP/releases/assets/64397879
ARG TES3MP_TARBALL_SHA256=106a56e32a00ff7a92b574fae0e25671e90a199f509b16d483a8d7da6fc3bcf0

# CoreScripts: the Lua that implements the game rules. The release tarball
# carries a snapshot from May 2022; upstream has kept fixing the 0.8.1 branch
# since (among other things it gained per-player kill counts,
# config.shareKills). Pinned by commit: git verifies the content against the
# hash, so no separate checksum is needed. To update, pick a newer commit from
# https://github.com/TES3MP/CoreScripts/commits/0.8.1
ARG CORESCRIPTS_REPO=https://github.com/TES3MP/CoreScripts.git
ARG CORESCRIPTS_COMMIT=3e397a11eaf7d0d4ff08df4bb9925e67748b4db8


# ---- Stage 1: download, verify and trim the release --------------------------
FROM ${DEBIAN_IMAGE} AS fetch

ARG TES3MP_TARBALL_URL
ARG TES3MP_TARBALL_FALLBACK_URL
ARG TES3MP_TARBALL_SHA256
ARG CORESCRIPTS_REPO
ARG CORESCRIPTS_COMMIT
# Build-time only (an ARG, not an ENV): keeps apt from asking questions.
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Package versions are deliberately not pinned (hadolint DL3008): Debian stable
# only ever replaces a package with its security fix, and a pin would break
# the build the day that happens.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/tes3mp

# Download with retries, fall back to the API URL, and accept nothing that does
# not match the pinned checksum - whichever URL it came from.
RUN <<'EOF'
download() {
    curl --fail --location --silent --show-error \
         --retry 4 --retry-delay 5 --retry-all-errors \
         --connect-timeout 20 --max-time 300 \
         --output release.tar.gz "$@"
}
verify() {
    echo "${TES3MP_TARBALL_SHA256}  release.tar.gz" | sha256sum --check --quiet -
}

if download "${TES3MP_TARBALL_URL}" && verify; then
    echo "Downloaded TES3MP from the release URL"
else
    echo "Release URL failed, trying the GitHub API fallback" >&2
    rm -f release.tar.gz
    download --header 'Accept: application/octet-stream' "${TES3MP_TARBALL_FALLBACK_URL}"
    verify
    echo "Downloaded TES3MP from the fallback URL"
fi
EOF

# Fetch exactly the pinned CoreScripts commit (GitHub serves any commit by its
# full hash). A retry loop covers the same kind of hiccup as above.
RUN <<'EOF'
git init --quiet corescripts
cd corescripts
git remote add origin "${CORESCRIPTS_REPO}"
for attempt in 1 2 3 4; do
    if git fetch --quiet --depth 1 origin "${CORESCRIPTS_COMMIT}"; then
        break
    fi
    [ "$attempt" -lt 4 ] || { echo "Could not fetch CoreScripts ${CORESCRIPTS_COMMIT}" >&2; exit 1; }
    sleep 5
done
git checkout --quiet FETCH_HEAD
test "$(git rev-parse HEAD)" = "${CORESCRIPTS_COMMIT}"
rm -rf .git
EOF

# Keep only what a dedicated server needs. The release tarball also carries
# client-side leftovers (GUI layouts, shaders, a controller database, build
# directories, CoreScripts' .git) that the server never opens.
RUN <<'EOF'
tar -xzf release.tar.gz
src=TES3MP-server
dst=/opt/tes3mp

install -d "$dst/resources" "$dst/server"

# The server itself, the Boost 1.67 libraries it was linked against, and the
# stock config the binary insists on finding next to itself.
cp -a "$src/tes3mp-server.x86_64" "$src/lib" "$src/tes3mp-server-default.cfg" "$dst/"

# The only "resource" the server reads: the version/commit hash that clients
# must match.
cp -a "$src/resources/version" "$dst/resources/"

# Pristine CoreScripts, from the pinned commit fetched above rather than the
# older snapshot inside the tarball. This copy is never used directly; the
# entrypoint seeds /data from it.
cs=corescripts
cp -a "$cs/data" "$cs/scripts" "$cs/lib" "$cs/LICENSE" "$cs/README.md" "$dst/server/"

# Licensing. TES3MP is GPLv3, so the image carries the licence text, the
# credits and the complete corresponding source that upstream ships inside the
# release for exactly this purpose. Upstream names it source.tar.gz but it is
# an uncompressed 21 MB tar; gzip it for real (-n: no timestamp, reproducible)
# so that honouring the GPL costs about 5 MB instead.
cp -a "$src/LICENSE" "$src/AUTHORS.md" "$src/tes3mp-credits.md" \
      "$src/tes3mp-package-info.txt" "$dst/"
if gzip --test "$src/source.tar.gz" 2>/dev/null; then
    cp "$src/source.tar.gz" "$dst/source.tar.gz"
else
    gzip -9 -n --stdout "$src/source.tar.gz" > "$dst/source.tar.gz"
fi

# The tarball marks every file executable; normalise to sane modes.
find "$dst" -type d -exec chmod 755 {} +
find "$dst" -type f -exec chmod 644 {} +
chmod 755 "$dst/tes3mp-server.x86_64"
EOF


# ---- Stage 2: the runtime image ----------------------------------------------
FROM ${DEBIAN_IMAGE}

ARG DEBIAN_IMAGE
ARG TES3MP_VERSION
ARG TES3MP_TARBALL_URL
ARG TES3MP_TARBALL_SHA256
ARG CORESCRIPTS_COMMIT

# The server runs as this unprivileged user. 1000 is the first regular user on
# most Linux hosts, which keeps bind mounts convenient; named volumes work with
# any value.
ARG TES3MP_UID=1000
ARG TES3MP_GID=1000
ARG DEBIAN_FRONTEND=noninteractive

# Labels. CI (docker/metadata-action) overrides the generic org.opencontainers
# ones when publishing; the tes3mp.* ones always describe the bundled server.
LABEL org.opencontainers.image.title="my-tes3mp-server" \
      org.opencontainers.image.description="TES3MP ${TES3MP_VERSION} dedicated server (Morrowind multiplayer) - one volume, configured through environment variables" \
      org.opencontainers.image.version="${TES3MP_VERSION}" \
      org.opencontainers.image.source="https://github.com/Jillerkore/my-tes3mp" \
      org.opencontainers.image.licenses="GPL-3.0-only" \
      org.opencontainers.image.base.name="docker.io/library/${DEBIAN_IMAGE}" \
      tes3mp.version="${TES3MP_VERSION}" \
      tes3mp.release.url="${TES3MP_TARBALL_URL}" \
      tes3mp.release.sha256="${TES3MP_TARBALL_SHA256}" \
      tes3mp.corescripts.commit="${CORESCRIPTS_COMMIT}" \
      tes3mp.source="/opt/tes3mp/source.tar.gz (in this image); upstream: https://github.com/TES3MP/TES3MP/tree/tes3mp-${TES3MP_VERSION}"

# Runtime dependencies:
#   libluajit-5.1-2  the one shared library the release does not bundle
#   tini             minimal init: forwards signals to the server and reaps
#                    zombies, so `docker stop` works even with plain `docker run`
#   nano             so `docker compose exec server nano scripts/config.lua`
#                    works; the slim base image has no editor at all
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends libluajit-5.1-2 tini nano \
 && rm -rf /var/lib/apt/lists/*

# The user, the volume mount point, and the two per-user directories the
# OpenMW-derived binary creates on startup if they are missing. It reads its
# user config from ~/.config/openmw/tes3mp-server.cfg; the symlink redirects
# that to the volume so the config lives next to the rest of the state.
RUN groupadd --gid "${TES3MP_GID}" tes3mp \
 && useradd --uid "${TES3MP_UID}" --gid tes3mp --create-home --home-dir /home/tes3mp \
            --shell /usr/sbin/nologin tes3mp \
 && install -d -o tes3mp -g tes3mp \
        /data \
        /home/tes3mp/.config/openmw \
        /home/tes3mp/.local/share/openmw/screenshots \
 && ln -s /data/tes3mp-server.cfg /home/tes3mp/.config/openmw/tes3mp-server.cfg

COPY --from=fetch /opt/tes3mp /opt/tes3mp
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
# Scripts my-tes3mp adds on top of CoreScripts; the entrypoint installs them
# into /data/scripts/custom/myTes3mp/ on every start.
COPY docker/custom /opt/tes3mp/my-tes3mp/custom
# The my-tes3mp release number, printed at start-up.
COPY VERSION /opt/tes3mp/my-tes3mp/VERSION

# Fail the build - not the first start - if the binary cannot find a library.
RUN LD_LIBRARY_PATH=/opt/tes3mp/lib ldd /opt/tes3mp/tes3mp-server.x86_64 > /tmp/ldd.txt \
 && ! grep 'not found' /tmp/ldd.txt \
 && rm /tmp/ldd.txt

ENV TES3MP_VERSION=${TES3MP_VERSION} \
    CORESCRIPTS_COMMIT=${CORESCRIPTS_COMMIT} \
    HOME=/home/tes3mp

# Numeric, so runtimes that insist on a provably non-root user can check it.
USER ${TES3MP_UID}:${TES3MP_GID}
WORKDIR /data
VOLUME /data

# TES3MP speaks UDP only (RakNet).
EXPOSE 25565/udp

# The server handles SIGTERM itself: it leaves its main loop, runs the
# OnServerExit script hooks and exits 0, normally well within a second. With
# public listing enabled it can take ~13 s (it waits for the master-server
# announcer thread), so docker-compose.yml sets a 30 s grace period; with
# plain `docker run` add --stop-timeout 30 in that case.
STOPSIGNAL SIGTERM

# Honest health for a UDP service: send the server a RakNet "unconnected ping"
# on localhost and require the matching pong. That is the same probe the TES3MP
# server browser uses, so "healthy" means "the port is bound and the server
# answers players", not merely "a process exists". During the start period the
# probe runs every second, so `docker compose up --wait` returns promptly.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=30s --start-interval=1s \
    CMD ["/usr/local/bin/entrypoint.sh", "healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["server"]

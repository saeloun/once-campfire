# Build Campfire into a native binary

This Saeloun fork can run as a Linux executable built from Rails source.
[Roundhouse](https://github.com/vipulnsward/roundhouse) emits a Ruby application
for [Spinel](https://github.com/matz/spinel), which generates C. A C compiler
then builds the executable. Static files and shared libraries still ship with
it; the deployed container has no Ruby interpreter or Rails server process.

## Verified reference build

The DQOR release deployed on 2026-10-04 uses these revisions:

| Component | Revision |
| --- | --- |
| [Campfire](https://github.com/saeloun/once-campfire/commit/46838319f0256f5d2bcc392f8c3bb6d394dbc2fe) | `46838319f0256f5d2bcc392f8c3bb6d394dbc2fe` |
| [Roundhouse](https://github.com/vipulnsward/roundhouse/commit/be39e428ef6f3a47719d3ab9a46041133146178a) | `be39e428ef6f3a47719d3ab9a46041133146178a` |
| [Spinel](https://github.com/matz/spinel/commit/ed603ed595db42626c747988a091c07f54532b94) | `ed603ed595db42626c747988a091c07f54532b94` |

That Campfire revision includes the DQOR theme, dashboard, SSO, session
persistence and sharper logo. Pin it explicitly: the fork's `main` branch may
not yet contain every deployed change. The commands below use Bash.

## Build from the published C package

The [verified release](https://github.com/vipulnsward/roundhouse/releases/tag/campfire-dq-logo-be39e42-4683831-20261004)
contains `docker.tgz`, `spinel.tgz`, `campfire-linux-amd64`, `provenance.json`
and `validation.md`. Download with GitHub CLI, verify checksums with Python 3,
and compile the Linux AMD64 image with Docker. The C package includes the
Spinel runtime source and assets; Ruby and Spinel installations are unnecessary
for this path.

```sh
mkdir -p campfire-native-release
cd campfire-native-release

gh release download campfire-dq-logo-be39e42-4683831-20261004 \
  --repo vipulnsward/roundhouse \
  --pattern docker.tgz --pattern provenance.json --pattern validation.md

python3 - <<'PY'
import hashlib, json
from pathlib import Path
expected = json.loads(Path("provenance.json").read_text())["artifacts"]["docker.tgz"]
assert hashlib.sha256(Path("docker.tgz").read_bytes()).hexdigest() == expected
print("Archive checksum verified")
PY

tar -xzf docker.tgz
docker build --platform linux/amd64 -t campfire-native:4683831 campfire-docker
```

The downloaded `campfire-linux-amd64` is the exact published executable;
rebuilding C can produce a different executable hash with a different compiler.
Compare downloaded files to `provenance.json` and record hashes of new builds.

## Convert a source checkout

Requirements: Git, Rust via rustup, mise, Ruby/Bundler, a C compiler and make,
and Docker for the Linux image. Install Spinel's platform dependencies as
specified in its pinned README. The reference package used Ruby 4.0.6 and
Bundler 4.0.3 for generated assets; Campfire's Rails source tests use Ruby
3.4.10. Roundhouse pins Rust 1.98.1 in `rust-toolchain.toml`.

```sh
build_root="$PWD/campfire-native-source"
mkdir -p "$build_root"
cd "$build_root"

git clone https://github.com/saeloun/once-campfire.git
git -C once-campfire checkout --detach 46838319f0256f5d2bcc392f8c3bb6d394dbc2fe

git clone https://github.com/vipulnsward/roundhouse.git
git -C roundhouse checkout --detach be39e428ef6f3a47719d3ab9a46041133146178a

git clone https://github.com/matz/spinel.git
git -C spinel checkout --detach ed603ed595db42626c747988a091c07f54532b94

mise install ruby@4.0.6
mise exec ruby@4.0.6 -- gem install bundler -v 4.0.3
rustup toolchain install 1.98.1 --profile minimal

(cd spinel && mise exec ruby@4.0.6 -- make deps && make)
export PATH="$build_root/spinel/bin:$build_root/spinel:$PATH"
export CARGO_TARGET_DIR="$build_root/roundhouse-target"

cd "$build_root/roundhouse"
mise exec ruby@4.0.6 -- scripts/build-campfire-archive \
  --out "$build_root/release" \
  --keep-tree "$build_root/emitted" \
  "$build_root/once-campfire"

cd "$build_root/release/campfire"
tar -xzf docker.tgz
docker build --platform linux/amd64 -t campfire-native:4683831 campfire-docker
```

The archive builder performs strict Roundhouse emission, builds assets with
`make assets`, renames the generated entry point to `campfire`, then runs
`spin pack` to bundle generated C, runtime and native package sources. It
produces a Spinel source archive and a separate Docker/C archive. Keep assets
enabled and require `docker.tgz` to exist; the script can skip that archive
when `spin` is absent. Resolve unsupported constructs rather than enabling
`--allow-unsupported` for a release.

## Extract and check the executable

```sh
container_id=$(docker create --platform linux/amd64 campfire-native:4683831)
docker cp "$container_id":/app/campfire ./campfire-linux-amd64
docker rm "$container_id"
file campfire-linux-amd64
```

Expect a Linux x86-64 ELF executable. Linux AMD64 builds on an ARM machine
need Docker emulation or an AMD64 builder. The binary requires the runtime
libraries and files packaged in the image; copying only the executable to an
arbitrary machine is insufficient.

For an isolated local smoke check, use a new volume and a loopback port:

```sh
docker run --rm -d --name campfire-native-check --platform linux/amd64 \
  -p 127.0.0.1:14300:3000 \
  -v campfire-native-check-data:/app/storage campfire-native:4683831

# After the server starts, inspect first-run setup and an embedded asset.
curl -fsSL http://127.0.0.1:14300/ -o first-run.html
curl -fsS http://127.0.0.1:14300/assets/deccan-queen/deccan-logo-sharp.png -o logo.png
docker stop campfire-native-check
```

Before rollout, exercise login, invitation, message delivery and attachments
with synthetic accounts on the compiled server. Rails source tests alone do
not verify native behavior. The reference release's native verification and
browser-coverage limits are recorded in `validation.md`.

## DQOR configuration and deployment

`GOOGLE_LOGIN_ENABLED=true` delegates authentication to the main DQOR site,
which owns Google/email-link login and recovery. Campfire redeems a single-use
grant, matches the verified email to its own user and creates its own session.
The reference callback is `https://chat.deccanqueenonrails.com/session/google`.
Google's OAuth callback belongs to the main DQOR app. A different identity
provider or hostname needs corresponding application and callback changes;
toggling the environment flag does not configure an identity provider.

`RUNTIME_DASHBOARD_ENABLED=true` enables `/runtime` and `/runtime/stats`.
The dashboard reads collector output from `RUNTIME_STATS_PATH`, defaulting to
`storage/runtime_stats.json`; a binary build alone does not start the collector.
The existing deployment also uses `CAMPFIRE_ADMIN_EMAILS`,
`CAMPFIRE_SPEAKER_EMAILS` and `CAMPFIRE_SPEAKER_ROOM_ID` for verified access.
Keep live configuration in the deployment's secret store, outside Git.

For an existing deployment, retain the same `/app/storage` mount, SQLite data,
`storage/secret_key_base`, environment configuration and TLS/WebSocket proxy.
Back up storage consistently while the service is stopped, retain the previous
image, and replace the image only after native checks pass. Ship the matching
static assets with the executable. Verify health, SSO and telemetry afterwards.
If rolling back, restore the previous image/configuration while preserving
messages written since deployment.

# FASTBuild (alternative build backend)

TheRock's default build backend is [Ninja](https://ninja-build.org/), driven by
CMake. Ninja remains the supported path for CI and day-to-day development.

This document describes an **optional** [FASTBuild](https://www.fastbuild.org/)
backend using CMake's `FASTBuild` generator (CMake **4.2+**). The super-project
already propagates `CMAKE_GENERATOR` into every sub-project configure and uses
`cmake --build` for compile/install phases, so no parallel build graph is
required for an initial spike.

## Setup

There are two options to setup the FASTBuild backend:

- A: Use prebuilt container image
- B: Use empty container image and setup manually

### A. Use prebuilt container image

#### 1. Run container (prebuilt)

```bash
docker run -it --rm \
  --memory=16g \
  --user root \
  --name rocm-fastbuild \
  -v "$(pwd):/workspace" \
  -w /workspace \
  therock-build-tools:latest \
  bash
```

#### 2. Setup TheRock

```bash
cd /path/to/TheRock    # your existing checkout / mount

python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python3 ./build_tools/fetch_sources.py
```

### B. Use empty container image

#### 1. Run container (empty)

```bash
docker run -it --rm \
  --memory=16g \
  --user root \
  --name rocm-fastbuild \
  -v "$(pwd):/workspace" \
  -w /workspace \
  ghcr.io/rocm/no_rocm_image_ubuntu24_04:latest \
  bash
```

#### 2. Install dependencies

##### OS packages (Ubuntu/Debian example)

```bash
sudo apt update
sudo apt install -y \
  git python3 python3-venv python3-dev pkg-config \
  g++ cmake ninja-build patchelf meson \
  unzip wget ca-certificates
```

##### CMake 4.2+ (required for `-G FASTBuild`)

```bash
wget https://github.com/Kitware/CMake/releases/download/v4.2.3/cmake-4.2.3-linux-x86_64.sh
chmod +x cmake-4.2.3-linux-x86_64.sh
sudo ./cmake-4.2.3-linux-x86_64.sh --skip-license --prefix=/usr/local
export PATH="/usr/local/bin:$PATH"
cmake --version   # must show 4.2.x
```

##### FASTBuild binary (not GitHub release zips)

```bash
FB_VERSION=1.20
cd /tmp
wget "https://fastbuild.org/downloads/v${FB_VERSION}/FASTBuild-Linux-x64-v${FB_VERSION}.zip" -O fastbuild.zip
file fastbuild.zip   # must say: Zip archive (~1.2M), not HTML
unzip -o fastbuild.zip
sudo install -m 755 fbuild /usr/local/bin/fbuild
fbuild -version    # >= 1.17
```

#### 3. Setup TheRock

##### TheRock repo (unchanged tree)

```bash
cd /path/to/TheRock    # your existing checkout / mount

python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

python3 ./build_tools/fetch_sources.py
```

##### Export path

```bash
export PATH="/usr/local/bin:$PATH"
```

## Build

### FASTBuild leaf

```bash
cmake --preset linux-fastbuild-leaf -B /tmp/build-fastbuild-leaf -S . \
  -DTHEROCK_AMDGPU_FAMILIES=gfx942

cmake --build /tmp/build-fastbuild-leaf --target therock-fmt
```

### Ninja leaf (for comparison)

```bash
cmake --preset linux-ninja-leaf -B /tmp/build-ninja-leaf -S . \
  -DTHEROCK_AMDGPU_FAMILIES=gfx942

cmake --build /tmp/build-ninja-leaf --target therock-fmt
```

### FASTBuild medium (fftw3, distributed)

The `linux-fastbuild-medium` preset adds FFTW3 (double- and single-precision). FFTW
has many host C translation units, so it is a better stress test for `-dist` than
`therock-fmt` (which finishes in seconds and rarely offloads work).

Prerequisites: at least one worker reachable from the driver (see
[Distributed build](#distributed-build)). The recommended setup runs
`fbuildworker` in the same `therock-build-tools:latest` image on each worker node.

```bash
export PATH="/opt/therock-fastbuild-env/opt/bin:$PATH"
BUILD=/tmp/build-fastbuild-medium

cmake --preset linux-fastbuild-medium -B "$BUILD" -S . \
  -DTHEROCK_AMDGPU_FAMILIES=gfx942

# Super-project configure auto-detects GCC helper tools (cc1, as, shared libs, …)
# and writes them into each sub-project `*_init.cmake` for FASTBuild. After changing
# TheRock cmake files, wipe `$BUILD` and reconfigure from scratch.

# Fetch sources and generate sub-project FASTBuild files (no compile yet).
cmake --build "$BUILD" --target \
  therock-fftw3+configure \
  therock-fftw3f+configure

# Sub-project CMake trees live under …/build_fftw3/build (not build_fftw3 itself).
ls "$BUILD/third-party/fftw3/build_fftw3/build/CMakeCache.txt"

# Cap local parallelism inside the container (avoids "Failed to spawn process. Error: 9").
cmake --build "$BUILD/third-party/fftw3/build_fftw3/build"  -- -dist -j32 -summary
cmake --build "$BUILD/third-party/fftw3/build_fftw3f/build" -- -dist -j32 -summary
```

### Ninja comparison (driver only)

Same FFTW3 scope on one node (`linux-ninja-leaf` plus `THEROCK_ENABLE_FFTW3=ON`).
Use a separate build tree; compile inside the sub-project `…/build_fftw3f/build`
directory (same layout as FASTBuild above).

```bash
BUILD_NINJA=/tmp/build-ninja-medium

cmake --preset linux-ninja-leaf -B "$BUILD_NINJA" -S . \
  -DTHEROCK_AMDGPU_FAMILIES=gfx942 \
  -DTHEROCK_ENABLE_FFTW3=ON

cmake --build "$BUILD_NINJA" --target therock-fftw3f+configure

time cmake --build "$BUILD_NINJA/third-party/fftw3/build_fftw3f/build" -- -j32
```

For timing, use `--target clean` on each backend (do not delete `CMakeFiles/` by
hand — that leaves a broken `build.ninja`):

```bash
time cmake --build "$BUILD_NINJA/third-party/fftw3/build_fftw3f/build" --target clean
time cmake --build "$BUILD_NINJA/third-party/fftw3/build_fftw3f/build" -- -j32

time cmake --build "$BUILD/third-party/fftw3/build_fftw3f/build" --target clean
time cmake --build "$BUILD/third-party/fftw3/build_fftw3f/build" -- -dist -j32 -summary
```

Use `-distverbose` while debugging. Optional: `-forceremote` to push more jobs to
workers during testing.

**Verify distribution.** A successful run prints
`Distributed Compilation : N Workers in pool` and object lines tagged
`<REMOTE: worker-ip>`. The `-summary` report should show `Remote CPU` greater than
zero on a **clean** build. Incremental rebuilds often hit the object cache and show
mostly `<LOCAL>` with `Remote CPU : 0.000s` even when workers are healthy. To
measure offloading, delete compiled objects first:

```bash
rm -rf "$BUILD/third-party/fftw3/build_fftw3/build/CMakeFiles"
rm -f  "$BUILD/third-party/fftw3/build_fftw3/build"/libfftw3*.so* "$BUILD/third-party/fftw3/build_fftw3/build/bench"
cmake --build "$BUILD/third-party/fftw3/build_fftw3/build" --target all -- -dist -j32 -summary
```

`<LOCAL RACE>` lines (local and remote both touched the same object) are usually
harmless when the build finishes with `FBuild: OK`.

If the build fails with `Failed to spawn process. Error: 9`, lower `-j` (for
example `-j16`) or raise container limits (`--ulimit nofile=65536:65536`,
`--pids-limit=-1`). If `-summary` shows `Remote CPU : 0.000s` on a clean build,
confirm `FASTBUILD_WORKERS` is set in the driver shell and workers are listening on
port 31264.

## Distributed build

FASTBuild distributes compile jobs from a **driver** to **workers** over TCP port
**31264**. The driver passes `-dist` to `fbuild` (via `cmake --build … -- -dist`).

Sources can stay on local disk (for example `~/scratch/TheRock`). Only worker
discovery must be reachable from every participant.


| Method                     | When to use                                                                                   |
| -------------------------- | --------------------------------------------------------------------------------------------- |
| Docker worker (recommended)| Same `therock-build-tools:latest` image on driver and workers; avoids toolchain mismatches  |
| `FASTBUILD_WORKERS`        | Worker IP list; use with `--network host` on the driver container                              |
| `FASTBUILD_BROKERAGE_PATH` | Shared directory on NFS visible on all hosts (for example `/opt/head/.fastbuild.brokerage`)   |


### Recommended: worker in the same container image

Run `fbuildworker` inside `therock-build-tools:latest` on each worker node so the
remote sandbox uses the **same GCC, binutils, and FASTBuild** as the driver. This
avoids errors such as `libbfd-2.42-system.so: cannot open shared object file` when
the driver container (Ubuntu 24) syncs `as` to a host worker with a different OS
(for example Ubuntu 26).

On each worker node (once):

```bash
docker run -d --restart unless-stopped \
  --name fbuildworker \
  --network host \
  therock-build-tools:latest \
  bash -c 'fbuildworker -mode=dedicated -cpus=-2'
```

Confirm the worker is listening:

```bash
docker logs fbuildworker
ss -tlnp | grep 31264    # on the worker host
```

To stop or replace the worker:

```bash
docker rm -f fbuildworker
```

### Driver container (`FASTBUILD_WORKERS`)

Use `--network host` so the container can reach workers on the cluster network.
Prefer **IP addresses** in `FASTBUILD_WORKERS` when hostnames do not resolve
inside the container (`hostname -I` on each worker node).

```bash
cd ~/scratch    # parent of TheRock; mounted as /workspace

docker run -it --rm \
  --network host \
  --memory=16g \
  --user root \
  -v "$(pwd):/workspace" \
  -w /workspace/TheRock \
  -e FASTBUILD_WORKERS="10.0.0.2" \
  therock-build-tools:latest \
  bash
```

Inside the container, verify connectivity, then run the
[medium (fftw3) build](#fastbuild-medium-fftw3-distributed):

```bash
nc -zv 10.0.0.2 31264

export PATH="/opt/therock-fastbuild-env/opt/bin:$PATH"
export FASTBUILD_WORKERS="10.0.0.2"   # if not passed via -e
```

A successful distributed build prints `Distributed Compilation : N Workers in pool`
and `<REMOTE: …>` object lines; see [Verify distribution](#fastbuild-medium-fftw3-distributed)
above.

### Alternative: brokerage on shared NFS

When all hosts (and the container) can bind-mount the same NFS path, set the same
`FASTBUILD_BROKERAGE_PATH` on the driver and every worker instead of
`FASTBUILD_WORKERS`:

```bash
export FASTBUILD_BROKERAGE_PATH=/opt/head/.fastbuild.brokerage
mkdir -p "$FASTBUILD_BROKERAGE_PATH"
```

Mount only the brokerage subdirectory into Docker (not all of `/opt/head`):

```bash
docker run -it --rm --network host \
  -v "$(pwd):/workspace" \
  -v /opt/head/.fastbuild.brokerage:/fastbuild-brokerage:rw \
  -w /workspace/TheRock \
  -e FASTBUILD_BROKERAGE_PATH=/fastbuild-brokerage \
  therock-build-tools:latest bash
```

Workers on the host keep `FASTBUILD_BROKERAGE_PATH=/opt/head/.fastbuild.brokerage`.
If Docker cannot mount the NFS path, use `FASTBUILD_WORKERS` as above.

### Advanced: host workers (toolchain sync required)

Only use bare-metal `fbuildworker` on worker hosts when you cannot run Docker there.
The remote worker must be able to run the **exact** compiler toolchain the driver
syncs (GCC helpers, `as`, and their shared libraries). A newer host OS (different
binutils `libbfd` version) typically fails even when `cc1` and `as` are present.

Install FASTBuild on each worker host (once):

```bash
cd /path/to/TheRock
# If the checkout came from Windows, strip CRLF before running the setup script:
sed -i 's/\r$//' build_tools/fastbuild_container_setup.sh dockerfiles/*.sh

bash build_tools/fastbuild_container_setup.sh
source ~/.therock-fastbuild-env/activate.sh
```

Patchelf is only required on the build driver; workers need `fbuildworker` in
`PATH`.

Start workers on the hosts:

```bash
source ~/.therock-fastbuild-env/activate.sh
fbuildworker -mode=dedicated -cpus=-2 &
ss -tlnp | grep 31264
```

TheRock auto-detects GCC helper tools and shared libraries for distributed compiles
when using the FASTBuild generator (`CMAKE_FASTBUILD_COMPILER_EXTRA_FILES`,
`CMAKE_FASTBUILD_ENV_OVERRIDES=LD_LIBRARY_PATH=.`). If remote compiles still fail
with `cannot execute 'cc1'`, `cannot execute 'as'`, or missing `libbfd-*.so`, prefer
the [Docker worker](#recommended-worker-in-the-same-container-image) approach, or
override the extra files manually on the driver before sub-project configure:

```bash
CC1=$(find /usr/libexec/gcc /usr/lib/gcc -name cc1 2>/dev/null | head -1)
GCC_EXEC_DIR=$(dirname "$CC1")
AS=$(readlink -f "$(which x86_64-linux-gnu-as || which as)")
FB_EXTRA="$(find "$GCC_EXEC_DIR" -maxdepth 1 -type f -printf '%p;')${AS};"
FB_EXTRA="${FB_EXTRA}$(ldd "$AS" | awk '/=> \// {print $3}' | tr '\n' ';')"

cmake --preset linux-fastbuild-medium -B "$BUILD" -S . \
  -DTHEROCK_AMDGPU_FAMILIES=gfx942 \
  -DCMAKE_FASTBUILD_COMPILER_EXTRA_FILES="${FB_EXTRA}" \
  -DCMAKE_FASTBUILD_ENV_OVERRIDES="LD_LIBRARY_PATH=."
rm -f "$BUILD/third-party/fftw3/build_fftw3/stamp/configure.stamp"
cmake --build "$BUILD" --target therock-fftw3+configure
grep ExtraFiles "$BUILD/third-party/fftw3/build_fftw3/build/fbuild.bff" | head
```

### Superbuild note

TheRock sub-projects are built with plain `cmake --build` and do not pass `-dist`
automatically. The leaf example above enables distribution directly; a full
superbuild needs `-dist` on each sub-build (for example via a `cmake` wrapper) or
building individual component trees with `cmake --build … -- -dist`.

## Prebuilt container image

If the prebuilt container image does not exist, build it:

```bash
docker build \
  -f dockerfiles/fastbuild_driver.Dockerfile \
  -t therock-build-tools:latest \
  .
```


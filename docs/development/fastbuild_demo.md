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

## Distributed build example

FASTBuild distributes compile jobs from a **driver** to **workers** over TCP port
**31264**. Workers run `fbuildworker` on the host OS; the driver passes `-dist` to
`fbuild` (via `cmake --build … -- -dist`).

Sources can stay on local disk (for example `~/scratch/TheRock`). Only worker
discovery must be reachable from every participant. Two options:


| Method                     | When to use                                                                                   |
| -------------------------- | --------------------------------------------------------------------------------------------- |
| `FASTBUILD_WORKERS`        | Docker driver without NFS bind mounts; use worker **IPs** if the container has no cluster DNS |
| `FASTBUILD_BROKERAGE_PATH` | Shared directory on NFS visible on all hosts (for example `/opt/head/.fastbuild.brokerage`)   |


### 1. Install FASTBuild on each worker host (once)

```bash
cd /path/to/TheRock
# If the checkout came from Windows, strip CRLF before running the setup script:
sed -i 's/\r$//' build_tools/fastbuild_container_setup.sh dockerfiles/*.sh

bash build_tools/fastbuild_container_setup.sh
source ~/.therock-fastbuild-env/activate.sh
```

Patchelf is only required on the build driver; workers need `fbuildworker` in
`PATH`.

### 2. Start workers on the hosts

On each node that should accept remote compile jobs:

```bash
source ~/.therock-fastbuild-env/activate.sh
fbuildworker -mode=dedicated -cpus=-2 &
ss -tlnp | grep 31264    # confirm the worker is listening
```

### 3. Run the driver in a container (`FASTBUILD_WORKERS`)

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
  -e FASTBUILD_WORKERS="10.0.0.2;10.0.0.3" \
  therock-build-tools:latest \
  bash
```

Inside the container, verify connectivity and build:

```bash
nc -zv 10.0.0.2 31264

export PATH="/opt/therock-fastbuild-env/opt/bin:$PATH"

cmake --preset linux-fastbuild-leaf -B /tmp/build-fb -S . \
  -DTHEROCK_AMDGPU_FAMILIES=gfx942

cmake --build /tmp/build-fb --target therock-fmt -- -dist -summary
```

A successful distributed build prints `Distributed Compilation : N Workers in pool`.
Use `-distverbose` while debugging.

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


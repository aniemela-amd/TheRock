# FASTBuild (alternative build backend)

TheRock's default build backend is [Ninja](https://ninja-build.org/), driven by
CMake. Ninja remains the supported path for CI and day-to-day development.

This document describes an **optional** [FASTBuild](https://www.fastbuild.org/)
backend using CMake's `FASTBuild` generator (CMake **4.2+**). The super-project
already propagates `CMAKE_GENERATOR` into every sub-project configure and uses
`cmake --build` for compile/install phases, so no parallel build graph is
required for an initial spike.

## Setup

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
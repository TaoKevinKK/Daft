#!/usr/bin/env bash
set -euo pipefail

# =============================
# Auto-detect system and params
# =============================
OS="$(uname | tr '[:upper:]' '[:lower:]')"
if [ "$OS" == "darwin" ]; then
    OS="macos"
elif [ "$OS" == "linux" ]; then
    OS="ubuntu"
else
    echo "Unsupported OS: $OS"
    exit 1
fi

ARCH="$(uname -m)"
if [ "$ARCH" == "aarch64" ] || [ "$ARCH" == "arm64" ]; then
    ARCH="aarch64"
else
    ARCH="x86_64"
fi

PYTHON_BIN=$(which python3 || which python)
PYTHON_VERSION=$($PYTHON_BIN -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
echo "Detected OS=$OS ARCH=$ARCH Python=$PYTHON_VERSION"

# =============================
# Build config defaults
# =============================
LTS=false        # 自动检测 LTS 文件或标志，可根据项目逻辑改
USE_LTO=true
BUILD_TYPE="release"

if [ -f ".lts" ]; then
    LTS=true
fi

echo "Build config: LTS=$LTS USE_LTO=$USE_LTO BUILD_TYPE=$BUILD_TYPE"

# =============================
# Environment setup
# =============================
export DAFT_ANALYTICS_ENABLED='0'
export UV_SYSTEM_PYTHON=1
export RUST_DAFT_PKG_BUILD_TYPE="${BUILD_TYPE}"

# Setup Bun
if ! command -v bun &>/dev/null; then
    echo "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
fi

# Upgrade pip and install Python dependencies
$PYTHON_BIN -m pip install --upgrade pip
$PYTHON_BIN -m pip install uv twine yq setuptools_scm

# =============================
# Patch package version
# =============================
VERSION="$($PYTHON_BIN -m setuptools_scm | sed 's/\.dev/-dev/g')"
echo "Setting package version to: $VERSION"

# =============================
# Configure RUSTFLAGS
# =============================
if [ "$ARCH" == "x86_64" ]; then
    if [ "$LTS" == "true" ]; then
        export RUSTFLAGS="-C target-feature=+sse3,+ssse3,+sse4.1,+sse4.2,+popcnt,+cmpxchg16b"
        export CFLAGS="-msse3 -mssse3 -msse4.1 -msse4.2 -mpopcnt -mcx16"
    else
        export RUSTFLAGS="-C target-feature=+sse3,+ssse3,+sse4.1,+sse4.2,+popcnt,+cmpxchg16b,+avx,+avx2,+fma,+bmi1,+bmi2,+lzcnt,+pclmulqdq,+movbe -Z tune-cpu=skylake"
        export CFLAGS="-msse3 -mssse3 -msse4.1 -msse4.2 -mpopcnt -mcx16 -mavx -mavx2 -mfma -mbmi -mbmi2 -mlzcnt -mpclmul -mmovbe -mtune=skylake"
    fi
fi

if [ "$OS" == "macos" ] && [ "$ARCH" == "aarch64" ]; then
    export RUSTFLAGS="-Ctarget-cpu=apple-m1"
    export CFLAGS="-mtune=apple-m1"
fi

# =============================
# Build Dashboard frontend
# =============================
echo "Building Daft dashboard frontend..."
pushd ./src/daft-dashboard/frontend
bun install
bun run build
popd

# =============================
# Build wheel using maturin
# =============================
PROFILE="release"
if [ "$USE_LTO" == "true" ]; then
    PROFILE="release-lto"
fi

echo "Building wheel for OS=$OS ARCH=$ARCH PROFILE=$PROFILE..."
export PYTHON_SYS_EXECUTABLE=$(which python3)

if [ "$OS" == "macos" ] || [ "$OS" == "windows" ]; then
    maturin develop --release --target $ARCH --strip --out dist
elif [ "$OS" == "ubuntu" ] && [ "$ARCH" == "x86_64" ]; then
    maturin develop --release --target x86_64-unknown-linux-gnu --manylinux 2_24 --sdist --out dist
elif [ "$OS" == "ubuntu" ] && [ "$ARCH" == "aarch64" ]; then
    export JEMALLOC_SYS_WITH_LG_PAGE=16
    maturin develop --release --target aarch64-unknown-linux-gnu --manylinux 2_24 --sdist --out dist
else
    echo "Unsupported OS/ARCH combination: $OS/$ARCH"
    exit 1
fi

echo "Wheel build completed. Artifacts in ./dist"

#!/bin/bash
set -e

if ! command -v realpath >/dev/null 2>&1; then
    cat <<EOF >&2
Error: 'realpath' command is required but not found.
EOF
    exit 1
fi

# Default parameters
STAGES="all"
STAGE1_INSTALL_DIR="$HOME/llvm-stage1"
STAGE2_INSTALL_DIR="$HOME/llvm"
ENABLE_INSTALL_STAGE1=true
ENABLE_INSTALL_STAGE2=true

print_help() {
    cat << EOF
Usage: $0 [OPTIONS]
Options:
  --stages=STAGE            Specify build stages (1, 2, all). Default: all
  --stage1-install-dir=DIR  Stage1 installation directory. Default: \$HOME/llvm-stage1
  --stage2-install-dir=DIR  Stage2 installation directory. Default: \$HOME/llvm
  --no-install-stage1       Skip installation for stage1
  --no-install-stage2       Skip installation for stage2
  -h, --help                Show this help message
Example:
  $0 --stages=1 --stage1-install-dir=/opt/llvm-stage1
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        --stages=*)
            STAGES="${1#*=}"
            ;;
        --stage1-install-dir=*)
            STAGE1_INSTALL_DIR=$(realpath -m -- "${1#*=}")
            ;;
        --stage2-install-dir=*)
            STAGE2_INSTALL_DIR=$(realpath -m -- "${1#*=}")
            ;;
        --no-install-stage1)
            ENABLE_INSTALL_STAGE1=false
            ;;
        --no-install-stage2)
            ENABLE_INSTALL_STAGE2=false
            ;;
        *)
            echo "Error: Unknown option $1"
            exit 1
            ;;
    esac
    shift
done

# Validate stages parameter
case "$STAGES" in
    1|2|all) ;;
    *)
        echo "Error: Invalid stages value. Valid options: 1, 2, all"
        exit 1
        ;;
esac

# Determine which stages to run
RUN_STAGE1=false
RUN_STAGE2=false

if [[ "$STAGES" == "1" ]]; then
    RUN_STAGE1=true
elif [[ "$STAGES" == "2" ]]; then
    RUN_STAGE2=true
elif [[ "$STAGES" == "all" ]]; then
    RUN_STAGE1=true
    RUN_STAGE2=true
fi

# Check Stage 1 Build
check_stage1_build() {
    local found=0

    # Check installation directory
    if $ENABLE_INSTALL_STAGE1 && [ -x "$STAGE1_INSTALL_DIR/bin/clang" ]; then
        found=1
        echo "Found stage1 installation at: $STAGE1_INSTALL_DIR"
    # Check build directory
    elif [ -x "build-stage1/bin/clang" ]; then
        found=1
        echo "Found stage1 build artifacts in build-stage1/"
    fi

    if [ $found -eq 0 ]; then
        echo -e "\nError: Stage 1 build not found!"
        echo "Possible solutions:"
        echo "1. Run stage1 first with: $0 --stages=1"
        echo "2. If using custom paths, verify these locations exist:"
        echo "   - Installed: $STAGE1_INSTALL_DIR/bin/clang"
        echo "   - Built:     build-stage1/bin/clang"
        exit 1
    fi
}

# Stage 1: Bootstrap compiler build
if $RUN_STAGE1; then
    echo "=== Running Stage 1 Build ==="

    # Configure stage 1
    cmake -S llvm -B build-stage1 -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$STAGE1_INSTALL_DIR" \
        -DCMAKE_BUILD_RPATH='$ORIGIN/../lib;$ORIGIN/../lib/x86_64-unknown-linux-gnu' \
        -DCMAKE_INSTALL_RPATH="$STAGE1_INSTALL_DIR/lib;$STAGE1_INSTALL_DIR/lib/x86_64-unknown-linux-gnu" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=OFF \
        -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF \
        -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;lldb" \
        -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind;compiler-rt" \
        -DLLVM_TARGETS_TO_BUILD=host

    # Build stage 1
    cmake --build build-stage1

    # Install stage 1 if enabled
    if $ENABLE_INSTALL_STAGE1; then
        echo "=== Installing Stage 1 Build ==="
        cmake --build build-stage1 --target install
        # Validate installation
        if [ ! -x "$STAGE1_INSTALL_DIR/bin/clang" ]; then
            echo "Error: Stage1 installation failed! clang not found in $STAGE1_INSTALL_DIR/bin"
            exit 1
        fi
    fi
fi

# Stage 2: Self-hosted compiler build
if $RUN_STAGE2; then
    echo "=== Running Stage 2 Build ==="

    # Force check stage1 build
    check_stage1_build

    # Intelligent Path Selection (Prioritize Installation Path)
    if $ENABLE_INSTALL_STAGE1 && [ -d "$STAGE1_INSTALL_DIR/bin" ]; then
        STAGE1_BIN_DIR="$STAGE1_INSTALL_DIR/bin"
        STAGE1_LIB_DIR="$STAGE1_INSTALL_DIR/lib"
    elif [ -d "build-stage1/bin" ]; then
        STAGE1_BIN_DIR=$(realpath -m -- "build-stage1/bin")
        STAGE1_LIB_DIR=$(realpath -m -- "build-stage1/lib")
    else
        echo "Error: No valid stage1 binaries found!"
        exit 1
    fi

    # Validate Required Files
    REQUIRED_FILES=(
        "$STAGE1_BIN_DIR/clang"
        "$STAGE1_LIB_DIR/libclang.so"
    )
    for file in "${REQUIRED_FILES[@]}"; do
        if [ ! -e "$file" ]; then
            echo "Error: Missing required stage1 file: $file"
            exit 1
        fi
    done

    STAGE1_ARCH_LIB_DIR="$STAGE1_LIB_DIR/x86_64-unknown-linux-gnu"
    [ -d "$STAGE1_ARCH_LIB_DIR" ] || STAGE1_ARCH_LIB_DIR="$STAGE1_LIB_DIR" # Compatible with no architecture subdirectory

    # Set environment variables for stage 2
    export PATH="$STAGE1_BIN_DIR:$PATH"
    export LD_LIBRARY_PATH="$STAGE1_LIB_DIR:$STAGE1_ARCH_LIB_DIR:$LD_LIBRARY_PATH"

    echo "Using stage1 binaries from: $STAGE1_BIN_DIR"
    echo "Current PATH: $PATH"
    echo "Current LD_LIBRARY_PATH: $LD_LIBRARY_PATH"

    # Configure stage 2
    cmake -S llvm -B build-stage2 -G Ninja \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$STAGE2_INSTALL_DIR" \
        -DCMAKE_BUILD_RPATH='$ORIGIN/../lib;$ORIGIN/../lib/x86_64-unknown-linux-gnu' \
        -DCMAKE_INSTALL_RPATH="$STAGE2_INSTALL_DIR/lib;$STAGE2_INSTALL_DIR/lib/x86_64-unknown-linux-gnu" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=OFF \
        -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF \
        -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;lldb" \
        -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind;compiler-rt" \
        -DLLVM_TARGETS_TO_BUILD=host \
        -DLLVM_ENABLE_LLD=ON \
        -DLLVM_ENABLE_LIBCXX=ON \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++

    # Build stage 2
    cmake --build build-stage2

    # Install stage 2 if enabled
    if $ENABLE_INSTALL_STAGE2; then
        echo "=== Installing Stage 2 Build ==="
        cmake --build build-stage2 --target install
        # Validate installation
        if [ ! -x "$STAGE2_INSTALL_DIR/bin/clang" ]; then
            echo "Error: Stage2 installation failed! clang not found in $STAGE2_INSTALL_DIR/bin"
            exit 1
        fi
    fi
fi

echo "=== Build completed successfully ==="

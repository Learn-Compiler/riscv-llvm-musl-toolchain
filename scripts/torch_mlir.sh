#!/usr/bin/env bash
# ==============================================================================
# scripts/torch_mlir.sh - 配置并构建 torch-mlir 组件 (可扩展插件阶段)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

step_torch_mlir() {
  if is_done torch_mlir; then
    ok "torch-mlir 已构建完成，跳过"
    return
  fi

  local torch_src="${TORCH_MLIR_SRC:-$SRC/third_party/torch-mlir}"
  if [ ! -d "$torch_src" ] || [ ! -f "$torch_src/CMakeLists.txt" ]; then
    warn "torch-mlir 源码未就绪 ($torch_src)"
    echo "  提示: 后续引入 torch-mlir 时，可将源码放置在 third_party/torch-mlir"
    echo "        或通过参数挂载: ./build.sh --torch-mlir-src /path/to/torch-mlir --step torch-mlir"
    return 0
  fi

  log "4b/5 配置并构建 torch-mlir"
  local TORCH_BUILD="$SRC/build-torch-mlir"
  mkdir -p "$TORCH_BUILD"

  local extra_torch_flags=()
  if [ -n "${TORCH_MLIR_EXTRA_CMAKE_ARGS:-}" ]; then
    read -r -a extra_torch_flags <<< "${TORCH_MLIR_EXTRA_CMAKE_ARGS}"
  fi

  # 使用刚构建安装好的 LLVM/Clang 及 MLIR cmake 配置目录
  "$BOOT/bin/cmake" -G Ninja \
    -S "$torch_src" \
    -B "$TORCH_BUILD" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_C_COMPILER="$INSTALL/bin/clang" \
    -DCMAKE_CXX_COMPILER="$INSTALL/bin/clang++" \
    -DMLIR_DIR="$INSTALL/lib/cmake/mlir" \
    -DLLVM_DIR="$INSTALL/lib/cmake/llvm" \
    "${extra_torch_flags[@]}"

  log "4b/5 编译 torch-mlir (-j$JOBS)"
  "$BOOT/bin/ninja" -C "$TORCH_BUILD" -j"$JOBS"

  log "4b/5 安装 torch-mlir"
  "$BOOT/bin/ninja" -C "$TORCH_BUILD" install

  mark torch_mlir
  ok "torch-mlir 构建并安装完成"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_torch_mlir
fi

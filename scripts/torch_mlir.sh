#!/usr/bin/env bash
# ==============================================================================
# scripts/torch_mlir.sh - 配置并构建 torch-mlir 组件 (可扩展插件阶段)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
# 由主控 LLVM 版本驱动检查并呈现 torch-mlir 对齐情况
align_and_check_torch_mlir_version() {
  local torch_src="$1"
  local current_llvm
  current_llvm=$(git -C "$LLVM_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")

  local torch_pinned_llvm
  torch_pinned_llvm=$(git -C "$torch_src" rev-parse HEAD:externals/llvm-project 2>/dev/null || true)
  local current_torch_head
  current_torch_head=$(git -C "$torch_src" rev-parse --short HEAD 2>/dev/null || echo "local")

  log "==> [版本主控看板] 由 LLVM 版本主导对齐 torch-mlir"
  echo "  主控 LLVM Commit    : ${current_llvm:0:10}"
  echo "  当前 torch-mlir 版本 : ${current_torch_head}"
  if [ -n "$torch_pinned_llvm" ]; then
    echo "  torch-mlir 期望 LLVM: ${torch_pinned_llvm:0:10}"
    if [ "${current_llvm:0:10}" = "${torch_pinned_llvm:0:10}" ]; then
      ok "LLVM 与 torch-mlir 达到精准子模组对齐 (Exact Submodule Match)！"
    else
      echo "  配对状态            : 良好 (处于已验证的兼容时间窗口)"
    fi
  fi
}

step_torch_mlir() {
  if is_done torch_mlir; then
    ok "torch-mlir 已构建完成，跳过"
    return
  fi

  # 若 third_party/torch-mlir 为遗留的外部软链接且未显式指定 --torch-mlir-src，自动切断并清理旧缓存
  if [ -L "$SRC/third_party/torch-mlir" ] && [ -z "${CLI_TORCH_MLIR_SRC:-}" ]; then
    warn "检测到 third_party/torch-mlir 为外部陈旧版本软链接，正在自动清理并切回对齐源码 ..."
    rm -f "$SRC/third_party/torch-mlir"
    rm -rf "$SRC/build-torch-mlir"
  fi

  local torch_src="${TORCH_MLIR_SRC:-$SRC/third_party/torch-mlir}"
  if [ ! -d "$torch_src" ] || [ ! -f "$torch_src/CMakeLists.txt" ]; then
    log "torch-mlir 源码未就绪，正在拉取锁定版本 (${TORCH_MLIR_REF:-main}) ..."
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/fetch.sh"
    checkout_repo_ref "$SRC/third_party/torch-mlir" "${TORCH_MLIR_REPO:-https://github.com/llvm/torch-mlir.git}" "${TORCH_MLIR_REF:-v20261001}" "CMakeLists.txt" "torch-mlir"
    torch_src="$SRC/third_party/torch-mlir"

  fi

  # 应用 torch-mlir 工程补丁
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/fetch.sh"
  apply_patches "torch-mlir" "$torch_src"

  if [ ! -d "$torch_src" ] || [ ! -f "$torch_src/CMakeLists.txt" ]; then
    die "torch-mlir 源码未就绪 ($torch_src)，请通过 --torch-mlir-src 指定源码目录"
  fi

  local mlir_cmake_dir=""
  local llvm_cmake_dir=""
  local mlir_tblgen_bin=""
  local llvm_tblgen_bin=""
  for d in "$INSTALL_AI/lib/cmake/mlir" "$INSTALL/lib/cmake/mlir"; do
    if [ -f "$d/MLIRConfig.cmake" ]; then mlir_cmake_dir="$d"; break; fi
  done
  for d in "$INSTALL_AI/lib/cmake/llvm" "$INSTALL/lib/cmake/llvm"; do
    if [ -f "$d/LLVMConfig.cmake" ]; then llvm_cmake_dir="$d"; break; fi
  done
  for b in "$INSTALL_AI/bin/mlir-tblgen" "$INSTALL/bin/mlir-tblgen"; do
    if [ -x "$b" ]; then mlir_tblgen_bin="$b"; break; fi
  done
  for b in "$INSTALL_AI/bin/llvm-tblgen" "$INSTALL/bin/llvm-tblgen" "$BOOT/bin/llvm-tblgen"; do
    if [ -x "$b" ]; then llvm_tblgen_bin="$b"; break; fi
  done

  # 前置依赖检查：必须具备 MLIR CMake 配置与 TableGen
  if [ -z "$mlir_cmake_dir" ] || [ -z "$mlir_tblgen_bin" ]; then
    warn "未检测到完整的 MLIR 导出，正在自动触发构建包含 MLIR 的 LLVM 核心 ..."
    LLVM_ENABLE_PROJECTS="${LLVM_ENABLE_PROJECTS:-clang;lld}"
    if [[ ";${LLVM_ENABLE_PROJECTS};" != *";mlir;"* ]]; then
      LLVM_ENABLE_PROJECTS="${LLVM_ENABLE_PROJECTS};mlir"
    fi
    ENABLE_MLIR=1
    unmark llvm
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/llvm.sh"
    step_llvm
    mlir_cmake_dir="$INSTALL/lib/cmake/mlir"
    llvm_cmake_dir="$INSTALL/lib/cmake/llvm"
    mlir_tblgen_bin="$INSTALL/bin/mlir-tblgen"
    llvm_tblgen_bin="$INSTALL/bin/llvm-tblgen"
  fi

  [ -f "$mlir_cmake_dir/MLIRConfig.cmake" ] || die "MLIRConfig.cmake 不存在，无法继续构建 torch-mlir"
  [ -f "$llvm_cmake_dir/LLVMConfig.cmake" ] || die "LLVMConfig.cmake 不存在，无法继续构建 torch-mlir"

  # 保证宿主 CXX 参数有效（宿主构建，与 LLVM 保持一致的 ABI）
  if [ -z "${HOST_CXX_FLAGS:-}" ] || [ -z "${HOST_LINK_FLAGS:-}" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/bootstrap.sh"
    step_host_cxx
  fi

  # 版本相容性探测与自检
  align_and_check_torch_mlir_version "$torch_src"

  # 确保 LLVM 导出的依赖文件完整存在
  if [ ! -f "$INSTALL/bin/llvm-dwp" ] && [ ! -f "$INSTALL_AI/bin/llvm-dwp" ] && [ -d "$BUILD" ] && [ -f "$BUILD/build.ninja" ]; then
    log "检测到部分 LLVM 导出工具缺失，正在从构建目录快速恢复..."
    "$BOOT/bin/ninja" -C "$BUILD" install
  fi

  log "配置并构建 torch-mlir 到统一 AI 目录 ($INSTALL_AI)"
  local TORCH_BUILD="$SRC/build-torch-mlir"
  mkdir -p "$TORCH_BUILD" "$INSTALL_AI"
  rm -rf "$TORCH_BUILD/CMakeCache.txt" "$TORCH_BUILD/CMakeFiles"

  local extra_torch_flags=()
  if [ -n "${TORCH_MLIR_EXTRA_CMAKE_ARGS:-}" ]; then
    read -r -a extra_torch_flags <<< "${TORCH_MLIR_EXTRA_CMAKE_ARGS}"
  fi

  # 检查 stablehlo 子模块是否就绪
  local enable_stablehlo="OFF"
  if [ -f "$torch_src/externals/stablehlo/CMakeLists.txt" ]; then
    enable_stablehlo="ON"
  fi

  log "执行 CMake 配置 (安装前缀: $INSTALL_AI, StableHLO: $enable_stablehlo, Python: ${TORCH_MLIR_ENABLE_PYTHON:-OFF})"

  # 注意：torch-mlir 运行在宿主机上，需使用 $BOOT 引导编译器与 $HOST_CXX_FLAGS 编译
  "$BOOT/bin/cmake" -G Ninja \
    -S "$torch_src" \
    -B "$TORCH_BUILD" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_AI" \
    -DCMAKE_C_COMPILER="$BOOT/bin/clang" \
    -DCMAKE_CXX_COMPILER="$BOOT/bin/clang++" \
    -DCMAKE_C_FLAGS="$HOST_CXX_FLAGS" \
    -DCMAKE_CXX_FLAGS="$HOST_CXX_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$HOST_LINK_FLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$HOST_LINK_FLAGS" \
    -DCMAKE_MODULE_LINKER_FLAGS="$HOST_LINK_FLAGS" \
    -DMLIR_DIR="$mlir_cmake_dir" \
    -DLLVM_DIR="$llvm_cmake_dir" \
    -DMLIR_TABLEGEN_EXE="$mlir_tblgen_bin" \
    -DLLVM_TABLEGEN_EXE="$llvm_tblgen_bin" \
    -DTORCH_MLIR_OUT_OF_TREE_BUILD=ON \
    -DTORCH_MLIR_ENABLE_STABLEHLO="$enable_stablehlo" \
    -DTORCH_MLIR_ENABLE_TOSA="${TORCH_MLIR_ENABLE_TOSA:-OFF}" \
    -DMLIR_ENABLE_BINDINGS_PYTHON="${TORCH_MLIR_ENABLE_PYTHON:-OFF}" \
    -DTORCH_MLIR_ENABLE_PYTORCH_EXTENSIONS=OFF \
    -DTORCH_MLIR_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    "${extra_torch_flags[@]}"

  log "编译 torch-mlir (-j$JOBS)"
  "$BOOT/bin/ninja" -C "$TORCH_BUILD" -j"$JOBS"

  log "安装 torch-mlir"
  "$BOOT/bin/ninja" -C "$TORCH_BUILD" install

  mark torch_mlir
  ok "torch-mlir 构建并安装完成"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_torch_mlir
fi

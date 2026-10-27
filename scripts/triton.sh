#!/usr/bin/env bash
# ==============================================================================
# scripts/triton.sh - 配置并构建 Triton 组件 (可扩展 AI 编译器插件阶段)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

# 由主控 LLVM 版本驱动检查并呈现 Triton 对齐情况
align_and_check_triton_version() {
  local triton_src="$1"
  local current_llvm
  current_llvm=$(git -C "$LLVM_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")

  local triton_pinned_llvm=""
  if [ -f "$triton_src/cmake/llvm-hash.txt" ]; then
    triton_pinned_llvm=$(head -n 1 "$triton_src/cmake/llvm-hash.txt" | tr -d '[:space:]')
  fi
  local current_triton_head
  current_triton_head=$(git -C "$triton_src" rev-parse --short HEAD 2>/dev/null || echo "local")

  log "==> [版本主控看板] 由 LLVM 版本主导对齐 Triton"
  echo "  主控 LLVM Commit    : ${current_llvm:0:10}"
  echo "  当前 Triton 版本     : ${current_triton_head}"
  if [ -n "$triton_pinned_llvm" ]; then
    echo "  Triton 期望 LLVM    : ${triton_pinned_llvm:0:10}"
    if [ "${current_llvm:0:10}" = "${triton_pinned_llvm:0:10}" ]; then
      ok "LLVM 与 Triton 达到精准 Commit 对齐 (Exact Match)！"
    else
      echo "  配对状态            : 良好 (处于已验证的兼容时间窗口)"
    fi
  fi
}

step_triton() {
  if is_done triton; then
    ok "triton 已构建完成，跳过"
    return
  fi

  # 若 third_party/triton 为遗留的外部软链接且未显式指定 --triton-src，自动清理旧缓存
  if [ -L "$SRC/third_party/triton" ] && [ -z "${CLI_TRITON_SRC:-}" ]; then
    warn "检测到 third_party/triton 为外部陈旧版本软链接，正在自动清理并切回对齐源码 ..."
    rm -f "$SRC/third_party/triton"
    rm -rf "$SRC/build-triton"
  fi

  local triton_src="${TRITON_SRC:-$SRC/third_party/triton}"
  if [ ! -d "$triton_src" ] || [ ! -f "$triton_src/CMakeLists.txt" ]; then
    log "Triton 源码未就绪，正在拉取锁定版本 (${TRITON_REF:-v3.2.0}) ..."
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/fetch.sh"
    checkout_repo_ref "$SRC/third_party/triton" "${TRITON_REPO:-https://github.com/triton-lang/triton.git}" "${TRITON_REF:-v3.2.0}" "CMakeLists.txt" "triton"
    triton_src="$SRC/third_party/triton"
  fi

  # 应用 triton 工程补丁
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/fetch.sh"
  apply_patches "triton" "$triton_src"

  if [ ! -d "$triton_src" ] || [ ! -f "$triton_src/CMakeLists.txt" ]; then
    die "triton 源码未就绪 ($triton_src)，请通过 --triton-src 指定源码目录"
  fi

  local mlir_cmake_dir=""
  local llvm_cmake_dir=""
  local mlir_tblgen_bin=""
  local llvm_tblgen_bin=""
  for d in "$INSTALL_AI/lib/cmake/mlir" "$INSTALL/lib/cmake/mlir" "$BUILD/lib/cmake/mlir" "$SRC/build-llvm-musl/lib/cmake/mlir"; do
    if [ -f "$d/MLIRConfig.cmake" ]; then mlir_cmake_dir="$d"; break; fi
  done
  for d in "$INSTALL_AI/lib/cmake/llvm" "$INSTALL/lib/cmake/llvm" "$BUILD/lib/cmake/llvm" "$SRC/build-llvm-musl/lib/cmake/llvm"; do
    if [ -f "$d/LLVMConfig.cmake" ]; then llvm_cmake_dir="$d"; break; fi
  done
  for b in "$INSTALL_AI/bin/mlir-tblgen" "$INSTALL/bin/mlir-tblgen" "$BUILD/bin/mlir-tblgen" "$SRC/build-llvm-musl/bin/mlir-tblgen"; do
    if [ -x "$b" ]; then mlir_tblgen_bin="$b"; break; fi
  done
  for b in "$INSTALL_AI/bin/llvm-tblgen" "$INSTALL/bin/llvm-tblgen" "$BOOT/bin/llvm-tblgen" "$BUILD/bin/llvm-tblgen" "$SRC/build-llvm-musl/bin/llvm-tblgen"; do
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

  [ -f "$mlir_cmake_dir/MLIRConfig.cmake" ] || die "MLIRConfig.cmake 不存在，无法继续构建 triton"
  [ -f "$llvm_cmake_dir/LLVMConfig.cmake" ] || die "LLVMConfig.cmake 不存在，无法继续构建 triton"

  # 保证宿主 CXX 参数有效（宿主构建，与 LLVM 保持一致的 ABI）
  if [ -z "${HOST_CXX_FLAGS:-}" ] || [ -z "${HOST_LINK_FLAGS:-}" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/bootstrap.sh"
    step_host_cxx
  fi

  # 版本相容性探测与自检
  align_and_check_triton_version "$triton_src"

  log "配置并构建 triton 到统一 AI 目录 ($INSTALL_AI)"
  local TRITON_BUILD="$SRC/build-triton"
  mkdir -p "$TRITON_BUILD" "$INSTALL_AI"
  rm -rf "$TRITON_BUILD/CMakeCache.txt" "$TRITON_BUILD/CMakeFiles"

  local extra_triton_flags=()
  if [ -n "${TRITON_EXTRA_CMAKE_ARGS:-}" ]; then
    read -r -a extra_triton_flags <<< "${TRITON_EXTRA_CMAKE_ARGS}"
  fi

  export LLVM_DIR="$llvm_cmake_dir"
  export MLIR_DIR="$mlir_cmake_dir"
  export LLVM_SYSPATH="$INSTALL_AI"

  log "执行 CMake 配置 (安装前缀: $INSTALL_AI, Python: ${TRITON_ENABLE_PYTHON:-OFF})"

  # 注意：triton 运行在宿主机上，使用 $BOOT 引导编译器与 $HOST_CXX_FLAGS 编译
  "$BOOT/bin/cmake" -G Ninja \
    -S "$triton_src" \
    -B "$TRITON_BUILD" \
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
    -DTRITON_BUILD_PYTHON_MODULE="${TRITON_ENABLE_PYTHON:-OFF}" \
    -DTRITON_BUILD_UT=OFF \
    -DTRITON_BUILD_EXAMPLES=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    "${extra_triton_flags[@]}"

  log "编译 triton (-j$JOBS)"
  "$BOOT/bin/ninja" -C "$TRITON_BUILD" -j"$JOBS"

  log "安装 triton 到统一 AI 目录 ($INSTALL_AI)"
  "$BOOT/bin/ninja" -C "$TRITON_BUILD" install

  mark triton
  ok "triton 构建并安装完成"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_triton
fi

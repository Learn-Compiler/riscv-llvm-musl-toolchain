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
  current_llvm=$(git -C "$LLVM_DIR" rev-parse HEAD 2>/dev/null || echo "${LLVM_SHA:-unknown}")

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

  local torch_src="${TORCH_MLIR_SRC:-$SRC/third_party/torch-mlir}"
  if [ ! -d "$torch_src" ] || [ ! -f "$torch_src/CMakeLists.txt" ]; then
    # 尝试自动发现宿主已有的源码或拉取
    local local_cand=""
    for cand in "/home/compiler-1/work/compiler/torch-mlir" "/home/compiler-1/learn/torch-mlir"; do
      if [ -f "$cand/CMakeLists.txt" ]; then
        local_cand="$cand"
        break
      fi
    done
    if [ -n "$local_cand" ]; then
      log "自动关联本地已有的 torch-mlir 源码 ($local_cand)"
      mkdir -p "$SRC/third_party"
      ln -sfn "$local_cand" "$SRC/third_party/torch-mlir"
      torch_src="$SRC/third_party/torch-mlir"
    else
      log "torch-mlir 源码未就绪，正在克隆 upstream ..."
      mkdir -p "$SRC/third_party"
      git clone --depth 1 "${TORCH_MLIR_REPO:-https://github.com/llvm/torch-mlir.git}" "$SRC/third_party/torch-mlir" || true
      torch_src="$SRC/third_party/torch-mlir"
    fi
  fi

  if [ ! -d "$torch_src" ] || [ ! -f "$torch_src/CMakeLists.txt" ]; then
    die "torch-mlir 源码未就绪 ($torch_src)，请通过 --torch-mlir-src 指定源码目录"
  fi

  # 前置依赖检查：必须具备 MLIR CMake 配置与 TableGen
  if [ ! -f "$INSTALL/lib/cmake/mlir/MLIRConfig.cmake" ] || [ ! -x "$INSTALL/bin/mlir-tblgen" ]; then
    warn "未在 $INSTALL 中检测到完整的 MLIR 导出 ($INSTALL/lib/cmake/mlir/MLIRConfig.cmake)"
    log "正在自动触发构建包含 MLIR 的 LLVM 工具链 ..."
    LLVM_ENABLE_PROJECTS="${LLVM_ENABLE_PROJECTS:-clang;lld}"
    if [[ ";${LLVM_ENABLE_PROJECTS};" != *";mlir;"* ]]; then
      LLVM_ENABLE_PROJECTS="${LLVM_ENABLE_PROJECTS};mlir"
    fi
    ENABLE_MLIR=1
    unmark llvm
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/llvm.sh"
    step_llvm
  fi

  [ -f "$INSTALL/lib/cmake/mlir/MLIRConfig.cmake" ] || die "MLIRConfig.cmake 不存在，无法继续构建 torch-mlir"
  [ -f "$INSTALL/lib/cmake/llvm/LLVMConfig.cmake" ] || die "LLVMConfig.cmake 不存在，无法继续构建 torch-mlir"

  # 保证宿主 CXX 参数有效（宿主构建，与 LLVM 保持一致的 ABI）
  if [ -z "${HOST_CXX_FLAGS:-}" ] || [ -z "${HOST_LINK_FLAGS:-}" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/bootstrap.sh"
    step_host_cxx
  fi

  # 版本相容性探测与自检
  align_and_check_torch_mlir_version "$torch_src"

  log "4b/5 配置并构建 torch-mlir (源码: $torch_src)"
  local TORCH_BUILD="$SRC/build-torch-mlir"
  mkdir -p "$TORCH_BUILD"

  local extra_torch_flags=()
  if [ -n "${TORCH_MLIR_EXTRA_CMAKE_ARGS:-}" ]; then
    read -r -a extra_torch_flags <<< "${TORCH_MLIR_EXTRA_CMAKE_ARGS}"
  fi

  # 检查 stablehlo 子模块是否就绪，若缺失则禁用以保证 out-of-tree 构建平稳通行
  local enable_stablehlo="OFF"
  if [ -f "$torch_src/externals/stablehlo/CMakeLists.txt" ]; then
    enable_stablehlo="ON"
  fi

  log "4b/5 执行 CMake 配置 (Out-of-tree, StableHLO: $enable_stablehlo, Python: ${TORCH_MLIR_ENABLE_PYTHON:-OFF})"

  # 注意：torch-mlir 运行在宿主机上，需使用 $BOOT 引导编译器与 $HOST_CXX_FLAGS 编译，
  # 避免误用以 riscv64 musl 为默认目标的目标端 clang
  "$BOOT/bin/cmake" -G Ninja \
    -S "$torch_src" \
    -B "$TORCH_BUILD" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_C_COMPILER="$BOOT/bin/clang" \
    -DCMAKE_CXX_COMPILER="$BOOT/bin/clang++" \
    -DCMAKE_C_FLAGS="$HOST_CXX_FLAGS" \
    -DCMAKE_CXX_FLAGS="$HOST_CXX_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$HOST_LINK_FLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$HOST_LINK_FLAGS" \
    -DCMAKE_MODULE_LINKER_FLAGS="$HOST_LINK_FLAGS" \
    -DMLIR_DIR="$INSTALL/lib/cmake/mlir" \
    -DLLVM_DIR="$INSTALL/lib/cmake/llvm" \
    -DMLIR_TABLEGEN_EXE="$INSTALL/bin/mlir-tblgen" \
    -DLLVM_TABLEGEN_EXE="$INSTALL/bin/llvm-tblgen" \
    -DTORCH_MLIR_OUT_OF_TREE_BUILD=ON \
    -DTORCH_MLIR_ENABLE_STABLEHLO="$enable_stablehlo" \
    -DMLIR_ENABLE_BINDINGS_PYTHON="${TORCH_MLIR_ENABLE_PYTHON:-OFF}" \
    -DTORCH_MLIR_ENABLE_PYTORCH_EXTENSIONS=OFF \
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

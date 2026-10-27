#!/usr/bin/env bash
# ==============================================================================
# scripts/fetch.sh - 准备源码（Git Submodule 初始化检出 / 挂载本地自研源码并应用补丁）
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
init_config

apply_patches() {
  local component="$1" target_dir="$2"
  local patch_dir="$SRC/patches/$component"
  if [ -d "$patch_dir" ] && compgen -G "$patch_dir/*.patch" > /dev/null; then
    echo "  检查并应用 $component 补丁 ..."
    for p in "$patch_dir"/*.patch; do
      [ -f "$p" ] || continue
      local p_name
      p_name="$(basename "$p")"
      if [ -f "$target_dir/.applied_$p_name" ]; then
        ok "补丁 $p_name 已应用，跳过"
      else
        echo "  正在应用补丁: $p_name"
        ( cd "$target_dir" && ( git apply "$p" 2>/dev/null || patch -p1 < "$p" ) ) \
          || die "应用补丁 $p 失败"
        touch "$target_dir/.applied_$p_name"
        ok "补丁 $p_name 应用完成"
      fi
    done
  fi
}


checkout_repo_ref() {
  local dest="$1" repo="$2" ref="$3" sentinel="$4" name="$5"
  [ -z "$ref" ] && return 0

  # 1. 检查是否已有标记且当前版本与目标 ref 完全一致
  if [ -e "$dest/$sentinel" ] && [ -f "$dest/.git_checked_ref" ]; then
    if [ "$(cat "$dest/.git_checked_ref" 2>/dev/null)" = "$ref" ]; then
      ok "$name 已位于锁定版本 ($ref, $(git -C "$dest" rev-parse --short HEAD 2>/dev/null || echo "$ref"))"
      return 0
    fi
  fi

  mkdir -p "$dest"
  # 2. 检查是否为有效 git 仓库（兼容子模组 .git 文件与普通 .git 目录）
  if ! git -C "$dest" rev-parse --git-dir >/dev/null 2>&1; then
    echo "  初始化并检出 $name ($ref) ..."
    if git clone --depth 1 --branch "$ref" "$repo" "$dest" 2>/dev/null; then
      echo "$ref" > "$dest/.git_checked_ref"
      ok "$name ($ref) 检出完成"
      return 0
    fi
    git init -q "$dest"
  fi

  # 3. 幂等更新 remote origin
  git -C "$dest" remote set-url origin "$repo" 2>/dev/null || \
    git -C "$dest" remote add origin "$repo" 2>/dev/null || true

  # 4. 拉取目标版本并强制切换
  echo "  拉取/切换 $name 至锁定版本 ($ref) ..."
  local fetch_ok=0
  for i in 1 2 3; do
    if git -C "$dest" fetch --depth 1 origin "$ref" 2>/dev/null || \
       git -C "$dest" fetch --depth 1 origin "tags/$ref:tags/$ref" 2>/dev/null || \
       git -C "$dest" fetch origin "$ref" 2>/dev/null || \
       git -C "$dest" fetch --depth 1 "$repo" "$ref" 2>/dev/null; then
      fetch_ok=1
      break
    fi
    echo "    第 $i 次拉取重试中..."; sleep 2
  done
  [ "$fetch_ok" = 1 ] || die "无法从 $repo 拉取 $ref"

  git -C "$dest" checkout -q -f FETCH_HEAD
  [ -e "$dest/$sentinel" ] || die "$name 检出后缺少关键文件: $dest/$sentinel"
  rm -f "$dest"/.applied_*
  echo "$ref" > "$dest/.git_checked_ref"
  ok "$name 成功锁定至 $(git -C "$dest" rev-parse --short HEAD 2>/dev/null || echo "$ref")"
}

step_fetch() {
  if is_done fetch; then
    ok "源码已就绪，跳过"
    return
  fi
  log "准备源码 (版本锁定: LLVM:${LLVM_REF:-default} torch-mlir:${TORCH_MLIR_REF:-default} triton:${TRITON_REF:-default} musl:${MUSL_REF:-default} linux-headers:${LINUX_HEADERS_REF:-default})"

  # ---- 1. 准备 LLVM 源码 ----
  if [ -n "${LLVM_SRC:-}" ]; then
    log "使用本地自研 LLVM 源码: $LLVM_SRC"
    [ -d "$LLVM_SRC/llvm" ] || die "指定的 LLVM_SRC 缺少 llvm 目录: $LLVM_SRC"
    mkdir -p "$(dirname "$LLVM_DIR")"
    ln -sfn "$LLVM_SRC" "$LLVM_DIR"
  else
    checkout_repo_ref "$LLVM_DIR" "${LLVM_REPO:-https://github.com/llvm/llvm-project.git}" "${LLVM_REF:-release/23.x}" "llvm/CMakeLists.txt" "llvm"
  fi

  # ---- 2. 准备 Musl 源码 ----
  if [ -n "${MUSL_SRC:-}" ]; then
    log "使用本地自研 Musl 源码: $MUSL_SRC"
    [ -f "$MUSL_SRC/configure" ] || die "指定的 MUSL_SRC 缺少 configure: $MUSL_SRC"
    mkdir -p "$(dirname "$MUSL_DIR")"
    ln -sfn "$MUSL_SRC" "$MUSL_DIR"
  else
    checkout_repo_ref "$MUSL_DIR" "${MUSL_REPO:-https://github.com/kraj/musl.git}" "${MUSL_REF:-v1.2.5}" "configure" "musl"
  fi

  # ---- 3. 准备 torch-mlir 源码 (Git Submodule / 本地挂载) ----
  if [ -n "${CLI_TORCH_MLIR_SRC:-}" ]; then
    log "使用本地挂载 torch-mlir 源码: $CLI_TORCH_MLIR_SRC"
    [ -f "$CLI_TORCH_MLIR_SRC/CMakeLists.txt" ] || die "指定的 TORCH_MLIR_SRC 缺少 CMakeLists.txt: $CLI_TORCH_MLIR_SRC"
    mkdir -p "$(dirname "$SRC/third_party/torch-mlir")"
    ln -sfn "$CLI_TORCH_MLIR_SRC" "$SRC/third_party/torch-mlir"
  else
    if [ -L "$SRC/third_party/torch-mlir" ]; then
      warn "解除外部陈旧软链接: $SRC/third_party/torch-mlir"
      rm -f "$SRC/third_party/torch-mlir"
      rm -rf "$SRC/build-torch-mlir"
    fi
    checkout_repo_ref "$SRC/third_party/torch-mlir" "${TORCH_MLIR_REPO:-https://github.com/llvm/torch-mlir.git}" "${TORCH_MLIR_REF:-v20261001}" "CMakeLists.txt" "torch-mlir"
  fi

  # ---- 4. 准备 linux-headers 源码 (Git Submodule / 本地挂载) ----
  if [ -n "${CLI_LINUX_HEADERS_SRC:-${LINUX_HEADERS_SRC:-}}" ]; then
    local custom_hdr="${CLI_LINUX_HEADERS_SRC:-${LINUX_HEADERS_SRC:-}}"
    log "使用本地挂载 linux-headers 源码: $custom_hdr"
    mkdir -p "$(dirname "$LINUX_HEADERS_DIR")"
    ln -sfn "$custom_hdr" "$LINUX_HEADERS_DIR"
  else
    checkout_repo_ref "$LINUX_HEADERS_DIR" "${LINUX_HEADERS_REPO:-https://github.com/sabotage-linux/kernel-headers.git}" "${LINUX_HEADERS_REF:-master}" "Makefile" "linux-headers"
  fi

  # 建立内部 include 映射与根目录兼容软链接
  if [ -d "$LINUX_HEADERS_DIR" ]; then
    if [ -d "$LINUX_HEADERS_DIR/riscv/include" ] && [ ! -d "$LINUX_HEADERS_DIR/include" ]; then
      ln -sfn "$LINUX_HEADERS_DIR/riscv/include" "$LINUX_HEADERS_DIR/include"
    fi
    if [ ! -e "$SRC/linux-headers" ] || [ -L "$SRC/linux-headers" ]; then
      ln -sfn "$LINUX_HEADERS_DIR" "$SRC/linux-headers"
    fi
  fi

  # ---- 5. 准备 triton 源码 (Git Submodule / 本地挂载) ----
  if [ -n "${CLI_TRITON_SRC:-}" ]; then
    log "使用本地挂载 triton 源码: $CLI_TRITON_SRC"
    [ -f "$CLI_TRITON_SRC/CMakeLists.txt" ] || die "指定的 TRITON_SRC 缺少 CMakeLists.txt: $CLI_TRITON_SRC"
    mkdir -p "$(dirname "$SRC/third_party/triton")"
    ln -sfn "$CLI_TRITON_SRC" "$SRC/third_party/triton"
  elif [ "${ENABLE_TRITON:-0}" = 1 ] || [ "${CLI_ENABLE_TRITON:-0}" = 1 ] || [ -d "$SRC/third_party/triton" ]; then
    if [ -L "$SRC/third_party/triton" ]; then
      warn "解除外部陈旧软链接: $SRC/third_party/triton"
      rm -f "$SRC/third_party/triton"
      rm -rf "$SRC/build-triton"
    fi
    checkout_repo_ref "$SRC/third_party/triton" "${TRITON_REPO:-https://github.com/triton-lang/triton.git}" "${TRITON_REF:-v3.2.0}" "CMakeLists.txt" "triton"
  fi

  # ---- 6. 应用拓展补丁 ----
  apply_patches "llvm" "$LLVM_DIR"
  apply_patches "musl" "$MUSL_DIR"
  if [ -d "$SRC/third_party/torch-mlir" ]; then
    apply_patches "torch-mlir" "$SRC/third_party/torch-mlir"
  fi
  if [ -d "$SRC/third_party/triton" ]; then
    apply_patches "triton" "$SRC/third_party/triton"
  fi
  if [ -d "$LINUX_HEADERS_DIR" ]; then
    apply_patches "linux-headers" "$LINUX_HEADERS_DIR"
  fi

  # ---- 6. 源码完整性校验 ----
  [ -f "$LLVM_DIR/llvm/CMakeLists.txt" ]        || die "llvm 源码不完整: $LLVM_DIR/llvm/CMakeLists.txt"
  [ -f "$LLVM_DIR/runtimes/CMakeLists.txt" ]    || die "runtimes 目录缺失: $LLVM_DIR/runtimes/CMakeLists.txt"
  [ -f "$LLVM_DIR/compiler-rt/CMakeLists.txt" ] || die "compiler-rt 缺失: $LLVM_DIR/compiler-rt/CMakeLists.txt"
  [ -f "$MUSL_DIR/configure" ]                  || die "musl 源码不完整: $MUSL_DIR/configure"
  local check_hdr
  check_hdr="$(get_linux_headers_include_dir)"
  [ -d "$check_hdr" ] || [ -f "$LINUX_HEADERS_DIR/Makefile" ] || die "linux-headers 源码不完整: $LINUX_HEADERS_DIR"

  mark fetch
  ok "源码就绪"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_fetch
fi

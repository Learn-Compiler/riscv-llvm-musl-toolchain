#!/usr/bin/env bash
# ==============================================================================
# scripts/02_fetch.sh - 准备源码（Git Submodule 初始化检出 / 挂载本地自研源码并应用补丁）
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

step_fetch() {
  if is_done fetch; then
    ok "源码已就绪，跳过"
    return
  fi
  log "2/5 准备源码 (Submodule / 本地源码)"

  # ---- 1. 准备 LLVM 源码 ----
  if [ -n "${LLVM_SRC:-}" ]; then
    log "使用本地自研 LLVM 源码: $LLVM_SRC"
    [ -d "$LLVM_SRC/llvm" ] || die "指定的 LLVM_SRC 缺少 llvm 目录: $LLVM_SRC"
    ln -sfn "$LLVM_SRC" "$SRC/llvm"
  else
    if [ ! -f "$SRC/llvm/llvm/CMakeLists.txt" ]; then
      echo "  初始化并检出 llvm 子模组 ..."
      git -C "$SRC" submodule update --init --depth 1 llvm || \
        git -C "$SRC" submodule update --init llvm
    fi
    ok "llvm 子模组已就绪 ($(git -C "$SRC/llvm" rev-parse --short HEAD 2>/dev/null || echo 'local'))"
  fi

  # ---- 2. 准备 Musl 源码 ----
  if [ -n "${MUSL_SRC:-}" ]; then
    log "使用本地自研 Musl 源码: $MUSL_SRC"
    [ -f "$MUSL_SRC/configure" ] || die "指定的 MUSL_SRC 缺少 configure: $MUSL_SRC"
    ln -sfn "$MUSL_SRC" "$SRC/musl"
  else
    if [ ! -f "$SRC/musl/configure" ]; then
      echo "  初始化并检出 musl 子模组 ..."
      git -C "$SRC" submodule update --init --depth 1 musl || \
        git -C "$SRC" submodule update --init musl
    fi
    ok "musl 子模组已就绪 ($(git -C "$SRC/musl" rev-parse --short HEAD 2>/dev/null || echo 'local'))"
  fi

  # ---- 3. 应用拓展补丁 ----
  apply_patches "llvm" "$SRC/llvm"
  apply_patches "musl" "$SRC/musl"

  # ---- 4. 源码完整性校验 ----
  [ -f "$SRC/llvm/llvm/CMakeLists.txt" ]        || die "llvm 源码不完整"
  [ -f "$SRC/llvm/runtimes/CMakeLists.txt" ]    || die "runtimes 目录缺失"
  [ -f "$SRC/llvm/compiler-rt/CMakeLists.txt" ] || die "compiler-rt 缺失"
  [ -f "$SRC/musl/configure" ]                  || die "musl 源码不完整"

  mark fetch
  ok "源码就绪"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_fetch
fi

#!/usr/bin/env bash
# ==============================================================================
# scripts/fetch.sh - 准备源码 (仅 LLVM 与 Picolibc，锁定版本与 SSH 镜像)
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
  # 2. 检查是否为有效 git 仓库
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

  # 4. 拉取目标版本并强制切换 (支持分支、tag 与 commit hash)
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
  log "准备源码 (版本锁定: LLVM:${LLVM_REF:-default} picolibc:${PICOLIBC_REF:-default})"

  # ---- 1. 准备 LLVM 源码 ----
  if [ -n "${LLVM_SRC:-}" ]; then
    log "使用本地自研 LLVM 源码: $LLVM_SRC"
    [ -d "$LLVM_SRC/llvm" ] || die "指定的 LLVM_SRC 缺少 llvm 目录: $LLVM_SRC"
    mkdir -p "$(dirname "$LLVM_DIR")"
    ln -sfn "$LLVM_SRC" "$LLVM_DIR"
  else
    checkout_repo_ref "$LLVM_DIR" "${LLVM_REPO:-git@github.com:Learn-Compiler/llvm-project.git}" "${LLVM_REF:-ea7d852a70e8bdfaf601d6626a760f9771b2c4b4}" "llvm/CMakeLists.txt" "llvm"
  fi

  # ---- 2. 准备 Picolibc 源码 ----
  if [ -n "${PICOLIBC_SRC_CUSTOM:-}" ]; then
    log "使用本地自研 Picolibc 源码: $PICOLIBC_SRC_CUSTOM"
    [ -f "$PICOLIBC_SRC_CUSTOM/meson.build" ] || die "指定的 PICOLIBC_SRC 缺少 meson.build: $PICOLIBC_SRC_CUSTOM"
    mkdir -p "$(dirname "$PICOLIBC_SRC")"
    ln -sfn "$PICOLIBC_SRC_CUSTOM" "$PICOLIBC_SRC"
  else
    checkout_repo_ref "$PICOLIBC_SRC" "${PICOLIBC_REPO:-git@github.com:Learn-Compiler/picolibc.git}" "${PICOLIBC_REF:-2ae376c6cdf4fef90ca2388ecf7a07457fa63cff}" "meson.build" "picolibc"
  fi

  # ---- 3. 应用拓展补丁 ----
  apply_patches "llvm" "$LLVM_DIR"
  apply_patches "picolibc" "$PICOLIBC_SRC"

  # ---- 4. 源码完整性校验 ----
  [ -f "$LLVM_DIR/llvm/CMakeLists.txt" ]        || die "llvm 源码不完整: $LLVM_DIR/llvm/CMakeLists.txt"
  [ -f "$LLVM_DIR/runtimes/CMakeLists.txt" ]    || die "runtimes 目录缺失: $LLVM_DIR/runtimes/CMakeLists.txt"
  [ -f "$LLVM_DIR/compiler-rt/CMakeLists.txt" ] || die "compiler-rt 缺失: $LLVM_DIR/compiler-rt/CMakeLists.txt"
  [ -f "$PICOLIBC_SRC/meson.build" ]            || die "picolibc 源码不完整: $PICOLIBC_SRC/meson.build"

  mark fetch
  ok "源码就绪 (LLVM + Picolibc)"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_fetch
fi

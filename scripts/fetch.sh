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
# 依据当前主控 LLVM 版本对齐 torch-mlir 对应兼容版本
align_torch_mlir_to_llvm() {
  local target_dir="$1"
  local current_llvm
  current_llvm=$(git -C "$LLVM_DIR" rev-parse HEAD 2>/dev/null || echo "${LLVM_SHA:-}")
  [ -n "$current_llvm" ] || return 0

  local target_torch_ref="${CLI_TORCH_MLIR_REF:-${TORCH_MLIR_SHA:-}}"

  # 若未显式配置 torch-mlir 目标提交，则根据 LLVM 提交在 torch-mlir 历史中动态检索匹配的集成点
  if [ -z "$target_torch_ref" ]; then
    local matched
    matched=$(git -C "$target_dir" log --grep="Integrate LLVM at .*${current_llvm:0:8}" -n 1 --format="%H" 2>/dev/null || true)
    if [ -n "$matched" ]; then
      target_torch_ref="$matched"
    else
      local llvm_time
      llvm_time=$(git -C "$LLVM_DIR" log -1 --format="%ci" "$current_llvm" 2>/dev/null || true)
      if [ -n "$llvm_time" ]; then
        target_torch_ref=$(git -C "$target_dir" log --before="$llvm_time" -n 1 --format="%H" 2>/dev/null || true)
      fi
    fi
  fi

  if [ -n "$target_torch_ref" ]; then
    local current_torch_head
    current_torch_head=$(git -C "$target_dir" rev-parse HEAD 2>/dev/null || true)
    if [[ "$current_torch_head" != "$target_torch_ref"* ]]; then
      log "依据 LLVM 主控版本 (${current_llvm:0:10})，自动对齐 torch-mlir 至: ${target_torch_ref:0:10}"
      git -C "$target_dir" checkout -q "$target_torch_ref" 2>/dev/null || true
    fi
    ok "torch-mlir 版本已对齐至: $(git -C "$target_dir" rev-parse --short HEAD 2>/dev/null || echo "$target_torch_ref")"
  fi
}

# 依据当前主控 LLVM 版本对齐 torch-mlir 对应兼容版本
align_torch_mlir_to_llvm() {
  local target_dir="$1"
  local current_llvm
  current_llvm=$(git -C "$LLVM_DIR" rev-parse HEAD 2>/dev/null || echo "${LLVM_SHA:-}")
  [ -n "$current_llvm" ] || return 0

  local target_torch_ref="${CLI_TORCH_MLIR_REF:-${TORCH_MLIR_SHA:-}}"

  # 若未显式配置 torch-mlir 目标提交，则根据 LLVM 提交在 torch-mlir 历史中动态检索匹配的集成点
  if [ -z "$target_torch_ref" ]; then
    local matched
    matched=$(git -C "$target_dir" log --grep="Integrate LLVM at .*${current_llvm:0:8}" -n 1 --format="%H" 2>/dev/null || true)
    if [ -n "$matched" ]; then
      target_torch_ref="$matched"
    else
      local llvm_time
      llvm_time=$(git -C "$LLVM_DIR" log -1 --format="%ci" "$current_llvm" 2>/dev/null || true)
      if [ -n "$llvm_time" ]; then
        target_torch_ref=$(git -C "$target_dir" log --before="$llvm_time" -n 1 --format="%H" 2>/dev/null || true)
      fi
    fi
  fi

  if [ -n "$target_torch_ref" ]; then
    local current_torch_head
    current_torch_head=$(git -C "$target_dir" rev-parse HEAD 2>/dev/null || true)
    if [[ "$current_torch_head" != "$target_torch_ref"* ]]; then
      log "依据 LLVM 主控版本 (${current_llvm:0:10})，自动对齐 torch-mlir 至: ${target_torch_ref:0:10}"
      git -C "$target_dir" checkout -q "$target_torch_ref" 2>/dev/null || true
    fi
    ok "torch-mlir 版本已对齐至: $(git -C "$target_dir" rev-parse --short HEAD 2>/dev/null || echo "$target_torch_ref")"
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
    mkdir -p "$(dirname "$LLVM_DIR")"
    ln -sfn "$LLVM_SRC" "$LLVM_DIR"
  else
    if [ ! -f "$LLVM_DIR/llvm/CMakeLists.txt" ]; then
      echo "  初始化并检出 llvm 子模组 ..."
      git -C "$SRC" submodule update --init --depth 1 third_party/llvm || \
        git -C "$SRC" submodule update --init third_party/llvm
    fi
    ok "llvm 子模组已就绪 ($(git -C "$LLVM_DIR" rev-parse --short HEAD 2>/dev/null || echo 'local'))"
  fi

  # ---- 2. 准备 Musl 源码 ----
  if [ -n "${MUSL_SRC:-}" ]; then
    log "使用本地自研 Musl 源码: $MUSL_SRC"
    [ -f "$MUSL_SRC/configure" ] || die "指定的 MUSL_SRC 缺少 configure: $MUSL_SRC"
    mkdir -p "$(dirname "$MUSL_DIR")"
    ln -sfn "$MUSL_SRC" "$MUSL_DIR"
  else
    if [ ! -f "$MUSL_DIR/configure" ]; then
      echo "  初始化并检出 musl 子模组 ..."
      git -C "$SRC" submodule update --init --depth 1 third_party/musl || \
        git -C "$SRC" submodule update --init third_party/musl
    fi
    ok "musl 子模组已就绪 ($(git -C "$MUSL_DIR" rev-parse --short HEAD 2>/dev/null || echo 'local'))"
  fi

  # ---- 3. 准备并对齐 torch-mlir 源码 (由 LLVM 主控版本驱动) ----
  local torch_src="${TORCH_MLIR_SRC:-$SRC/third_party/torch-mlir}"
  if [ -n "${CLI_TORCH_MLIR_SRC:-}" ]; then
    log "使用本地挂载 torch-mlir 源码: $CLI_TORCH_MLIR_SRC"
    [ -f "$CLI_TORCH_MLIR_SRC/CMakeLists.txt" ] || die "指定的 TORCH_MLIR_SRC 缺少 CMakeLists.txt: $CLI_TORCH_MLIR_SRC"
    mkdir -p "$(dirname "$SRC/third_party/torch-mlir")"
    ln -sfn "$CLI_TORCH_MLIR_SRC" "$SRC/third_party/torch-mlir"
  elif [ "${ENABLE_TORCH_MLIR:-0}" = 1 ] || [ "${CLI_ENABLE_TORCH_MLIR:-0}" = 1 ] || [ -d "$SRC/third_party/torch-mlir" ]; then
    if [ ! -f "$SRC/third_party/torch-mlir/CMakeLists.txt" ]; then
      local local_cand=""
      for cand in "/home/compiler-1/work/compiler/torch-mlir" "/home/compiler-1/learn/torch-mlir"; do
        if [ -f "$cand/CMakeLists.txt" ]; then
          local_cand="$cand"
          break
        fi
      done
      if [ -n "$local_cand" ]; then
        log "检测到本地已有 torch-mlir 源码 ($local_cand)，建立软链接"
        mkdir -p "$SRC/third_party"
        ln -sfn "$local_cand" "$SRC/third_party/torch-mlir"
      else
        echo "  克隆 torch-mlir 源码 (upstream) ..."
        mkdir -p "$SRC/third_party"
        git clone "${TORCH_MLIR_REPO:-https://github.com/llvm/torch-mlir.git}" "$SRC/third_party/torch-mlir" || true
      fi
    fi

    # 由 LLVM 主控版本决定并切换 torch-mlir 对应版本
    if [ -d "$SRC/third_party/torch-mlir/.git" ]; then
      align_torch_mlir_to_llvm "$SRC/third_party/torch-mlir"
    fi

    if [ -f "$SRC/third_party/torch-mlir/CMakeLists.txt" ]; then
      ok "torch-mlir 源码已就绪"
    fi
  fi

  # ---- 4. 应用拓展补丁 ----
  apply_patches "llvm" "$LLVM_DIR"
  apply_patches "musl" "$MUSL_DIR"
  if [ -d "$SRC/third_party/torch-mlir" ]; then
    apply_patches "torch-mlir" "$SRC/third_party/torch-mlir"
  fi

  # ---- 5. 源码完整性校验 ----
  [ -f "$LLVM_DIR/llvm/CMakeLists.txt" ]        || die "llvm 源码不完整: $LLVM_DIR/llvm/CMakeLists.txt"
  [ -f "$LLVM_DIR/runtimes/CMakeLists.txt" ]    || die "runtimes 目录缺失: $LLVM_DIR/runtimes/CMakeLists.txt"
  [ -f "$LLVM_DIR/compiler-rt/CMakeLists.txt" ] || die "compiler-rt 缺失: $LLVM_DIR/compiler-rt/CMakeLists.txt"
  [ -f "$MUSL_DIR/configure" ]                  || die "musl 源码不完整: $MUSL_DIR/configure"

  mark fetch
  ok "源码就绪"
}

# 独立运行支持
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step_fetch
fi

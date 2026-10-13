---
name: riscv-toolchain-builder
description: >-
  Workflows, procedures, and troubleshooting guidelines for the RISC-V LLVM + Musl toolchain project.
  Use this skill when building, customizing, verifying, or debugging the toolchain, configuring MLIR or
  torch-mlir pipelines, or running step-by-step toolchain development.
---

# RISC-V LLVM + Musl 工具链构建与维护指南

本 Skill 为开发和维护 `riscv64-unknown-linux-musl` 纯 LLVM/Clang 工具链提供标准操作规程、流水线阶段解析与故障排查方法。

---

## 1. 工具链核心架构与设计目标

- **完全脱离 GCC / GNU Binutils**：
  - 编译器：`clang` / `clang++`
  - 汇编与链接器：`lld`
  - 目标 C 运行时库：`musl` libc
  - 底层编译器运行库：LLVM `compiler-rt` (builtins + crtbegin/crtend)
  - C++ 标准库与展开库：LLVM `libc++` + `libc++abi` + `libunwind`
- **自举 (Bootstrapping) 机制**：
  - 通过 `.bootstrap/` 下载预编译免 root 的 Clang、CMake 和 Ninja，避免宿主 GCC 污染与版本不匹配。
- **循环依赖解耦三部曲**：
  1. **Builtins**：利用空头文件环境先编译 compiler-rt builtins 与 crt 初始对象。
  2. **Musl**：以 step 1 产物链接编译 Musl libc，建立基础 Sysroot。
  3. **LLVM + Runtimes**：使用自举编译器一次性构建宿主 LLVM/Clang 及目标架构的 libc++/libunwind 等完整运行库。

---

## 2. 流水线阶段与执行入口

构建总入口为根目录下的 [`build.sh`](../../build.sh)，由 [`scripts/`](../../scripts/) 下的模块化脚本驱动：

| 步骤名 (`--step`) | 对应脚本 | 阶段职责说明 |
| :--- | :--- | :--- |
| `bootstrap` | [`scripts/bootstrap.sh`](../../scripts/bootstrap.sh) | 探测并下载免 root 引导工具 (Clang/CMake/Ninja)，探测宿主 C++ 运行时 |
| `fetch` | [`scripts/fetch.sh`](../../scripts/fetch.sh) | 初始化并检出 `third_party/llvm` 与 `third_party/musl`，应用必要补丁 |
| `builtins` | [`scripts/builtins.sh`](../../scripts/builtins.sh) | 跨架构编译 compiler-rt builtins 与 crtbegin/crtend (别名: `compiler-rt`) |
| `musl` | [`scripts/musl.sh`](../../scripts/musl.sh) | 编译 Musl libc 并安装至 Sysroot (`install-clang-musl/riscv64-unknown-linux-musl`) |
| `llvm` | [`scripts/llvm.sh`](../../scripts/llvm.sh) | 构建宿主 LLVM 工具链及目标端完整运行时 (compiler-rt, libc++, libunwind) |
| `torch-mlir` | [`scripts/torch_mlir.sh`](../../scripts/torch_mlir.sh) | *(扩展阶段)* 对接已安装的 LLVM/MLIR 配置，独立构建与安装 torch-mlir |
| `prune` | [`scripts/prune.sh`](../../scripts/prune.sh) | 移除无用跨平台二进制、符号剥离、生成三元组链接与目标 `.cfg` 驱动配置文件 |
| `verify` | [`scripts/verify.sh`](../../scripts/verify.sh) | 校验运行库完整性，通过 QEMU 运行 C/C++ 冒烟测试并检测静态/动态链接行为 |
| `package` | [`scripts/package.sh`](../../scripts/package.sh) | 打包发布产物为 `.tar.zst` 并计算 `SHA256SUMS` |

---

## 3. 常见开发工作流操作手册

### 3.1 默认完整构建 (生产发布形态)
默认构建为纯静态库，驱动默认附带 `-static`：
```bash
./build.sh --default
```

### 3.2 二次开发与源码单步调试 (推荐)
保留调试符号、开启 LLVM 断言，支持 GDB 源码级断点：
```bash
# 推荐日常开发模式：RelWithDebInfo (-O2 -g + Assertions)
./build.sh --debug

# 仅重新构建 LLVM 模块与运行时库
./build.sh --rebuild-llvm --debug

# 极端单步无优化调试：Debug (-O0 -g + Assertions)
./build.sh --full-debug
```

### 3.3 启用 MLIR 与构建 torch-mlir 组件 (LLVM 主控驱动版本)
本体系采用**以核心 LLVM 为主控基准，自动推导与对齐下游 torch-mlir 对应版本**的机制：
```bash
# 方式 A: 一键构建完整流水线 (自动由 LLVM 版本推导并切换匹配的 torch-mlir 节点)
./build.sh --enable-torch-mlir --debug

# 方式 B: 分步构建
# 步骤 1: 构建启用 MLIR 与宿主 X86/RISCV 架构的 LLVM
./build.sh --enable-mlir --targets "RISCV;X86" --debug

# 步骤 2: 单独构建 torch-mlir 组件 (系统自动根据当前 LLVM commit 检出兼容的 torch-mlir 提交)
./build.sh --step torch-mlir

# 方式 C: 显式指定特定的 torch-mlir 提交节点或本地源码
./build.sh --step torch-mlir --torch-mlir-version d3071f4785
./build.sh --step torch-mlir --torch-mlir-src /path/to/torch-mlir
```

### 3.4 动态库构建与动态链接
编译 `.so` 共享库，生成的 `.cfg` 默认不注入 `-static`：
```bash
./build.sh --shared
```

### 3.5 单独执行与断点调试步骤
```bash
# 单独重跑验证步骤
./build.sh --step verify

# 从 musl 步骤开始向下继续执行
./build.sh --from musl

# 单独调试 LLVM 编译并追加自定义 CMake 选项
./build.sh --step llvm --debug --cmake-args "-DLLVM_BUILD_EXAMPLES=OFF"
```

---

## 4. 关键配置文件与环境变量

1. **全局默认配置**：[`config/default.env`](../../config/default.env)
   - 包含三元组、目标架构、构建目录名、默认 `LLVM_ENABLE_PROJECTS` 等。
2. **本地环境覆盖**：[`config/local.env`](../../config/local.env) (由 `config/local.env.example` 复制)
   - 优先级最高，可覆盖 `JOBS`、`BUILD_TYPE`、`LLVM_SRC`、`LLVM_EXTRA_CMAKE_ARGS` 等，且已被 `.gitignore` 忽略。
3. **架构特异性配置**：`config/targets/<target>.env`
   - 目前默认 `riscv64-linux-musl.env`。

---

## 5. 调试排查与常见踩坑指南

1. **时间戳重置 (Cache Invalidation)**：
   - 每个构建阶段成功后会在 `.build-stamps/` 写入标记。
   - 若修改了某一脚本或想强制重新执行某一阶段，使用 `--step <name>` 会自动清除该阶段时间戳，或手动删除：
     ```bash
     rm -f .build-stamps/llvm .build-stamps/verify
     ```
2. **QEMU 冒烟测试失败**：
   - 依赖 `qemu-riscv64` (动态库测试还需正确传递 `-L <sysroot>`)。
   - 若系统未安装 QEMU，可通过系统包管理器安装 `qemu-user`，或使用 `SKIP_TESTS=1` 跳过测试。
3. **驱动默认行为由 `.cfg` 决定**：
   - 生成的驱动配置文件位于 `install-clang-musl/bin/riscv64-unknown-linux-musl.cfg`。
   - 它控制了 `--sysroot`、`--rtlib=compiler-rt`、`--unwindlib=libunwind`、`-fuse-ld=lld` 以及默认的 `-static`。

---

## 6. 进阶参考文档

- [系统架构与循环依赖解决机制](./references/architecture.md)
- [CLI 参数速查与常用用例清单](./references/cli-cheatsheet.md)

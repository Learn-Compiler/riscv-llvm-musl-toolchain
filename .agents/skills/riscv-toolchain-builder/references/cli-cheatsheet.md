# CLI 命令参数与常见场景速查手册

本文档汇总 `./build.sh` 的全量命令行参数及高频开发用例。

---

## 1. 命令行参数完整列表

### 构建模式
- `--default`：恢复/强制标准构建（Release + 纯静态库 + 默认 `-static` 链接）。
- `--release`：发布优化模式 (`-O3`，自动剥离调试符号)。
- `--debug`：推荐的二次开发模式 (`RelWithDebInfo`, `-O2 -g`，开启 Assertions，保留符号)。
- `--full-debug`：纯源码单步调试模式 (`Debug`, `-O0 -g`，开启 Assertions，保留符号)。
- `--build-type <TYPE>`：自定义 CMake 构建类型 (`Release|RelWithDebInfo|Debug|MinSizeRel`)。
- `--runtimes-build-type <TYPE>`：自定义目标运行时库构建类型（默认: `Release`）。

### 库形态与链接
- `--shared`, `--share`：构建动态运行库 (`.so`) 及静态库，默认不注入 `-static`。
- `--static`：显式仅构建静态库 (`.a`)（默认行为）。
- `--static-link`：强制在 `.cfg` 中默认启用 `-static`。
- `--no-static-link`：在 `.cfg` 中不默认启用 `-static`。

### 组件定制与参数透传
- `--projects <LIST>`：自定义 LLVM 子项目列表（如 `"clang;lld;mlir"`）。
- `--enable-mlir`, `--mlir`：快捷开启 MLIR 子项目。
- `--targets <LIST>`：指定 LLVM 编译后端架构（如 `"RISCV;X86"`）。
- `--runtimes <LIST>`：指定 LLVM 目标运行时（默认: `"compiler-rt;libcxx;libcxxabi;libunwind"`）。
- `--cmake-args <ARGS>`：透传额外参数给 LLVM CMake（可多次传入）。
- `--musl-args <ARGS>`：透传额外参数给 Musl `./configure`。
- `--torch-mlir-src <DIR>`：指定本地 torch-mlir 源码路径。
- `--llvm-src <DIR>`：挂载本地自定义 LLVM 源码目录（无需重新检出）。
- `--musl-src <DIR>`：挂载本地自定义 Musl 源码目录（无需重新检出）。

### 流程控制与维护
- `--step <NAME>`：单独执行某一特定步骤（如 `musl`, `llvm`, `verify`, `torch-mlir`）。
- `--from <NAME>`：从指定步骤开始向下执行全部流水线。
- `--rebuild-llvm`：清理 LLVM 编译时间戳并重新编译。
- `--clean`：清理临时构建目录与时间戳（保留 `.bootstrap`）。
- `--clean-all`：清理包括引导工具在内的全部产物。
- `--package`：构建后打包生成 `.tar.zst`。

---

## 2. 常见场景用例

### 场景 1：构建带 MLIR 支持与 Debug 符号的工具链
```bash
./build.sh --enable-mlir --targets "RISCV;X86" --debug
```

### 场景 2：基于已有 LLVM 构建外部 torch-mlir
```bash
# 保证 LLVM 中已安装 MLIR cmake 导出文件
./build.sh --enable-mlir --step llvm

# 单独配置并编译 torch-mlir
./build.sh --step torch-mlir --torch-mlir-src ~/workspace/torch-mlir
```

### 场景 3：快速迭代开发 LLVM 内部 Pass / Codegen
```bash
# 源码位于外部目录，使用 8 线程进行快速增量编译
JOBS=8 ./build.sh --llvm-src ~/workspace/llvm-project --rebuild-llvm --debug
```

### 场景 4：仅编译 Musl libc 调试底层系统调用
```bash
./build.sh --step musl --musl-args "--enable-debug"
```

### 场景 5：验证安装产物与冒烟测试
```bash
# 单独重跑 QEMU 自动化测试套件
./build.sh --step verify
```

# AI 编程对话记录

## 项目：Linux 持续 CPU Profiling 工具

---

### 对话 1：项目需求理解

**用户**：我需要在 Linux 上开发一个 7x24 持续 CPU Profiling 工具，要容器化、支持按时间回查、生成火焰图。

**AI**：理解了需求，这是一个类似"黑匣子"的 perf 持续采集工具。我建议按照以下模块来拆分：
1. collector.sh - 核心采集，每60秒轮转
2. cleaner.sh - 过期数据清理
3. query.py - 按时间回查
4. flamegraph.py - 火焰图生成
5. api.py - HTTP API 服务
6. entrypoint.sh - 容器入口
7. Dockerfile - 容器化

---

### 对话 2：编写 collector.sh

**用户**：请编写 src/collector.sh，这是一个 7x24 持续 CPU 采集脚本，使用 perf record 每 60 秒轮转一次。

**AI**：已生成 collector.sh，包含以下功能：
- 每 60 秒轮转生成 perf_YYYYMMDD_HHMMSS.data
- 支持硬件 PMU (cycles) 和软件 (cpu-clock) 自动降级
- 捕获 SIGINT/SIGTERM 优雅终止
- 支持环境变量配置：RETENTION_HOURS, PERF_FREQ, PERF_DURATION

---

### 对话 3：编写 cleaner.sh

**用户**：请编写 src/cleaner.sh，清理过期数据。

**AI**：已生成 cleaner.sh，支持：
- 清理超过 RETENTION_HOURS 的 perf_*.data 文件
- --dry-run 预演模式
- 返回删除文件数量

---

### 对话 4：编写 query.py

**用户**：请编写 src/query.py，按时间段回查采样文件。

**AI**：已生成 query.py，支持：
- --start / --end 时间参数
- 文件名时间戳解析
- 采集窗口交叠匹配策略

---

### 对话 5：编写 flamegraph.py

**用户**：请编写 src/flamegraph.py，一键生成火焰图。

**AI**：已生成 flamegraph.py：
- 自动克隆 FlameGraph 工具链
- perf script → stackcollapse-perf.pl → flamegraph.pl
- 支持 --width 参数

---

### 对话 6：编写 api.py

**用户**：请编写 src/api.py，HTTP API 服务。

**AI**：已生成 api.py：
- /api/health - 健康检查
- /api/status - 系统概览
- /api/files - 按时间查询
- /api/flamegraph - 生成火焰图 SVG

---

### 对话 7：编写 entrypoint.sh

**用户**：请编写 src/entrypoint.sh，容器启动入口。

**AI**：已生成 entrypoint.sh：
- 启动 collector 采集进程
- 启动 HTTP API 服务
- 每10分钟执行 cleaner 清理
- 捕获信号优雅关闭
- fail-fast 机制

---

### 对话 8：编写 Dockerfile

**用户**：请编写 Dockerfile。

**AI**：已生成 Dockerfile：
- 基于 ubuntu:22.04
- 安装 perf, python3, git, perl, procps, stress-ng
- 复制 src/ 和 requirements.txt
- 设置环境变量
- 入口点 entrypoint.sh

---

### 对话 9：编写 README.md

**用户**：请编写 README.md。

**AI**：已生成 README.md：
- 项目简介、架构设计
- 快速启动命令
- 使用示例
- 设计权衡说明

---

### 对话 10：编写测试脚本

**用户**：请编写 test/test_scenario.sh。

**AI**：已生成测试脚本：
- 自动安装 stress-ng
- 记录开始/结束时间
- 执行 CPU 压力测试
- 输出测试摘要
- 提示验证命令

---

## 开发总结

本项目通过 AI 辅助编程完成了一个完整的 Linux 持续 CPU Profiling 工具，代码量约 1500 行，覆盖采集、清理、回查、火焰图生成、HTTP API、容器化等完整链路。

**AI 使用体会**：
- 需求拆解清晰，能快速生成可运行的代码
- 注释详细，便于理解和维护
- 错误处理全面，考虑到了各种边界情况
- 迭代效率高，大大缩短了开发周期


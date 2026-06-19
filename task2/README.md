# CPU Profiling 持续采集工具

## 项目简介

本工具是一个 **7×24 持续 CPU Profiling 工具**，让 `perf` 像"黑匣子"一样常驻后台运行。出问题时只需指定时间点，就能调出当时的 CPU 采样数据，生成火焰图定位根因。

**核心功能：**

| 功能 | 说明 |
|------|------|
| **后台持续采集** | 使用 `perf record` 在后台持续采集系统级 CPU 调用栈数据，按 60 秒时间窗口自动轮转 |
| **历史数据保留** | 采样数据按时间戳命名，自动清理过期数据（默认保留 24h），避免磁盘爆满 |
| **按时间回查** | 提供命令行工具和 HTTP API，输入时间段自动定位对应的采样文件 |
| **一键生成火焰图** | 对指定时间段的采样数据，自动调用 FlameGraph 工具链生成 SVG 火焰图 |

---

## 架构设计说明

### 整体架构

```
┌────────────────────────────────────────────────────────────┐
│                    Docker 容器 (--privileged)               │
│                                                            │
│  ┌──────────────┐                                          │
│  │ entrypoint.sh │  ← 容器入口，启动并管理所有服务            │
│  └──────┬───────┘                                          │
│         │                                                  │
│    ┌────┼────────────┬──────────────┐                      │
│    ▼    ▼            ▼              ▼                      │
│  ┌─────────┐  ┌────────────┐  ┌──────────┐                │
│  │collector│  │ cleaner 循环│  │ api.py  │                │
│  │  .sh    │  │ (每10分钟)  │  │ :8080   │                │
│  └────┬────┘  └─────┬──────┘  └────┬─────┘                │
│       │             │              │                       │
│  ┌────▼────┐   ┌────▼──────┐  ┌───▼──────────┐            │
│  │perf     │   │cleaner.sh │  │Flask HTTP API│            │
│  │record   │   │清理过期数据│  │              │            │
│  │持续采集  │   └───────────┘  │ /api/health  │            │
│  └────┬────┘                  │ /api/status  │            │
│       │                       │ /api/files   │──► query.py│
│  ┌────▼──────────┐            │ /api/flame   │──► flame   │
│  │ /data/perf_raw│            │    graph     │    graph.py│
│  │ perf_*.data   │            └──────────────┘            │
│  └────┬──────────┘                                        │
│       │                                                   │
│  ┌────▼──────────┐                                        │
│  │ /data/perf_svg│                                        │
│  │ flame_*.svg   │                                        │
│  └───────────────┘                                        │
└────────────────────────────────────────────────────────────┘
```

### 核心模块说明

| 模块 | 类型 | 职责 |
|------|------|------|
| `entrypoint.sh` | Bash | 容器启动入口，管理所有子进程生命周期，捕获退出信号优雅终止 |
| `collector.sh` | Bash | 7×24 持续采集进程，每 60s 轮转生成 `perf_*.data`，支持硬件/软件事件自动降级 |
| `cleaner.sh` | Bash | 清理过期数据，支持 `--dry-run` 预演，返回删除文件数量 |
| `query.py` | Python CLI | 按时间范围回查 `perf_*.data` 文件，输出匹配文件列表 |
| `flamegraph.py` | Python CLI | 调用 FlameGraph 工具链（`perf script` → `stackcollapse-perf.pl` → `flamegraph.pl`）生成 SVG |
| `api.py` | Python Flask | HTTP REST API，提供健康检查、状态查询、文件查询、火焰图生成接口 |

### 数据流

```
perf record (持续采集)
       │
       ▼
/data/perf_raw/perf_YYYYMMDD_HHMMSS.data
       │
       ├── cleaner.sh ──► 删除过期文件（>24h）
       │
       ├── query.py ────► 按时间段匹配文件列表
       │
       └── flamegraph.py ──► perf script
                                 │
                          stackcollapse-perf.pl
                                 │
                           flamegraph.pl
                                 │
                                 ▼
                    /data/perf_svg/flame_*.svg
```

---

## 快速启动命令

### 1. 加载 Docker 镜像

```bash
docker load -i profiler.tar
```

### 2. 启动容器

```bash
docker run --privileged -d \
    --name profiler \
    -p 8080:8080 \
    -v /data/profiler:/data \
    profiler:latest
```

> **注意**：必须使用 `--privileged` 模式，因为 `perf` 需要访问宿主机内核的 PMU（Performance Monitoring Unit）。

### 3. 验证运行状态

```bash
# 查看日志
docker logs -f profiler

# 健康检查
curl http://localhost:8080/api/health
```

### 4. 环境变量（可选覆盖）

```bash
docker run --privileged -d \
    -p 8080:8080 \
    -v /data/profiler:/data \
    -e RETENTION_HOURS=48 \
    -e PERF_FREQ=199 \
    -e API_PORT=9090 \
    profiler:latest
```

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RETENTION_HOURS` | 24 | 数据保留时长（小时） |
| `PERF_FREQ` | 99 | 采样频率（Hz） |
| `PERF_DURATION` | 60 | 采集轮转间隔（秒） |
| `API_PORT` | 8080 | HTTP API 监听端口 |
| `DATA_DIR` | /data/perf_raw | 采样数据目录 |
| `SVG_DIR` | /data/perf_svg | 火焰图输出目录 |

---

## 使用示例

### 1. 查询时间段内的采样文件

```bash
curl "http://localhost:8080/api/files?start=2026-06-19T03:00&end=2026-06-19T03:05"
```

响应示例：
```json
{
  "count": 3,
  "files": [
    "/data/perf_raw/perf_20260619_030001.data",
    "/data/perf_raw/perf_20260619_030100.data",
    "/data/perf_raw/perf_20260619_030200.data"
  ],
  "start": "2026-06-19 03:00",
  "end": "2026-06-19 03:05"
}
```

### 2. 生成火焰图

```bash
# 直接保存为 SVG 文件
curl "http://localhost:8080/api/flamegraph?file=/data/perf_raw/perf_20260619_030000.data" \
    > flame.svg

# 自定义宽度
curl "http://localhost:8080/api/flamegraph?file=/data/perf_raw/perf_20260619_030000.data&width=1600" \
    > flame_wide.svg
```

### 3. 查看系统状态

```bash
curl http://localhost:8080/api/status
```

响应示例：
```json
{
  "collector_running": true,
  "disk_usage": "45M",
  "file_count": 1440,
  "recent_files": [
    {"name": "perf_20260619_110000.data", "size_bytes": 32768, "mtime": "2026-06-19 11:01:00"}
  ]
}
```

### 4. 命令行方式查询文件

```bash
# 直接在容器内使用 query.py
docker exec profiler python3 /app/src/query.py \
    --start "2026-06-19 03:00" \
    --end "2026-06-19 03:05"
```

### 5. 命令行方式生成火焰图

```bash
# 直接在容器内使用 flamegraph.py
docker exec profiler python3 /app/src/flamegraph.py \
    --input /data/perf_raw/perf_20260619_030000.data \
    --output /tmp/flame.svg
```

### 6. 手动清理过期数据

```bash
# 查看将被删除的文件（不实际删除）
docker exec profiler /app/src/cleaner.sh --dry-run

# 执行清理
docker exec profiler /app/src/cleaner.sh
```

---

## 设计权衡说明

### 1. 为什么优先使用 cpu-clock 而不是 cycles

- **cycles** 依赖硬件 PMU（Performance Monitoring Unit），在虚拟化环境或部分云主机中不可用
- 本工具启动时自动探测硬件 PMU 可用性，**优先尝试 `cycles`**，失败后自动降级到 `cpu-clock`（软件事件）
- `cpu-clock` 基于内核软件时钟，兼容性最好，适合绝大多数部署环境
- 容器以 `--privileged` 运行时，通常可以使用 `cycles` 获得更精确的采样

### 2. 为什么 60 秒轮转

- **粒度**：60 秒粒度足以定位到具体的故障时刻（如凌晨 CPU 飙升的分钟级定位）
- **文件大小**：单次 60 秒 `perf record` 生成的数据文件通常在几十 KB 到几 MB，24 小时约产生 1440 个文件
- **磁盘开销**：24 小时数据总量通常在 100MB ~ 500MB，对生产环境影响可控
- **可通过环境变量 `PERF_DURATION` 调整**

### 3. 为什么保留 24 小时

- **运维场景**：大多数故障在发生后 24 小时内会被发现和处理，24 小时覆盖了常见的回溯需求
- **磁盘预算**：24 小时数据量可控，不会因长期运行导致磁盘爆满
- **可通过环境变量 `RETENTION_HOURS` 调整**，支持延长到 48h / 72h 等

### 4. 为什么用 99Hz 采样频率

- `perf` 官方推荐频率：避免与系统定时器（100Hz / 250Hz / 1000Hz）同步导致采样偏差
- 99Hz 在精度和开销之间取得良好平衡
- **可通过环境变量 `PERF_FREQ` 调整**

### 5. 容器化设计的考量

- `--privileged` 是必须的：`perf` 需要访问 `/proc/sys/kernel/perf_event_paranoid` 和内核 PMU
- 数据目录 `/data` 建议挂载宿主机卷，防止容器删除后数据丢失
- 单容器架构简化部署，避免多容器通信的复杂性

---

## 测试验证

### 测试脚本

```bash
# 运行测试（在宿主机上）
bash test/test_scenario.sh
```

### 测试流程

1. **启动采集容器**
2. **构造 CPU 飙升场景**：使用 `stress-ng` 模拟 60 秒 CPU 压力
   ```bash
   stress-ng --cpu 2 --cpu-method matrixprod -t 60s
   ```
3. **记录飙升时间段**
4. **使用 API 回查该时间段**的采样文件
5. **生成火焰图**，验证 `matrixprod` 热点函数出现在火焰图中

### 预期结果

- 查询 API 返回匹配时间段的 `perf_*.data` 文件列表
- 生成的火焰图 SVG 中能看到 `stress-ng` / `matrixprod` 相关的函数调用栈热点
- 火焰图顶部应有明显的 `matrix_prod` 或类似函数名占比较大宽度

---

## 目录结构

```
.
├── Dockerfile                  # Docker 镜像构建文件
├── README.md                   # 项目文档（本文件）
├── requirements.txt            # Python 依赖
├── .dockerignore               # Docker 构建忽略规则
├── src/
│   ├── entrypoint.sh           # 容器启动入口
│   ├── collector.sh            # 持续 CPU 采集脚本
│   ├── cleaner.sh              # 过期数据清理脚本
│   ├── query.py                # 按时间回查工具
│   ├── flamegraph.py           # 火焰图生成工具
│   └── api.py                  # HTTP REST API 服务
├── test/
│   ├── test_scenario.sh        # 测试验证脚本
│   └── screenshots/            # 测试截图（可选）
└── ai-chat-log/                # AI 对话记录
```

---

## API 接口速查

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/health` | 健康状态检查 |
| GET | `/api/status` | 系统概览（磁盘、文件数、采集状态） |
| GET | `/api/files?start=...&end=...` | 按时间查询采样文件 |
| GET | `/api/flamegraph?file=...&width=...` | 生成火焰图 SVG |

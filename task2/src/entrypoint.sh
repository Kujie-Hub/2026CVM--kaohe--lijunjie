#!/bin/bash
#===============================================================================
# entrypoint.sh - Docker 容器启动入口
#===============================================================================
# 功能：
#   1. 后台启动 collector.sh   — 7x24 持续 CPU Profiling 采集
#   2. 后台启动 HTTP API 服务    — 提供查询 / 火焰图生成接口
#   3. 后台启动 cleaner 定时任务  — 每 10 分钟清理过期数据
#   4. 捕获 SIGTERM / SIGINT，优雅关闭所有子进程
#   5. 容器保持前台运行，日志输出到 stdout
#
# 环境变量（可通过 docker run -e 覆盖）：
#   RETENTION_HOURS - 数据保留时长，默认 24
#   PERF_FREQ       - 采样频率(Hz)，默认 99
#   PERF_DURATION   - 采集轮转间隔(秒)，默认 60
#   API_PORT        - HTTP API 监听端口，默认 8080
#   DATA_DIR        - 数据目录，默认 /data/perf_raw
#   SVG_DIR         - 火焰图输出目录，默认 /data/perf_svg
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# 环境变量默认值
#-------------------------------------------------------------------------------
RETENTION_HOURS="${RETENTION_HOURS:-24}"
PERF_FREQ="${PERF_FREQ:-99}"
PERF_DURATION="${PERF_DURATION:-60}"
API_PORT="${API_PORT:-8080}"
DATA_DIR="${DATA_DIR:-/data/perf_raw}"
SVG_DIR="${SVG_DIR:-/data/perf_svg}"

# 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 子进程 PID 记录
COLLECTOR_PID=""
API_PID=""
CLEANER_LOOP_PID=""

# 退出标志
EXIT_REQUESTED=0

#-------------------------------------------------------------------------------
# 日志函数
#-------------------------------------------------------------------------------
log() {
    echo "[entrypoint] [$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

#-------------------------------------------------------------------------------
# 信号处理：优雅关闭所有子进程
#-------------------------------------------------------------------------------
graceful_shutdown() {
    log "收到退出信号，开始优雅关闭所有服务..."

    EXIT_REQUESTED=1

    # 按启动的逆序关闭子进程

    # 1. 关闭 cleaner 定时任务
    if [[ -n "${CLEANER_LOOP_PID}" ]] && kill -0 "${CLEANER_LOOP_PID}" 2>/dev/null; then
        log "正在停止 cleaner 定时任务 (PID: ${CLEANER_LOOP_PID})..."
        kill -TERM "${CLEANER_LOOP_PID}" 2>/dev/null || true
        wait "${CLEANER_LOOP_PID}" 2>/dev/null || true
        log "cleaner 定时任务已停止"
    fi

    # 2. 关闭 API 服务
    if [[ -n "${API_PID}" ]] && kill -0 "${API_PID}" 2>/dev/null; then
        log "正在停止 API 服务 (PID: ${API_PID})..."
        kill -TERM "${API_PID}" 2>/dev/null || true
        wait "${API_PID}" 2>/dev/null || true
        log "API 服务已停止"
    fi

    # 3. 关闭 collector 采集进程
    if [[ -n "${COLLECTOR_PID}" ]] && kill -0 "${COLLECTOR_PID}" 2>/dev/null; then
        log "正在停止 collector 采集进程 (PID: ${COLLECTOR_PID})..."
        kill -TERM "${COLLECTOR_PID}" 2>/dev/null || true
        wait "${COLLECTOR_PID}" 2>/dev/null || true
        log "collector 采集进程已停止"
    fi

    log "所有服务已安全关闭"
}

# 注册信号处理器
trap graceful_shutdown SIGTERM SIGINT

#-------------------------------------------------------------------------------
# 创建必要目录
#-------------------------------------------------------------------------------
setup_directories() {
    log "初始化目录..."
    mkdir -p "${DATA_DIR}"
    mkdir -p "${SVG_DIR}"
    log "  数据目录: ${DATA_DIR}"
    log "  SVG 目录: ${SVG_DIR}"
}

#-------------------------------------------------------------------------------
# 打印启动信息
#-------------------------------------------------------------------------------
print_banner() {
    log "============================================"
    log "  CPU Profiling 工具 - 容器启动"
    log "============================================"
    log "  配置:"
    log "    RETENTION_HOURS = ${RETENTION_HOURS} h"
    log "    PERF_FREQ       = ${PERF_FREQ} Hz"
    log "    PERF_DURATION   = ${PERF_DURATION} s"
    log "    API_PORT        = ${API_PORT}"
    log "    DATA_DIR        = ${DATA_DIR}"
    log "    SVG_DIR         = ${SVG_DIR}"
    log "============================================"
}

#-------------------------------------------------------------------------------
# 1. 启动 collector.sh — 后台持续采集
#-------------------------------------------------------------------------------
start_collector() {
    log "[启动] collector — 后台持续 CPU Profiling 采集"

    local collector_script="${SCRIPT_DIR}/collector.sh"
    if [[ ! -f "${collector_script}" ]]; then
        log "[ERROR] collector.sh 未找到: ${collector_script}"
        exit 1
    fi

    # 导出环境变量给子进程
    export RETENTION_HOURS PERF_FREQ PERF_DURATION OUTPUT_DIR="${DATA_DIR}"

    # 后台启动，日志输出到 stdout
    bash "${collector_script}" &
    COLLECTOR_PID=$!

    log "  collector 已启动 (PID: ${COLLECTOR_PID})"

    # 等待一小段时间，确认 collector 没有立即崩溃
    sleep 2
    if ! kill -0 "${COLLECTOR_PID}" 2>/dev/null; then
        log "[FATAL] collector 启动后立即退出，容器终止"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# 2. 启动 HTTP API 服务
#-------------------------------------------------------------------------------
start_api() {
    log "[启动] API — HTTP 查询接口 (端口: ${API_PORT})"

    local api_script="${SCRIPT_DIR}/api.py"
    if [[ ! -f "${api_script}" ]]; then
        log "[WARN] api.py 未找到: ${api_script}，跳过 API 服务启动"
        return
    fi

    # 导出环境变量
    export DATA_DIR SVG_DIR FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-/tmp/FlameGraph}"

    python3 "${api_script}" --port "${API_PORT}" --data-dir "${DATA_DIR}" --svg-dir "${SVG_DIR}" &
    API_PID=$!

    log "  API 服务已启动 (PID: ${API_PID})"
}

#-------------------------------------------------------------------------------
# 3. 启动 cleaner 定时任务 — 每 10 分钟清理一次
#-------------------------------------------------------------------------------
start_cleaner_loop() {
    log "[启动] cleaner — 定时清理任务（每 10 分钟）"

    local cleaner_script="${SCRIPT_DIR}/cleaner.sh"
    if [[ ! -f "${cleaner_script}" ]]; then
        log "[WARN] cleaner.sh 未找到: ${cleaner_script}，跳过定时清理"
        return
    fi

    # 导出环境变量
    export RETENTION_HOURS DATA_DIR

    # 后台循环：每 10 分钟执行一次 cleaner.sh
    (
        while true; do
            sleep 600  # 10 分钟 = 600 秒

            # 检查是否收到退出信号
            if [[ ${EXIT_REQUESTED} -ne 0 ]]; then
                break
            fi

            log "[cleaner] 执行定时清理..."
            bash "${cleaner_script}" 2>&1 | while IFS= read -r line; do
                echo "[cleaner] ${line}"
            done
        done
    ) &
    CLEANER_LOOP_PID=$!

    log "  cleaner 定时任务已启动 (PID: ${CLEANER_LOOP_PID})"
}

#-------------------------------------------------------------------------------
# 4. 监控子进程 — fail-fast 机制
#    如果 collector 异常退出，容器也退出
#-------------------------------------------------------------------------------
monitor_children() {
    log "所有服务已启动，进入监控模式..."

    while [[ ${EXIT_REQUESTED} -eq 0 ]]; do
        # 检查 collector 是否存活
        if [[ -n "${COLLECTOR_PID}" ]] && ! kill -0 "${COLLECTOR_PID}" 2>/dev/null; then
            wait "${COLLECTOR_PID}" 2>/dev/null || true
            local collector_exit=$?
            log "[FATAL] collector 进程异常退出（退出码: ${collector_exit}），容器终止"
            EXIT_REQUESTED=1
            break
        fi

        # 检查 API 是否存活（非致命，仅记录警告）
        if [[ -n "${API_PID}" ]] && ! kill -0 "${API_PID}" 2>/dev/null; then
            wait "${API_PID}" 2>/dev/null || true
            local api_exit=$?
            log "[WARN] API 服务异常退出（退出码: ${api_exit}），尝试重启..."
            start_api
        fi

        sleep 5
    done

    # 触发优雅关闭
    graceful_shutdown
}

#-------------------------------------------------------------------------------
# 主流程
#-------------------------------------------------------------------------------
main() {
    print_banner
    setup_directories

    start_collector
    start_api
    start_cleaner_loop

    monitor_children
}

main "$@"

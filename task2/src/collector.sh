#!/bin/bash
#===============================================================================
# collector.sh - 7x24 持续 CPU Profiling 采集脚本
#===============================================================================
# 功能：使用 perf record 持续采集系统级 CPU 调用栈数据
#       - 每 60 秒轮转一次，生成独立的采样文件
#       - 文件名格式：perf_YYYYMMDD_HHMMSS.data
#       - 自动清理过期数据，避免磁盘爆满
#       - 支持优雅终止（捕获 SIGINT / SIGTERM）
#
# 环境变量：
#   RETENTION_HOURS   - 数据保留时长（小时），默认 24
#   OUTPUT_DIR        - 数据输出目录，默认 /data/perf_raw/
#   PERF_FREQ         - 采样频率（Hz），默认 99
#   PERF_DURATION     - 每轮采集时长（秒），默认 60
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# 环境变量默认值
#-------------------------------------------------------------------------------
RETENTION_HOURS="${RETENTION_HOURS:-24}"
OUTPUT_DIR="${OUTPUT_DIR:-/data/perf_raw}"
PERF_FREQ="${PERF_FREQ:-99}"
PERF_DURATION="${PERF_DURATION:-60}"

# 日志文件（同时输出到 stdout 和文件）
LOG_FILE="${OUTPUT_DIR}/collector.log"

# 全局标志：是否收到退出信号
EXIT_REQUESTED=0

#-------------------------------------------------------------------------------
# 日志函数：同时输出到 stdout 和日志文件
#-------------------------------------------------------------------------------
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

#-------------------------------------------------------------------------------
# 信号处理函数：捕获退出信号，优雅终止
#-------------------------------------------------------------------------------
handle_signal() {
    log "收到退出信号，正在优雅终止..."
    EXIT_REQUESTED=1
}

# 注册信号处理器
trap handle_signal SIGINT SIGTERM

#-------------------------------------------------------------------------------
# 检查 perf 是否可用
#-------------------------------------------------------------------------------
check_perf() {
    log "============================================"
    log "CPU Profiling 采集器启动"
    log "============================================"
    log "配置信息："
    log "  OUTPUT_DIR      = ${OUTPUT_DIR}"
    log "  RETENTION_HOURS = ${RETENTION_HOURS} h"
    log "  PERF_FREQ       = ${PERF_FREQ} Hz"
    log "  PERF_DURATION   = ${PERF_DURATION} s"
    log "============================================"

    # 检查 perf 命令是否存在
    if ! command -v perf &> /dev/null; then
        log "[ERROR] perf 命令不可用，请确认："
        log "       1. 系统中已安装 linux-tools / perf 包"
        log "       2. 容器以 --privileged 模式运行"
        log "       3. perf 版本与内核版本匹配"
        exit 1
    fi

    local perf_version
    perf_version=$(perf --version 2>&1 | head -1)
    log "[OK] perf 可用：${perf_version}"

    # 探测硬件 PMU 是否可用（优先使用 cycles 事件）
    # 某些虚拟化环境 / 容器中 PMU 不可访问，此时自动降级到 cpu-clock
    if perf record -e cycles -F 1 -a -o /dev/null -- sleep 0.1 2>/dev/null; then
        PERF_EVENT="cycles"
        log "[OK] 硬件 PMU 可用，使用事件: cycles"
    else
        PERF_EVENT="cpu-clock"
        log "[WARN] 硬件 PMU 不可用，降级到 cpu-clock（软件事件）"
        log "       若需硬件事件，请确保容器以 --privileged 模式运行且宿主机支持 PMU"
    fi
}

#-------------------------------------------------------------------------------
# 创建输出目录
#-------------------------------------------------------------------------------
setup_output_dir() {
    if ! mkdir -p "${OUTPUT_DIR}"; then
        log "[ERROR] 无法创建输出目录: ${OUTPUT_DIR}"
        exit 1
    fi
    log "[OK] 输出目录已就绪: ${OUTPUT_DIR}"
}

#-------------------------------------------------------------------------------
# 清理过期数据
# 根据 RETENTION_HOURS 删除超出保留时长的 .data 文件
#-------------------------------------------------------------------------------
cleanup_old_data() {
    local retention_minutes=$((RETENTION_HOURS * 60))

    # 查找并删除过期的 perf 数据文件
    local deleted_count=0
    while IFS= read -r -d '' old_file; do
        log "[CLEANUP] 删除过期文件: $(basename "$old_file")"
        rm -f "$old_file"
        ((deleted_count++)) || true
    done < <(find "${OUTPUT_DIR}" -maxdepth 1 -name "perf_*.data" -type f \
        -mmin "+${retention_minutes}" -print0 2>/dev/null)

    if [[ $deleted_count -gt 0 ]]; then
        log "[CLEANUP] 本次清理了 ${deleted_count} 个过期文件"
    fi
}

#-------------------------------------------------------------------------------
# 计算并输出当前数据目录占用磁盘大小
#-------------------------------------------------------------------------------
show_disk_usage() {
    local usage
    usage=$(du -sh "${OUTPUT_DIR}" 2>/dev/null | cut -f1)
    log "[DISK] 当前数据目录占用磁盘: ${usage}"
}

#-------------------------------------------------------------------------------
# 主采集循环
# 每次循环执行一次 perf record，生成一个带时间戳的采样文件
# 然后检查是否需要清理过期数据
#-------------------------------------------------------------------------------
run_collection_loop() {
    # 在采集循环中临时关闭 set -e，避免以下情况导致脚本意外退出：
    #   1. iteration 递增操作在边界情况的返回码问题
    #   2. perf record 管道中 while 循环的退出码传播
    #   3. stat 命令在某些边缘情况下返回非零
    #   4. 管道断开（SIGPIPE）导致 perf record 提前终止
    # 循环内部通过显式检查 exit_code 来处理错误
    set +e

    log "开始持续采集，每 ${PERF_DURATION} 秒生成一个采样文件..."
    log "按 Ctrl+C 或发送 SIGTERM 信号终止"
    log ""

    local iteration=0

    while [[ $EXIT_REQUESTED -eq 0 ]]; do
        # 生成时间戳文件名
        local timestamp
        timestamp=$(date '+%Y%m%d_%H%M%S')
        local output_file="${OUTPUT_DIR}/perf_${timestamp}.data"

        # 更新迭代计数
        iteration=$((iteration + 1))

        log "[CYCLE ${iteration}] 开始采集 -> ${output_file}"

        # 执行 perf record：
        #   -F <freq>    : 采样频率
        #   -a           : 采集所有 CPU
        #   -g           : 记录调用图（call graph），用于后续生成火焰图
        #   -e <event>   : 优先 cycles（硬件PMU），不可用时降级为 cpu-clock（软件）
        #   -o <file>    : 输出文件
        #   -- sleep N   : 采集 N 秒后自动停止
        #
        # 注意：
        #   - 使用 -- 分隔 perf 参数和要监控的命令（sleep）
        #   - 不通过管道过滤 stderr，避免管道断开导致 SIGPIPE 终止 perf
        #   - 直接将 perf stderr 追加到日志文件
        perf record \
            -F "${PERF_FREQ}" \
            -a \
            -g \
            -e "${PERF_EVENT}" \
            -o "${output_file}" \
            -- sleep "${PERF_DURATION}" \
            2>>"${LOG_FILE}"

        local exit_code=$?

        # 运行时降级保护：如果使用 cycles 失败，自动降级到 cpu-clock 重试
        if [[ $exit_code -ne 0 ]] && [[ "${PERF_EVENT}" == "cycles" ]]; then
            log "[WARN] cycles 事件采集失败（退出码: ${exit_code}），硬件 PMU 不可用，降级到 cpu-clock"
            PERF_EVENT="cpu-clock"
            log "[CYCLE ${iteration}] 降级重试 -> ${output_file}"

            # 使用 cpu-clock 重试本轮采集
            perf record \
                -F "${PERF_FREQ}" \
                -a \
                -g \
                -e "${PERF_EVENT}" \
                -o "${output_file}" \
                -- sleep "${PERF_DURATION}" \
                2>>"${LOG_FILE}"
            exit_code=$?
        fi

        if [[ $exit_code -ne 0 ]]; then
            log "[WARN] 第 ${iteration} 轮采集异常退出（退出码: ${exit_code}），继续下一轮..."
        else
            # 输出文件大小用于确认采集结果
            local file_size
            file_size=$(stat -c%s "${output_file}" 2>/dev/null || echo "0")
            log "[CYCLE ${iteration}] 采集完成，文件大小: ${file_size} bytes"
        fi

        # 每 5 轮做一次过期清理和磁盘用量检查（减少清理开销）
        if [[ $((iteration % 5)) -eq 0 ]]; then
            cleanup_old_data
            show_disk_usage
        fi

        # 如果是收到退出信号后的最后一轮，额外清理一次
        if [[ $EXIT_REQUESTED -ne 0 ]]; then
            cleanup_old_data
            break
        fi

        # 短延迟防止极端情况下 CPU 空转（实际上 perf record 本身已阻塞 60s，
        # 此处的 sleep 是为了在 perf 意外快速退出时避免疯狂重试）
        sleep 0.1
    done

    # 恢复 set -e（保持良好习惯）
    set -e
}

#-------------------------------------------------------------------------------
# 终止处理：清理当前正在进行的 perf 进程并退出
#-------------------------------------------------------------------------------
cleanup_on_exit() {
    log "============================================"
    log "采集器正在退出..."

    # 杀掉所有由本脚本启动的 perf 子进程
    pkill -P $$ perf 2>/dev/null || true

    # 最后一次清理过期数据
    cleanup_old_data
    show_disk_usage

    log "采集器已安全退出，共运行 ${iteration:-0} 轮采集"
    log "============================================"
}

# 注册退出时的清理函数
trap cleanup_on_exit EXIT

#-------------------------------------------------------------------------------
# 主流程入口
#-------------------------------------------------------------------------------
main() {
    # 1. 检查 perf 是否可用
    check_perf

    # 2. 创建输出目录
    setup_output_dir

    # 3. 启动采集循环
    run_collection_loop
}

# 执行主函数
main "$@"

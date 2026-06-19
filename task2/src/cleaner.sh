#!/bin/bash
#===============================================================================
# cleaner.sh - perf 采样数据清理脚本
#===============================================================================
# 功能：清理 /data/perf_raw/ 目录下超过保留时长的 perf_*.data 文件
#       - 支持 --dry-run 模式，仅列出不删除
#       - 清理前后输出磁盘占用信息
#       - 返回实际删除/可删除的文件数量
#
# 环境变量：
#   RETENTION_HOURS - 数据保留时长（小时），默认 24
#   DATA_DIR        - 数据目录，默认 /data/perf_raw/
#
# 用法：
#   ./cleaner.sh              # 正常清理
#   ./cleaner.sh --dry-run    # 预演模式，只列出不删除
#   RETENTION_HOURS=48 ./cleaner.sh    # 自定义保留时长
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# 环境变量默认值
#-------------------------------------------------------------------------------
RETENTION_HOURS="${RETENTION_HOURS:-24}"
DATA_DIR="${DATA_DIR:-/data/perf_raw}"

# 是否为 dry-run 模式
DRY_RUN=false

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

#-------------------------------------------------------------------------------
# 显示磁盘占用
#-------------------------------------------------------------------------------
show_disk_usage() {
    if [[ -d "${DATA_DIR}" ]]; then
        local usage
        usage=$(du -sh "${DATA_DIR}" 2>/dev/null | cut -f1)
        log "当前数据目录磁盘占用: ${usage}  (${DATA_DIR})"
    else
        log "数据目录不存在: ${DATA_DIR}"
    fi
}

#-------------------------------------------------------------------------------
# 解析命令行参数
#-------------------------------------------------------------------------------
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run)
                DRY_RUN=true
                ;;
            *)
                log "未知参数: $arg"
                echo "用法: $0 [--dry-run]"
                exit 1
                ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# 主清理逻辑
#-------------------------------------------------------------------------------
run_cleanup() {
    local retention_minutes=$((RETENTION_HOURS * 60))
    local deleted_count=0

    # 检查目录是否存在
    if [[ ! -d "${DATA_DIR}" ]]; then
        log "[WARN] 数据目录不存在: ${DATA_DIR}，无需清理"
        echo "0"
        return 0
    fi

    #-----------------------------------------------------------------------
    # 清理前磁盘占用
    #-----------------------------------------------------------------------
    show_disk_usage

    #-----------------------------------------------------------------------
    # 查找过期文件
    # 使用 find 查找超过 retention_minutes 分钟的 perf_*.data 文件
    #-----------------------------------------------------------------------
    log "============================================"
    log "清理策略: 保留最近 ${RETENTION_HOURS} 小时的数据"
    log "数据目录: ${DATA_DIR}"
    if $DRY_RUN; then
        log "模式: DRY-RUN（仅列出，不删除）"
    fi
    log "============================================"

    # 先统计过期文件数量
    local expired_count
    expired_count=$(find "${DATA_DIR}" -maxdepth 1 -name "perf_*.data" -type f \
        -mmin "+${retention_minutes}" 2>/dev/null | wc -l)

    if [[ $expired_count -eq 0 ]]; then
        log "没有发现过期文件"
        show_disk_usage
        echo "0"
        return 0
    fi

    log "发现 ${expired_count} 个过期文件:"

    # 遍历过期文件
    while IFS= read -r -d '' old_file; do
        local fname
        fname=$(basename "$old_file")
        local fsize
        fsize=$(du -h "$old_file" 2>/dev/null | cut -f1)

        if $DRY_RUN; then
            # dry-run 模式：只输出信息，不删除
            log "  [DRY-RUN] 将删除: ${fname}  (${fsize})"
        else
            # 正常模式：删除文件
            log "  [DELETE] 删除: ${fname}  (${fsize})"
            rm -f "$old_file"
        fi

        ((deleted_count++)) || true
    done < <(find "${DATA_DIR}" -maxdepth 1 -name "perf_*.data" -type f \
        -mmin "+${retention_minutes}" -print0 2>/dev/null)

    #-----------------------------------------------------------------------
    # 清理后磁盘占用
    #-----------------------------------------------------------------------
    if $DRY_RUN; then
        log "----------------------------------------"
        log "DRY-RUN 完成，共 ${deleted_count} 个文件将被删除"
        log "----------------------------------------"
    else
        log "----------------------------------------"
        log "清理完成，共删除 ${deleted_count} 个文件"
        log "----------------------------------------"
    fi

    show_disk_usage

    # 返回删除的文件数量
    echo "${deleted_count}"
}

#-------------------------------------------------------------------------------
# 主函数
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"
    run_cleanup
}

# 执行并捕获返回值
main "$@"
exit $?

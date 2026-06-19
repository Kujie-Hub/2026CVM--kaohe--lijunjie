#!/bin/bash
#===============================================================================
# test_scenario.sh - CPU 飙升场景测试脚本
#===============================================================================
# 功能：使用 stress-ng 构造可复现的 CPU 飙升场景，验证 profiling 工具的有效性。
#
# 用法：
#   bash test/test_scenario.sh
#
# 前置条件：
#   - profiling 工具容器已启动
#   - 本脚本在宿主机或容器内执行均可
#
# 测试流程：
#   1. 检查 stress-ng 是否可用，不可用则自动安装
#   2. 记录开始时间
#   3. 执行 60 秒 CPU 压力（matrixprod 矩阵乘法）
#   4. 记录结束时间
#   5. 输出测试摘要
#   6. 提示使用 API 回查并生成火焰图
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# 日志函数
#-------------------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

#-------------------------------------------------------------------------------
# 检查并安装 stress-ng
#-------------------------------------------------------------------------------
check_stress_ng() {
    if command -v stress-ng &> /dev/null; then
        log "[OK] stress-ng 已安装: $(stress-ng --version 2>&1 | head -1)"
        return 0
    fi

    log "[INFO] stress-ng 未找到，尝试安装..."

    # 检测包管理器
    if command -v apt-get &> /dev/null; then
        log "[INFO] 使用 apt-get 安装 stress-ng..."
        sudo apt-get update -qq && sudo apt-get install -y -qq stress-ng
    elif command -v yum &> /dev/null; then
        log "[INFO] 使用 yum 安装 stress-ng..."
        sudo yum install -y stress-ng
    elif command -v dnf &> /dev/null; then
        log "[INFO] 使用 dnf 安装 stress-ng..."
        sudo dnf install -y stress-ng
    else
        log "[ERROR] 无法确定包管理器，请手动安装 stress-ng"
        exit 1
    fi

    # 验证安装
    if command -v stress-ng &> /dev/null; then
        log "[OK] stress-ng 安装成功"
    else
        log "[ERROR] stress-ng 安装失败"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# 记录时间戳（ISO 8601 格式）
#-------------------------------------------------------------------------------
timestamp_now() {
    date '+%Y-%m-%d %H:%M:%S'
}

#-------------------------------------------------------------------------------
# 主测试流程
#-------------------------------------------------------------------------------
main() {
    log "============================================"
    log "  CPU Profiling 工具 - 测试验证"
    log "============================================"
    log ""

    # 1. 检查 stress-ng
    log "[Step 1/4] 检查 stress-ng..."
    check_stress_ng
    log ""

    # 2. 记录开始时间
    log "[Step 2/4] 记录开始时间并启动 CPU 压力测试..."
    START_TIME=$(timestamp_now)
    START_EPOCH=$(date +%s)

    log "  开始时间: ${START_TIME}"
    log "  压力参数: stress-ng --cpu 2 --cpu-method matrixprod -t 60s"
    log ""

    # 3. 执行 stress-ng
    log "[Step 3/4] 执行 CPU 压力测试（持续 60 秒）..."
    log "  (请等待 60 秒...)"
    log ""

    if stress-ng --cpu 2 --cpu-method matrixprod -t 60s; then
        log ""
        log "[OK] stress-ng 执行完成"
    else
        log ""
        log "[ERROR] stress-ng 执行失败（退出码: $?）"
        exit 1
    fi

    # 4. 记录结束时间
    END_TIME=$(timestamp_now)
    END_EPOCH=$(date +%s)
    DURATION=$((END_EPOCH - START_EPOCH))

    # 5. 输出测试摘要
    log ""
    log "============================================"
    log "  测试摘要"
    log "============================================"
    log "  开始时间: ${START_TIME}"
    log "  结束时间: ${END_TIME}"
    log "  持续时长: ${DURATION} 秒"
    log "  压力方法: matrixprod (矩阵乘法)"
    log "  CPU 数量: 2"
    log "============================================"
    log ""

    # 6. 提示使用 API 回查
    # 将时间格式转为 API 友好的格式
    START_API=$(echo "${START_TIME}" | sed 's/ /T/')
    END_API=$(echo "${END_TIME}" | sed 's/ /T/')

    log "============================================"
    log "  验证步骤"
    log "============================================"
    log ""
    log "  1. 查询该时间段的采样文件："
    log "     curl \"http://localhost:8080/api/files?start=${START_API}&end=${END_API}\""
    log ""
    log "  2. 对返回的文件逐个生成火焰图："
    log "     curl \"http://localhost:8080/api/flamegraph?file=<文件路径>\" > flame.svg"
    log ""
    log "  3. 用浏览器打开 flame.svg，搜索 \"matrix\" 确认热点函数："
    log "     - 应能看到 matrix_prod 或类似函数在火焰图中占较大宽度"
    log "     - 说明工具成功捕获了 stress-ng 的 CPU 热点"
    log ""
    log "  4. 也可使用命令行直接生成："
    log "     docker exec profiler python3 /app/src/flamegraph.py \\"
    log "         --input /data/perf_raw/<文件名>.data"
    log ""
    log "============================================"
    log "  测试完成！"
    log "============================================"
}

main "$@"

#!/usr/bin/env python3
"""
==============================================================================
query.py - 按时间段回查 perf 采样文件
==============================================================================
功能：根据指定的起止时间，在 /data/perf_raw/ 目录下自动匹配时间戳落在
      范围内的 perf_YYYYMMDD_HHMMSS.data 文件，输出文件列表。

用法：
    python query.py --start "2026-06-19 03:00" --end "2026-06-19 03:05"
    python query.py --start "2026-06-19 03:00"                 # end 默认为当前时间
    python query.py --start "2026-06-19 03:00" --output result.txt

环境变量：
    DATA_DIR - 数据目录，默认 /data/perf_raw/
==============================================================================
"""

import argparse
import glob
import os
import re
import sys
from datetime import datetime

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
DEFAULT_DATA_DIR = os.environ.get("DATA_DIR", "/data/perf_raw")

# 文件名正则：perf_YYYYMMDD_HHMMSS.data
FILENAME_PATTERN = re.compile(r"^perf_(\d{8})_(\d{6})\.data$")


def parse_filename(filepath: str) -> datetime | None:
    """从文件名中解析时间戳，返回 datetime 对象。

    文件名格式: perf_YYYYMMDD_HHMMSS.data

    Args:
        filepath: 文件路径

    Returns:
        解析成功返回 datetime，失败返回 None
    """
    basename = os.path.basename(filepath)
    match = FILENAME_PATTERN.match(basename)
    if not match:
        return None

    date_str = match.group(1)   # YYYYMMDD
    time_str = match.group(2)   # HHMMSS

    try:
        return datetime.strptime(f"{date_str}{time_str}", "%Y%m%d%H%M%S")
    except ValueError:
        return None


def parse_time_arg(time_str: str) -> datetime:
    """解析命令行输入的时间字符串。

    支持格式：
        - "2026-06-19 03:00"
        - "2026-06-19T03:00:00"
        - "20260619_030000"

    Args:
        time_str: 时间字符串

    Returns:
        datetime 对象

    Raises:
        argparse.ArgumentTypeError: 格式无法识别时抛出
    """
    formats = [
        "%Y-%m-%d %H:%M",       # 2026-06-19 03:00
        "%Y-%m-%d %H:%M:%S",    # 2026-06-19 03:00:00
        "%Y-%m-%dT%H:%M",       # 2026-06-19T03:00
        "%Y-%m-%dT%H:%M:%S",    # 2026-06-19T03:00:00
        "%Y%m%d_%H%M%S",        # 20260619_030000
        "%Y%m%d%H%M%S",         # 20260619030000
    ]
    for fmt in formats:
        try:
            return datetime.strptime(time_str, fmt)
        except ValueError:
            continue

    raise argparse.ArgumentTypeError(
        f"无法解析时间: '{time_str}'，支持格式: 'YYYY-MM-DD HH:MM' 等"
    )


def find_perf_files(data_dir: str, start_time: datetime, end_time: datetime) -> list[str]:
    """在数据目录中查找时间戳在 [start_time, end_time] 范围内的 perf 文件。

    匹配策略：
    - perf 文件以 60 秒为轮转周期，文件名时间戳表示该轮采集的开始时间
    - 文件时间戳在 [start_time, end_time] 区间内即视为匹配
    - 同时也会包含在 start_time 之前开始、但采集时段与查询区间有交叠的文件
      （即：文件时间戳 + 60s >= start_time 且 文件时间戳 <= end_time）

    Args:
        data_dir: 数据目录路径
        start_time: 查询起始时间
        end_time: 查询结束时间

    Returns:
        按时间排序的文件路径列表
    """
    if not os.path.isdir(data_dir):
        print(f"[ERROR] 数据目录不存在: {data_dir}", file=sys.stderr)
        return []

    # 获取所有 perf_*.data 文件
    pattern = os.path.join(data_dir, "perf_*.data")
    all_files = glob.glob(pattern)

    matched = []
    for filepath in all_files:
        ts = parse_filename(filepath)
        if ts is None:
            continue

        # 文件采集窗口为 [ts, ts + 60s]
        file_end = ts.timestamp() + 60

        # 有交叠即匹配：文件窗口与查询窗口有重叠
        if ts.timestamp() <= end_time.timestamp() and file_end >= start_time.timestamp():
            matched.append(filepath)

    # 按文件名排序（即按时间排序）
    matched.sort()
    return matched


def main():
    parser = argparse.ArgumentParser(
        description="按时间段回查 perf 采样文件",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
    python query.py --start "2026-06-19 03:00" --end "2026-06-19 03:05"
    python query.py --start "2026-06-19 03:00"
    python query.py --start "2026-06-19 03:00" --output result.txt
        """,
    )

    parser.add_argument(
        "--start", "-s",
        required=True,
        type=parse_time_arg,
        help='起始时间，格式: "YYYY-MM-DD HH:MM" 或 "YYYY-MM-DD HH:MM:SS"',
    )
    parser.add_argument(
        "--end", "-e",
        type=parse_time_arg,
        default=None,
        help='结束时间，格式同上。不指定则默认为当前时间',
    )
    parser.add_argument(
        "--output", "-o",
        type=str,
        default=None,
        help="将结果输出到指定文件（默认输出到 stdout）",
    )
    parser.add_argument(
        "--data-dir", "-d",
        type=str,
        default=DEFAULT_DATA_DIR,
        help=f"数据目录（默认: {DEFAULT_DATA_DIR}）",
    )

    args = parser.parse_args()

    # 处理默认结束时间
    start_time = args.start
    end_time = args.end if args.end else datetime.now()

    # 验证时间顺序
    if start_time >= end_time:
        print(
            f"[ERROR] 起始时间 ({start_time}) 必须早于结束时间 ({end_time})",
            file=sys.stderr,
        )
        sys.exit(1)

    # 查找匹配文件
    files = find_perf_files(args.data_dir, start_time, end_time)

    # 构建输出内容
    lines = []
    lines.append(f"查询时间段: {start_time.strftime('%Y-%m-%d %H:%M:%S')} ~ {end_time.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"数据目录: {args.data_dir}")
    lines.append("-" * 50)

    if not files:
        lines.append("未找到匹配的采样文件。")
    else:
        lines.append(f"找到 {len(files)} 个匹配的采样文件：")
        for f in files:
            lines.append(f"  {f}")

    lines.append("-" * 50)
    lines.append(f"共 {len(files)} 个文件")

    output_text = "\n".join(lines)

    # 输出结果
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(output_text + "\n")
        print(f"结果已保存到: {args.output}")
    else:
        print(output_text)

    # 返回找到的文件数量
    return len(files)


if __name__ == "__main__":
    count = main()
    sys.exit(0 if count >= 0 else 1)

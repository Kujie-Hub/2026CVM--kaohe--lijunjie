#!/usr/bin/env python3
"""
==============================================================================
flamegraph.py - 一键生成火焰图
==============================================================================
功能：接受一个 perf.data 文件，调用 FlameGraph 工具链生成 SVG 火焰图。

处理流程：
    perf.data  --(perf script)--> 文本格式调用栈
        --(stackcollapse-perf.pl)--> 折叠调用栈
        --(flamegraph.pl)--> SVG 火焰图

用法：
    python flamegraph.py --input perf_20260619_030000.data
    python flamegraph.py --input perf_20260619_030000.data --output out.svg
    python flamegraph.py --input perf_20260619_030000.data --width 1600

环境变量：
    FLAMEGRAPH_DIR - FlameGraph 工具链目录，默认自动克隆到 /tmp/FlameGraph
    PERF_SVG_DIR   - SVG 输出目录，默认 /data/perf_svg/
==============================================================================
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
DEFAULT_FLAMEGRAPH_DIR = os.environ.get("FLAMEGRAPH_DIR", "/tmp/FlameGraph")
DEFAULT_SVG_DIR = os.environ.get("PERF_SVG_DIR", "/data/perf_svg")
FLAMEGRAPH_REPO = "https://github.com/brendangregg/FlameGraph.git"

# 输入文件名正则：perf_YYYYMMDD_HHMMSS.data
FILENAME_PATTERN = "perf_"


def ensure_flamegraph_tools(flamegraph_dir: str) -> tuple[str, str]:
    """确保 FlameGraph 工具链可用，不存在则自动克隆。

    Args:
        flamegraph_dir: FlameGraph 工具链目标目录

    Returns:
        (stackcollapse_path, flamegraph_path) 两个脚本的路径

    Raises:
        RuntimeError: 克隆失败或脚本缺失时抛出
    """
    stackcollapse_path = os.path.join(flamegraph_dir, "stackcollapse-perf.pl")
    flamegraph_path = os.path.join(flamegraph_dir, "flamegraph.pl")

    # 如果已存在且两个脚本都就绪，直接返回
    if os.path.isfile(stackcollapse_path) and os.path.isfile(flamegraph_path):
        return stackcollapse_path, flamegraph_path

    # 自动克隆
    print(f"[INFO] FlameGraph 工具链未找到，正在从 GitHub 克隆...")
    print(f"[INFO] 仓库: {FLAMEGRAPH_REPO}")
    print(f"[INFO] 目标: {flamegraph_dir}")

    # 如果目录存在但不完整，先删除
    if os.path.isdir(flamegraph_dir):
        import shutil
        shutil.rmtree(flamegraph_dir)

    parent_dir = os.path.dirname(flamegraph_dir)
    os.makedirs(parent_dir, exist_ok=True)

    try:
        result = subprocess.run(
            ["git", "clone", "--depth", "1", FLAMEGRAPH_REPO, flamegraph_dir],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(f"克隆失败:\n{result.stderr}")
    except subprocess.TimeoutExpired:
        raise RuntimeError("克隆 FlameGraph 仓库超时（120秒）")
    except FileNotFoundError:
        raise RuntimeError("git 命令不可用，请确认已安装 git")

    # 验证克隆后脚本是否存在
    if not os.path.isfile(stackcollapse_path):
        raise RuntimeError(f"克隆完成但未找到 stackcollapse-perf.pl: {stackcollapse_path}")
    if not os.path.isfile(flamegraph_path):
        raise RuntimeError(f"克隆完成但未找到 flamegraph.pl: {flamegraph_path}")

    print(f"[OK] FlameGraph 工具链已就绪: {flamegraph_dir}")
    return stackcollapse_path, flamegraph_path


def run_perf_script(input_file: str) -> str:
    """执行 perf script 将 perf.data 转换为文本调用栈。

    Args:
        input_file: perf.data 文件路径

    Returns:
        perf script 的 stdout 输出

    Raises:
        FileNotFoundError: 输入文件不存在
        RuntimeError: perf script 执行失败
    """
    if not os.path.isfile(input_file):
        raise FileNotFoundError(f"输入文件不存在: {input_file}")

    try:
        result = subprocess.run(
            ["perf", "script", "-i", input_file],
            capture_output=True,
            text=True,
            timeout=300,  # 大文件可能需要较长时间
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"perf script 执行失败（退出码 {result.returncode}）:\n{result.stderr.strip()}"
            )
        return result.stdout
    except subprocess.TimeoutExpired:
        raise RuntimeError("perf script 执行超时（300秒），输入文件可能过大")
    except FileNotFoundError:
        raise RuntimeError("perf 命令不可用，请确认已安装 perf")


def run_stackcollapse(stackcollapse_script: str, perf_output: str) -> str:
    """通过 stackcollapse-perf.pl 折叠调用栈。

    Args:
        stackcollapse_script: stackcollapse-perf.pl 路径
        perf_output: perf script 的文本输出

    Returns:
        折叠后的调用栈文本
    """
    try:
        result = subprocess.run(
            ["perl", stackcollapse_script],
            input=perf_output,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"stackcollapse-perf.pl 执行失败（退出码 {result.returncode}）:\n{result.stderr.strip()}"
            )
        if not result.stdout.strip():
            raise RuntimeError(
                "stackcollapse-perf.pl 输出为空，可能输入数据无有效调用栈信息"
            )
        return result.stdout
    except subprocess.TimeoutExpired:
        raise RuntimeError("stackcollapse-perf.pl 执行超时（120秒）")
    except FileNotFoundError:
        raise RuntimeError("perl 命令不可用，请确认已安装 perl")


def run_flamegraph(flamegraph_script: str, collapsed_data: str, width: int,
                   title: str = "") -> str:
    """通过 flamegraph.pl 生成 SVG 火焰图。

    Args:
        flamegraph_script: flamegraph.pl 路径
        collapsed_data: stackcollapse 的输出
        width: SVG 宽度（像素）
        title: 火焰图标题

    Returns:
        SVG 内容字符串
    """
    cmd = ["perl", flamegraph_script, f"--width={width}"]
    if title:
        cmd.extend(["--title", title])

    try:
        result = subprocess.run(
            cmd,
            input=collapsed_data,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"flamegraph.pl 执行失败（退出码 {result.returncode}）:\n{result.stderr.strip()}"
            )
        if not result.stdout.strip():
            raise RuntimeError("flamegraph.pl 输出为空")
        return result.stdout
    except subprocess.TimeoutExpired:
        raise RuntimeError("flamegraph.pl 执行超时（120秒）")
    except FileNotFoundError:
        raise RuntimeError("perl 命令不可用，请确认已安装 perl")


def generate_output_path(input_file: str, svg_dir: str) -> str:
    """根据输入文件名自动生成输出 SVG 路径。

    规则：perf_YYYYMMDD_HHMMSS.data -> flame_YYYYMMDD_HHMMSS.svg

    Args:
        input_file: 输入 perf.data 文件路径
        svg_dir: SVG 输出目录

    Returns:
        输出 SVG 文件的完整路径
    """
    basename = os.path.basename(input_file)
    # 替换前缀 perf_ -> flame_，后缀 .data -> .svg
    if basename.startswith(FILENAME_PATTERN) and basename.endswith(".data"):
        svg_basename = "flame_" + basename[len(FILENAME_PATTERN):-len(".data")] + ".svg"
    else:
        # 非标准命名时，简单替换后缀
        name, _ = os.path.splitext(basename)
        svg_basename = f"flame_{name}.svg"

    os.makedirs(svg_dir, exist_ok=True)
    return os.path.join(svg_dir, svg_basename)


def main():
    parser = argparse.ArgumentParser(
        description="一键生成 CPU 火焰图（SVG）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
    python flamegraph.py --input perf_20260619_030000.data
    python flamegraph.py --input perf_20260619_030000.data --output out.svg
    python flamegraph.py --input perf_20260619_030000.data --width 1600
        """,
    )

    parser.add_argument(
        "--input", "-i",
        required=True,
        type=str,
        help="输入的 perf.data 文件路径",
    )
    parser.add_argument(
        "--output", "-o",
        type=str,
        default=None,
        help="输出的 SVG 文件路径。不指定则自动生成到 /data/perf_svg/",
    )
    parser.add_argument(
        "--width", "-w",
        type=int,
        default=1200,
        help="SVG 火焰图宽度（像素），默认 1200",
    )
    parser.add_argument(
        "--title", "-t",
        type=str,
        default=None,
        help="火焰图标题，默认使用输入文件名",
    )
    parser.add_argument(
        "--flamegraph-dir",
        type=str,
        default=DEFAULT_FLAMEGRAPH_DIR,
        help=f"FlameGraph 工具链目录（默认: {DEFAULT_FLAMEGRAPH_DIR}）",
    )
    parser.add_argument(
        "--svg-dir",
        type=str,
        default=DEFAULT_SVG_DIR,
        help=f"SVG 输出目录，未指定 --output 时使用（默认: {DEFAULT_SVG_DIR}）",
    )

    args = parser.parse_args()

    input_file = args.input
    output_file = args.output
    width = args.width
    title = args.title

    # 自动生成输出路径
    if not output_file:
        output_file = generate_output_path(input_file, args.svg_dir)

    # 自动生成标题
    if not title:
        title = f"CPU Flame Graph: {os.path.basename(input_file)}"

    print("=" * 60)
    print("CPU 火焰图生成器")
    print("=" * 60)
    print(f"  输入文件:     {input_file}")
    print(f"  输出文件:     {output_file}")
    print(f"  SVG 宽度:     {width}px")
    print(f"  标题:         {title}")
    print("=" * 60)

    try:
        # Step 1: 确保 FlameGraph 工具链可用
        print("\n[1/3] 检查 FlameGraph 工具链...")
        stackcollapse_script, flamegraph_script = ensure_flamegraph_tools(
            args.flamegraph_dir
        )
        print(f"  stackcollapse: {stackcollapse_script}")
        print(f"  flamegraph:    {flamegraph_script}")

        # Step 2: perf script 转换
        print(f"\n[2/3] 执行 perf script（解析 {input_file}）...")
        perf_output = run_perf_script(input_file)
        line_count = perf_output.count("\n")
        print(f"  perf script 完成，输出 {line_count} 行")

        # Step 3: stackcollapse 折叠调用栈
        print(f"\n[3/3] 生成火焰图...")
        collapsed = run_stackcollapse(stackcollapse_script, perf_output)
        collapsed_lines = collapsed.count("\n")
        print(f"  stackcollapse 完成，输出 {collapsed_lines} 行折叠调用栈")

        # Step 4: flamegraph 生成 SVG
        svg_content = run_flamegraph(flamegraph_script, collapsed, width, title)

        # Step 5: 写入 SVG 文件
        os.makedirs(os.path.dirname(output_file) or ".", exist_ok=True)
        with open(output_file, "w", encoding="utf-8") as f:
            f.write(svg_content)

        svg_size = os.path.getsize(output_file)
        print(f"  flamegraph 完成")
        print(f"\n{'=' * 60}")
        print(f"[OK] 火焰图已生成: {output_file}")
        print(f"     文件大小: {svg_size:,} bytes")
        print(f"{'=' * 60}")

        # 返回生成的 SVG 文件路径
        print(output_file)
        return 0

    except FileNotFoundError as e:
        print(f"\n[ERROR] 文件不存在: {e}", file=sys.stderr)
        return 1
    except RuntimeError as e:
        print(f"\n[ERROR] {e}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"\n[ERROR] 未知错误: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

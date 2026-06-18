# 火焰图生成与热点分析报告

## 一、测试环境

| 项目 | 信息 |
|------|------|
| CPU | 13th Gen Intel(R) Core(TM) i7-13620H (Raptor Lake) |
| vCPU | 2核 |
| 虚拟化 | VMware |
| 内核 | Linux 6.8.0-124-generic |

## 二、火焰图生成命令

### 2.1 矩阵乘法（计算密集型）
sudo perf record -F 99 -g -- stress-ng --cpu 1 --cpu-method matrixprod -t 30s
sudo perf script > matrixprod.script
./FlameGraph/stackcollapse-perf.pl matrixprod.script | ./FlameGraph/flamegraph.pl --title="矩阵乘法火焰图" > flamegraphs/matrixprod_flame.svg

### 2.2 随机访存（访存密集型）
sudo perf record -F 99 -g -- stress-ng --vm 1 --vm-bytes 512M --vm-method rand-set -t 30s
sudo perf script > randmem.script
./FlameGraph/stackcollapse-perf.pl randmem.script | ./FlameGraph/flamegraph.pl --title="随机访存火焰图" > flamegraphs/randmem_flame.svg

## 三、火焰图展示

### 3.1 矩阵乘法火焰图（计算密集型）
- 文件位置：flamegraphs/matrixprod_flame.svg
- 打开方式：用浏览器打开SVG文件
- 形态特征：扁平状，热点分散

### 3.2 随机访存火焰图（访存密集型）
- 文件位置：flamegraphs/randmem_flame.svg
- 打开方式：用浏览器打开SVG文件
- 形态特征：尖塔状，热点集中

## 四、火焰图对比分析

### 4.1 宽度分布差异

| 负载类型 | 火焰图形状 | 宽度分布 | 主要占用CPU的函数 |
|----------|-----------|----------|------------------|
| 矩阵乘法（计算密集） | 扁平 | 宽，热点分散 | stress-ng主函数、计算相关函数 |
| 随机访存（访存密集） | 尖塔 | 窄，热点集中 | exc_page_fault、handle_mm_fault、wp_page_copy |

### 4.2 热点函数对比

#### 矩阵乘法（计算密集型）
调用栈（从底部到顶部）：
[stress-ng] → [unknown] → stress-ng

热点集中：主要在 stress-ng 主函数和计算相关函数中，没有深度内核调用栈。

#### 随机访存（访存密集型）
调用栈（从底部到顶部）：
[stress-ng] → madvise → entry_SYSCALL_64 → asm_exc_page_fault → exc_page_fault → do_user_addr_fault → handle_mm_fault → handle_pte_fault → do_wp_page → wp_page_copy

热点集中：在缺页异常处理路径（exc_page_fault → handle_mm_fault → wp_page_copy）。

## 五、尖塔/扁平形态分析

### 5.1 为什么矩阵乘法是扁平状？
- 用户态计算为主，CPU时间主要在用户态执行浮点运算
- 很少触发缺页异常，数据工作集较小，能放入Cache
- 不进入内核，没有系统调用和缺页异常
- 多个函数调用路径，时间分散在多个用户态函数

结论：计算密集型负载的CPU时间分布在多个用户态函数中，火焰图呈现扁平状。

### 5.2 为什么随机访存是尖塔状？
- 频繁缺页异常，随机地址访问导致大量Page Fault
- 深度内核调用栈（exc_page_fault → handle_mm_fault → wp_page_copy）
- 热点高度集中，所有时间都花在同一条内核路径上
- 用户态时间短，大部分时间在处理缺页异常

结论：访存密集型负载的CPU时间集中在缺页异常处理路径上，火焰图呈现尖塔状。

## 六、内核态函数分析

### 6.1 出现的内核函数

| 内核函数 | 所在层级 | 功能说明 |
|----------|----------|----------|
| entry_SYSCALL_64 | 系统调用入口 | 用户态→内核态切换 |
| asm_exc_page_fault | 缺页异常入口 | 汇编级异常处理 |
| exc_page_fault | 缺页异常处理 | 缺页异常核心处理 |
| do_user_addr_fault | 地址检查 | 验证用户地址合法性 |
| handle_mm_fault | 缺页处理 | 处理内存缺页 |
| handle_pte_fault | 页表处理 | 遍历页表层级 |
| do_wp_page | 写时复制 | 处理写时复制页面 |
| wp_page_copy | 页面复制 | 复制物理页面（4KB） |

### 6.2 为什么会出现这些内核函数？
随机访存负载每次访问随机地址，可能导致：
1. 地址未映射 → 触发缺页异常
2. 页表不存在 → handle_mm_fault 分配物理页
3. 写时复制 → wp_page_copy 复制页面

### 6.3 对性能的影响
- 流水线停顿：缺页异常导致CPU流水线清空
- 上下文切换：用户态↔内核态切换消耗时间
- 内存分配：分配物理页需要时间
- 页面复制：复制4KB页面消耗内存带宽

量化影响（来自perf stat数据）：
- 用户态时间：14.92秒
- 内核态时间：15.16秒
- 内核态占比超过50%

## 七、总结

### 7.1 计算密集型 vs 访存密集型

| 对比维度 | 矩阵乘法（计算密集） | 随机访存（访存密集） |
|----------|---------------------|---------------------|
| 火焰图形状 | 扁平（宽） | 尖塔（高） |
| 热点集中度 | 分散 | 集中 |
| 主要函数 | 用户态计算函数 | 内核态缺页异常处理 |
| 瓶颈位置 | CPU执行单元 | 内存子系统 |

### 7.2 核心结论
1. 计算密集型负载：CPU时间主要花在用户态计算上，火焰图呈扁平状
2. 访存密集型负载：CPU时间集中在缺页异常处理路径，火焰图呈尖塔状
3. 火焰图形状反映瓶颈位置：尖塔→瓶颈明确，扁平→热点分散


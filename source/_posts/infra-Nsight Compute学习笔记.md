---
title: infra Nsight Compute学习笔记
categories: [学习笔记, 大模型算法]
tags: [CUDA, Nsight Compute, AI Infra]
---

这篇主要用来记录Nsight Compute的学习

# 测试背景

我主要使用的是矩阵乘法这个cuda kernel的不同优化版本来进行测试

```cpp
__global__ void mysgemm_v1(int M,//A(M x K)   B(K x N)  C(M x N)
						   int N,
						   int K,
						   float alpha,//放缩系数
						   float *A,
                           float* B,
                           float beta,//放缩系数
                           float *C)
```


不同版本kernel核函数对比如下：
- v1 **朴素实现**
	- 每个thread，负责C的一个元素
- v2 **共享内存优化**
	- 一个block，负责一个C_sub（搬运A_sub, B_sub 到 该block的shared_mem）
	- 一个thread负责C_sub里面的一个元素
	- 共享内存保存A_tile, B_tile
	- 寄存器保存每个A_tile，B_tile的计算结果
- v3 **thread_tile优化**
	- 基于v2
	- 一个thread负责C_sub里多个元素 = C_tile
	- 共享内存保存A_tile, B_tile
	- 寄存器保存每个A_tile，B_tile的计算结果
- v4 **向量预取指令**
	- 基于v3
	- 写共享内存As直接写**转置**，**读共享内存**时，优化**读取的效率**
- v5 **双缓冲+指令流水线重叠优化**
- v6 **warp tiling优化**

benchmard的测试条件为：
- M=2048
- K=2048
- N=2048

测试结果为
![366](images/Pasted%20image%2020260702192335.png)



# Nsight compute报告分析(以v1朴素实现的分析结果为例)

## 基本概念
> 吞吐量：单位时间内统计数量：
> **计算吞吐量** compute throughput: **单位时间内完成多少次计算**
> 	SM 所有运算单元（FMA/ALU/FP64/Tensor 等）**完成的运算操作总次数**
> **内存吞吐量** memory throughput: **单位时间传输的数据字节总量**


关于各种计算硬件单元，GPU里面有很多负责计算单元：
- **LSU** 加载 / 存储访存单元
- **FMA** 浮点数乘加单元
- **ALU** 整数运算单元

**每个硬件单元，都有自己独立的指令流水线**，每条流水线只处理对应类型指令
![332](images/Pasted%20image%2020260702195620.png)


----

##  GPU Speed Of Light Throughput
GPU 理论峰值吞吐量分析面板

本面板整体**展示 GPU 计算单元**与显存资源的吞吐量概况。
每项硬件单元指标会输出**当前实际吞吐量**相对理论峰值的利用率百分比

![](images/Pasted%20image%2020260702195840.png)![319](images/Pasted%20image%2020260702195857.png)![365](images/Pasted%20image%2020260702195909.png)

可以看到SM的计算单元指令吞吐量占满了，
显存访问吞吐量也占满了，其中主要是一级缓存在疯狂使用。

> **计算吞吐量**只统计 FMA/ALU 等运算操作，和 LSU 访存无关
>
>这里 98.29% 代表：**只要 SM 处于活跃、没有阻塞等待的周期里，运算单元几乎跑满了理论算力上限**。




![](images/Pasted%20image%2020260702200024.png)1. 高吞吐量提示（High Throughput）

当前内核程序**占用设备 80% 以上的计算或显存峰值性能** （<mark style="background:#fff88f">计算能力压榨的好像还不错</mark>）。若需进一步提升性能，建议将计算负载从当前高占用硬件单元迁移至其他模块。

可先前往「计算负载分析」板块分析程序负载特征。




![](images/Pasted%20image%2020260702200118.png)2. 屋顶线分析提示（Roofline Analysis）

本 GPU 设备单精度浮点（FP32）与双精度浮点（FP64）理论峰值性能比值为 64:1。

当前内核程序**仅达到设备单精度峰值性能的 6%**，双精度峰值性能利用率为 0%。
说明<mark style="background:#ff4d4f">计算能力仅到达峰值的6%</mark>， 差的很多


## Compute Workload Analysis
计算负载分析
本模块**对流式多处理器（SM）的计算资源**进行精细化分析，包含实际每周期执行指令数（IPC）与各类流水线的**硬件利用率**。流水线利用率过高时，会成为整体性能瓶颈
![](images/Pasted%20image%2020260702200321.png)
![320](images/Pasted%20image%2020260702200406.png)![285](images/Pasted%20image%2020260702200417.png)





![](images/Pasted%20image%2020260702200435.png)⚠️ 硬件利用率偏低
所有<mark style="background:#ff4d4f">计算流水线均未充分利用</mark>。出现该现象有两种可能性：当前 GPU 内核计算量过小；或是调度器未生成足够多的线程束（warp）。




![534](images/Pasted%20image%2020260702200509.png)

流水线利用率（占 SM 活跃周期百分比）
![319](images/Pasted%20image%2020260702200541.png)


这个是反应的计算指令的类别占比，可以看出我们程序主要是进行什么计算，这里可以看出，主要是FMA计算。
![497](images/Pasted%20image%2020260702200647.png)






![](images/Pasted%20image%2020260702200735.png)流水线利用率（占硬件峰值可执行指令总量百分比）

这个主要反应的是，一段绝对时间内，SM主要在进行什么指令，这里可以看出，大部分实际都是LSU，也就是访存

所有线程执行流程都被内存读写指令阻塞，**硬件绝大多数周期用于加载、存储数据**，没有空余周期执行浮点 / 整数计算。


**所以，总结下来：V1 的 matmul的朴素实现，是一个**

**访存密集型**：海量全局内存读写操作；
**仅基础单精度浮点 + 少量整数运算**，无高精度、AI 张量、纹理采样、复杂分支逻辑；


## 总结

> **计算吞吐量** 是看100个时间点里面，最忙的子管道（指令）工作了多少时间
>
>这里 98.29% 代表：**只要 SM 处于活跃、没有阻塞等待的周期里，运算单元几乎跑满了理论算力上限**。我们可以查看breakdown细则，发现，最忙的是LSU指令。
>![362](images/Pasted%20image%2020260702202650.png)





>结合前面流水线图表：**活跃周期内 FMA 流水线占比 22%、ALU 占 7%**，在仅有的少量能干活的时间里，算力硬件被充分利用。这里的占比，是指的FMA在他的所有时间内，只工作了22个时间
>![489](images/Pasted%20image%2020260702202800.png)



所以现在看这个SM的峰值利用率，可以看到在SM的活跃时期100个时间，LSU一直都在跑，
![](images/Pasted%20image%2020260702203833.png)
![](images/Pasted%20image%2020260702202946.png)

![](images/Pasted%20image%2020260702203825.png)
![620](images/Pasted%20image%2020260702203846.png)





![556](images/Pasted%20image%2020260702203913.png)
![527](images/Pasted%20image%2020260702203932.png)


## Memory Workload Analysis
![](images/Pasted%20image%2020260702204009.png)

这里就是分析GPU的显存资源，
- **内存吞吐量** 20.41 Gb/s <mark style="background:#ff4d4f">低</mark>
	- ![319](images/Pasted%20image%2020260702204525.png)
- **L1缓存命中率** 94.96% <mark style="background:#ff4d4f">高</mark>
	-  ![279](images/Pasted%20image%2020260702204551.png)
- L2缓存命中率 97.73% <mark style="background:#ff4d4f">高</mark>
	- ![233](images/Pasted%20image%2020260702204649.png)
- L2压缩成功率 0%
	- ![352](images/Pasted%20image%2020260702210901.png)
- 内存繁忙率 49%  **整体 memory 系统忙碌程度**
- 最大带宽占满率 98.29% <mark style="background:#ff4d4f">极个别管线最忙</mark>  最忙 memory 子资源的带宽利用程度
- 内存管道繁忙率 98.29%  **memory 指令管线忙碌程度**
	- ![322](images/Pasted%20image%2020260702204727.png)
	- ![452](images/Pasted%20image%2020260702204802.png)
- L2压缩率 0%
	- 
	- ![296](images/Pasted%20image%2020260702210929.png)





![](images/Pasted%20image%2020260702205034.png)

<mark style="background:#ff4d4f">黄色警告提示：L2 Load Access Pattern</mark>
从 **L1 纹理缓存向 L2 缓存发起的读取访存模式未达到最优**。

L1 纹理缓存向 L2 发起一次请求的最小粒度为一条 128 字节缓存行，一条缓存行包含 4 段连续 32 字节扇区。

但当前内核每次读取缓存行时，平均仅访问 4 个扇区中的 1.6 个，存在大量无效缓存行加载开销。

前往「源码计数器」板块查看**未合并离散读取**相关指标，**优化思路：尽可能减少单次内存请求需要加载的缓存行数量**。
![](images/Pasted%20image%2020260702205858.png)






接下来是分析
![688](images/Pasted%20image%2020260702211116.png)
![](images/Pasted%20image%2020260702211129.png)

这个 **Memory Chart** 是把刚才表格里的 memory workload 画成一张“数据流图”

> 你的 v1 naive SGEMM **几乎只使用 global memory 路径**，
> **没有 shared memory**；
> 
> 大量 global load/store 请求进入 L1/TEX，L1/L2 命中率很高，真正到 DRAM 的数据不多，但 global→L1TEX 以及 L1TEX→L2 的请求模式存在 warning。



![249](images/Pasted%20image%2020260702211420.png)![178](images/Pasted%20image%2020260702212054.png)![257](images/Pasted%20image%2020260702212119.png)








### 总结
所以，根据以上分析，可以看出几个问题
- <mark style="background:#ff4d4f">显存带宽低</mark>，说明显存带宽**不是瓶颈**
- L2->L1的访存请求粒度利用不充分
	- 每次访存请求没有充分利用完整 cache line，**访问的L2的cache line的利用率不够**。




## scheduler statistics
![](images/Pasted%20image%2020260702212810.png)

warp 调度器有没有足够多的 warp 可以发射指令。

SM 里的 warp scheduler 每个周期有没有活干？能不能连续发指令？

```
GPU Maximum Warps Per Scheduler       = 12   //硬件上限，每个 warp scheduler 理论最多能管理 12 个 warp。
Theoretical Warps Per Scheduler       = 8    //根据你的 kernel 配置算出来的理论 occupancy
									//一个 SM 通常有 4 个 warp scheduler，所以平均到每个 scheduler
									
									
Active Warps Per Scheduler            = 7.93
//每个 scheduler 平均有 7.93 个 active warp。它非常接近 theoretical 的 8，说明你的 kernel 基本达到了由 launch config 限制下的理论 occupancy。


Eligible Warps Per Scheduler          = 1.10  //每个调度器的就绪 warp，当前已经准备好，可以发出下一条指令
//大部分 warp 虽然在 SM 上，但都卡住了，说明大部分的warp都在阻塞中，等待访存返回


Issued Warp Per Scheduler             = 0.27 //每个 scheduler 每个 cycle 平均真正发出了多少个 warp 指令
//理想值 ≈ 1.0， 这说明 issue slot 利用率很低，调度器经常空转。

No Eligible                           = 72.94% 
// 有 72.94% 的周期，scheduler 找不到任何一个可以发指令的 warp。


One or More Eligible                  = 27.06%
```


![](images/Pasted%20image%2020260702213633.png)



## Warp state statistics
warp 在两个连续指令之间，到底把时间花在了哪里

前面的 **Scheduler Statistics** 告诉你：“调度器经常发不出指令”。  
这个 **Warp State Statistics** 进一步告诉你：“为什么 warp 发不出指令”


```
Warp Cycles Per Issued Instruction = 29.31  //平均每个 warp 发出一条指令，要隔大约 29.31 个 cycle。
//理想情况下，warp 应该比较频繁地发指令。你这里 29.31 cycle 才发一条，说明 warp 大部分时间都在 stall。
//对应：No Eligible = 72.94%


Warp Cycles Per Executed Instruction = 29.31   



Avg. Active Threads Per Warp = 32   //每个 warp 基本都是 32 个线程全活跃
//你这个 kernel 不是因为分支发散导致性能差。




Avg. Not Predicated Off Threads/Warp = 31.98  //绝大多数线程没有被谓词屏蔽，基本都在执行有效指令。
```

![](images/Pasted%20image%2020260702214309.png)
每个 warp **平均有 20 个周期卡住**，是因为 local/global **memory 指令要进入 L1TEX/LSU 相关队列**，但是这个**队列满了**，新的访存指令发不进去。

![331](images/Pasted%20image%2020260702214404.png)

warp的其他几个项：
- Stall Not Selected
	- 这个 warp 已经 ready 了，但是调度器这一拍没有选它。
- Stall Wait
	- ![246](images/Pasted%20image%2020260702214506.png)
- Stall Long Scoreboard
	- warp 在等一个**较长延迟的数据依赖**，常见是 global memory / L2 / DRAM load 的返回。
- Stall Dispatch Stall
	- 这个和指令分发/执行资源有关，表示 warp 虽然有指令，但由于 dispatch 相关限制没能顺利发出去
- Selected
	- warp 被 scheduler 选中并成功发出指令的周期。




## Launch Statistics
kernel 是怎么启动的，以及这个启动配置会消耗多少 GPU 资源。

```
Grid Size                         = 4096
Block Size                        = 1024
Threads                           = 4,194,304
Registers Per Thread              = 40
//一个寄存器 4字节， 每个thread占用40*4 = 160字节的寄存器资源

//共享内存
Static Shared Memory Per Block    = 0
Dynamic Shared Memory Per Block   = 0

//这个不是我们主动申请的共享内存
//CUDA driver / runtime / profiling / kernel 启动环境可能额外占用的一点 shared memory 资源。
Driver Shared Memory Per Block    = 1.02 KB

//表示当前 shared memory 配置/分配粒度相关的容量显示
Shared Memory Configuration Size  = 8.19 KB


//这个表示你没有显式设置 L1/shared memory 偏好。
Function Cache Configuration      = CachePreferNone


//所有 block 分配到 SM 上执行时，大约要分 32 波跑完。
Waves Per SM                      = 32
```
![331](images/Pasted%20image%2020260702215523.png)

<mark style="background:#fff88f">如果扑不满会怎么样</mark>，我在编写kernel的时候，怎么会知道GPU的SM数量，每个SM的寄存器大小呢？

![457](images/Pasted%20image%2020260702215655.png)
![523](images/Pasted%20image%2020260702215722.png)





![](images/Pasted%20image%2020260702215800.png)
![](images/Pasted%20image%2020260702215808.png)


### <mark style="background:#fff88f">**写 kernel 时怎么知道 SM 数量**？</mark>

最标准方法是用 CUDA Runtime API 查询。

![494](images/Pasted%20image%2020260702215903.png)![158](images/Pasted%20image%2020260702215914.png)


### 怎么知道自己的 kernel 每个线程用了多少寄存器

1. Nsight Compute
2. ![275](images/Pasted%20image%2020260702220018.png)
3. ![475](images/Pasted%20image%2020260702220032.png)





### 怎么知道一个 SM 能同时放几个 block？
![332](images/Pasted%20image%2020260702220115.png)

![324](images/Pasted%20image%2020260702220157.png)

这个函数会帮你根据 **kernel 的寄存器**、**shared memory**、**block size** 自动算出理论 **occupancy**。


### 实战中写kernel的流程

![](images/Pasted%20image%2020260702220238.png)









## Occupancy
一个 SM 上到底同时驻留了多少 warp，占硬件最大可驻留 warp 数的比例

![314](images/Pasted%20image%2020260702220450.png)



![427](images/Pasted%20image%2020260702215234.png)





```

//一个 SM 最大 active warps 大约是48 warps / SM 在4090上
Theoretical Occupancy              = 66.67%
Theoretical Active Warps per SM    = 32
Achieved Occupancy                 = 66.01%
Achieved Active Warps per SM       = 31.68

Block Limit Registers              = 1
Block Limit Shared Mem             = 8
Block Limit Warps                  = 1
Block Limit SM                     = 24
```
![177](images/Pasted%20image%2020260702220659.png)![265](images/Pasted%20image%2020260702220715.png)![363](images/Pasted%20image%2020260702220730.png)



### 总结
![529](images/Pasted%20image%2020260702220747.png)

![291](images/Pasted%20image%2020260702220821.png)











## Source Counters
把前面看到的 **stall、分支、指令数量** 对应回源码行。

![](images/Pasted%20image%2020260702221056.png)

![228](images/Pasted%20image%2020260702221143.png)![259](images/Pasted%20image%2020260702221114.png)![274](images/Pasted%20image%2020260702221128.png)






![355](images/Pasted%20image%2020260702221159.png)![323](images/Pasted%20image%2020260702221213.png)





# 计算密集型 - 显存密集型 / 计算瓶颈 - 显存瓶颈
![691](images/Pasted%20image%2020260702221906.png)


**计算密集型**
每搬 1 byte 数据，可以做很多次计算。

核心指标：
	**算术强度** = 浮点运算**次数** / 访存**字节数**

![534](images/Pasted%20image%2020260702222043.png)


**显存密集型**：
每搬 1 byte 数据，只做很少计算
![454](images/Pasted%20image%2020260702222125.png)




<mark style="background:#ff4d4f">计算瓶颈</mark>
kernel 的**速度主要受计算单元限制**，比如 FMA / Tensor Core / SFU 等计算管线已经很忙，**继续优化访存意义不大**，应该优化计算组织。

![568](images/Pasted%20image%2020260702222231.png)




<mark style="background:#ff4d4f">显存瓶颈</mark>
显存瓶颈有**两种**，要分清

![453](images/Pasted%20image%2020260702222355.png)



![484](images/Pasted%20image%2020260702222441.png)


## 如何准确判断
![549](images/Pasted%20image%2020260702222648.png)



![235](images/Pasted%20image%2020260702222804.png)![206](images/Pasted%20image%2020260702222819.png)



![456](images/Pasted%20image%2020260702222902.png)




![](images/Pasted%20image%2020260702222944.png)




```
计算密集型算子：
    特点：FLOPs/Byte 高，每读入一点数据，可以做很多计算。
    目标：让 FMA/Tensor Core 尽量忙。
    优化：
        1. shared memory tiling，提高 block 内复用
        2. register blocking，提高 thread 内复用
        3. 减少 global load
        4. 合理调度，让计算和访存重叠
        5. 提高 FMA/Tensor Core 利用率

显存密集型算子：
    特点：FLOPs/Byte 低，每搬很多数据，只做少量计算。
    目标：让显存/L2/L1 访问尽量高效。
    优化：
        1. coalesced access
        2. vectorized load/store
        3. 减少无效访存
        4. 提高 cache line / sector 利用率
        5. 尽量提高实际内存带宽
```

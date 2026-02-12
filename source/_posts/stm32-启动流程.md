---
title: stm32 启动流程
date: 2025-12-24 23:14:40
categories: [学习笔记, 嵌入式, MCU] 
tags: [嵌入式, mcu, stm32]
---
- [STM32f1 启动流程分析](#stm32f1-启动流程分析)
  - [1. STM32F1xx 芯片架构](#1-stm32f1xx-芯片架构)
  - [2. 编译文件类型](#2-编译文件类型)
  - [启动模式](#启动模式)
  - [启动文件startup.s](#启动文件startups)
  - [上电启动流程](#上电启动流程)
  - [程序的结构，运行域和加载域](#程序的结构运行域和加载域)

# STM32f1 启动流程分析
## 1. STM32F1xx 芯片架构
![alt text](../images/9.1.png)
关于启动流程，我们只需要关注
1. CM3内核
2. 内核通用寄存器R0-R15（尤其是SP寄存器和PC寄存器）（均为32位 4byte寄存器）
3. RAM（SRAM）
4. ROM（FLASH）
![alt text](../images/9.2.png)
## 2. 编译文件类型
![alt text](../images/9.3.png)
我们主要关注以下几种编译类型：
1. .o （由编译器编译.c/.s文件产生的可重定向文件）
2. .axf (由armlink链接器，将整个工程参与编译的.o链接成一个可执行文件，是不可重定向的，然后通过仿真器下载调试)
3. .hex （由axf转换而来的一个可执行对象文件，除了可执行代码，还有地址信息，知道烧写的地址）
4. .bin 正常gcc链接起来的可执行代码
5. .map文件（表示函数调用关系，地址关系等。方便调试）



## 启动模式
当内核上电后，CM3第一件事就是：

1. 读取0x0的4字节地址作为MSP（存放栈顶指针）
2. 读取0x4的4字节地址作为PC

事实上，这里的地址0x0, 0x04，可以被重映射到其他的地址空间，这种**重映射**，就是**启动模式的选择**


![alt text](../images/22.1.png)

实际的选择，可以通过`BOOT 引脚`根据`外部施加的电平`来决定芯片的`启动地址`

> 我们正常选择的就是第一种，内部flash启动，即把`0x0 -> 0x08000000`, `0x04 -> 0x08000004`

至于这个启动地址，存放的是什么指令，什么内容，这由`启动文件 starttup_stm32f103xe.s` 决定了存储什么内容

链接时，由分散加载文件(sct)决定这些内容的绝对地址，即分配到内部 FLASH 还是内部 SRAM。

## 启动文件startup.s
startup.S, 是上电后执行的第一个程序

主要工作如下：

1. 初始化栈指针 SP = _initial_sp
2. 初始化程序计数器指针 PC = Reset_Handler
3. 设置 堆 和 栈 的大小
4. 初始化中断向量表(填写IVT)
5. 配置外部 SRAM 作为数据存储器（可选）
6. 配置系统时钟，通过调用 SystemInit 函数（可选）
7. 调用 C 库中的 _main 函数初始化用户堆栈，最终调用 main 函数


## 上电启动流程
1. **上电**，CM3启动，（SP，PC未初始化）
2. （**初始化SP**）CM3硬件机制读取0x0800 0000开始的32位=4字节（0x da da da da）写入SP
3. （**初始化PC**）CM3硬件机制读取0x0800 0004开始的32位=4byte （0x da da da da）写入PC
4. （CM3 联合SP， PC， 按照正常的**取指令，译指令，执行指令**。）
   1. （取指令）CM3按照PC只是的下一条指令的地址，用总线在flash中取出指令（0x da da da da）
   2. （译指令）CM3翻译这4byte的指令为自己的ARM/THUMB指令 按照地址最后是否是0/1来区分arm/thumb指令集
   3. （执行指令）执行指令，完毕后更新PC指向下一条指令（+2/+4）。
5. CM3跳转**RESET_HANDLER**, 执行初始化
   1. CM3执行初始化内部的SystemInit函数，**初始化时钟**，执行完毕跳转回来。（函数名即函数段的入口地址）
   2. CM3执行__main，**初始化用户堆栈**（因为我们没有用microlib，所以是标准的编译器，所以需要告知c语言的堆栈的起始地址和大小）和C语言环境，完成后不再回来，进入C的世界。


startup.S开头程序示例：
```c

Stack_Size      EQU     0x00000400

                AREA    STACK, NOINIT, READWRITE, ALIGN=3
Stack_Mem       SPACE   Stack_Size
__initial_sp
                                                  
; <h> Heap Configuration
;   <o>  Heap Size (in Bytes) <0x0-0xFFFFFFFF:8>
; </h>

Heap_Size       EQU     0x00000200

                AREA    HEAP, NOINIT, READWRITE, ALIGN=3
__heap_base
Heap_Mem        SPACE   Heap_Size
__heap_limit

                PRESERVE8
                THUMB


; Vector Table Mapped to Address 0 at Reset
                AREA    RESET, DATA, READONLY
                EXPORT  __Vectors
                EXPORT  __Vectors_End
                EXPORT  __Vectors_Size

__Vectors       DCD     __initial_sp               ; Top of Stack
                DCD     Reset_Handler              ; Reset Handler
                DCD     NMI_Handler                ; NMI Handler
                DCD     HardFault_Handler          ; Hard Fault Handler
                DCD     MemManage_Handler          ; MPU Fault Handler
                DCD     BusFault_Handler           ; Bus Fault Handler
```

开头的分配，栈，堆，只是分配了内存空间大小，和指明指针的相对位置。并没有说明绝对物理地址是哪里。

当你编译工程时，链接器会读取一个配置文件（在 Keil 中通常是 `Project_Name.sct`）。这个文件描述了芯片的内存布局。(这个是真正的编译工具链里面的链接脚本，类似lds)

> 在startup.S中分配栈大小和指明栈指针的相对位置，然后在编译过程中的`链接脚本`中，指定实际这些地址的位置

> 栈空间的大小，CM3自己也意识不到，仅仅只是程序这么分配在map中。

> 栈从高往低生长，堆从低到高生长
   
## 程序的结构，运行域和加载域
map 文件是你的程序的镜像内存分布图：

正常程序编译好后，放置在加载域（存储的地方，ROM）里面

```c
//正常程序在加载域中的结构

.bss      //RW   （RAM）（初值为0）
.data     //RW   (初值在ROM，读写在RAM)（有初值，且不为 0）
.rodata   //RO   (ROM)
.text     //RO   (ROM)
```

>Section：描述映像文件的代码或数据块，我们简称程序段



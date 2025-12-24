---
title: stm32 启动流程
date: 2025-12-24 23:14:40
categories: [学习笔记, 嵌入式, MCU] 
tags: [嵌入式, mcu, stm32]
---
- [STM32f1 启动流程分析](#stm32f1-启动流程分析)
  - [1. STM32F1xx 芯片架构](#1-stm32f1xx-芯片架构)
  - [2. 编译文件类型](#2-编译文件类型)
  - [3. 启动文件startup.s](#3-启动文件startups)
  - [4. STM32F1xx固件烧录（存储器map）](#4-stm32f1xx固件烧录存储器map)
  - [5. 上电启动流程](#5-上电启动流程)
  - [6. map文件解析](#6-map文件解析)
  - [7. 汇编代码中的各种段，程序执行的加载域运行域](#7-汇编代码中的各种段程序执行的加载域运行域)

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
## 3. 启动文件startup.s
STM32 上电复位后，**CM3 内核的执行起点由中断向量表（IVT） 决定**，而**startup.s的核心作用就是定义中断向量表**，并将复位后首先执行的代码（Reset_Handler）放入向量表的指定位置。

这个文件的作用就是被编译器编译，然后烧写到flash的开头，是的CM3内核一开始知道初始化的东西是什么。可以理解为IVT的描述，最终，编译器会把startup.s编译成IVT。

## 4. STM32F1xx固件烧录（存储器map）
最终烧录的是一个镜像文件，全部烧写到FLASH中，我们在STlink中指定了起始的烧录地址为0x0800 0000.

**以前的内核复位后的操作**
在以前的ARM7/ARM9 内核控制器的复位后， 内核会直接默认从绝对地址0x0000 0000开始取第一条指令执行复位中断。（即固定了PC初始=0x0000 0000）

**CM3内核复位操作**
依赖boot方式，支持起始执行地址的重定位

CM3有三种启动方式：
1. flash启动
    CM3起始地址为0x0800 0000
2. SRAM启动
    CM3起始地址为0x2000 0000
3. Bootloader启动
    CM3起始地址为内置BootLoader区
## 5. 上电启动流程
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
## 6. map文件解析
1. 程序段交叉引用关系（Section Cross References）
    `main.o(i.main) refers to sys.o(i.sys_stm32_clock_init) for sys_stm32_clock_init 表示：main.c
文件中的 main 函数，调用了 sys.c 中的 sys_stm32_clock_init 函数。其中：i.main 表示 main
函数的入口地址`
2. 删除映像未使用的程序段（Removing Unused input sections from the image）
    `216 unused section(s) (total 15556bytes) removed from the
image. 表示总共移除了 216 个程序段（函数/数据），大小为 15556 字节。即给我们的 MCU
节省了 15556 字节的程序空间。`
3. 映像符号表（Image Symbol Table）
`本地符号（Local Symbols）记录了用 static 声明的全局变量地址和大小，c 文件中函数的
地址和用 static 声明的函数代码大小，汇编文件中的标号地址（作用域：限本文件）。
全局符号（Global Symbols）记录了全局变量的地址和大小，C 文件中函数的地址及其代
码大小，汇编文件中的标号地址（作用域：全工程）`
4. 映像内存分布图（Memory Map of the image）
`加载域（Load Region）和运行域（Execution Region）`
5. 映像组件大小（Image component sizes）
   `整个映像所有代码（.o）占用空间的汇总
信息`

## 7. 汇编代码中的各种段，程序执行的加载域运行域
**加载域**
`程序（代码、数据）被永久存储的区域，通常是Flash（或 ROM）。加载域中包含程序运行所需的所有原始数据`
1. 代码指令
2. 全局变量的初始值
   

**运行域**
程序实际执行时所在的区域，可以是Flash，也可以是RAM。

    代码的运行域：如果代码在 Flash 中直接执行（大部分情况），则运行域 = 加载域（均为 Flash）；如果代码需要在 RAM 中执行（如高速访问、自修改代码），则运行域是 RAM，加载域仍是 Flash（代码需从 Flash 拷贝到 RAM 后再执行）。

    数据的运行域：全局变量、栈、堆等需要读写的区域，运行域一定是 RAM（Flash 只读，无法修改），而它们的初始值（如.data段的初始值）的加载域是 Flash。


**程序中常见的段**
.text、.data、.bss
![alt text](../images/9.4.png)
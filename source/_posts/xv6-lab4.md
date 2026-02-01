---
title: xv6 lab4
date: 2026-01-31 12:39:32
categories: [学习笔记, 嵌入式, OS] 
tags: [嵌入式, OS, XV6]
---
# backtrace
## 理解trampoline -> trap -> trampoline
从用户到内核
我们可以把这个过程想象成一次“紧急避险”。

**1. 第一阶段：（uservec）(trampoline.S)**

这是Trap发生后的第一站。此时最尴尬的是：所有登记都存着用户的数据，你一个都不能动，不然用户数据就丢了。

`交换a0`：利用sscratch寄存器，先把用户的a0内存，换回一个指向的TRAPFRAME地址。

`保存现场`：现在有了a0指向的TRAPFRAME空间，赶紧把剩下的31个已注册的全存进去。

`加载内核环境`：从TRAPFRAME里加载内核栈、内核页表、usertrap的地址。(这些在第一次进程创建的时候，通过trap获取到的，之后都是fork复制)

`跳入C语言`：跳转到**usertrap**。

**2. 第二阶段：usertrap(trap.c)**


到了这里，我们已经进入了真正的内核世界。

`修改中断提示`：把`stvec`改成指向kernelvec。因为现在已经在内核了，如果再发生中断，处理方式和在用户状态是不一样的。

`分流处理`：

- 如果是ecall（系统调用），调syscall()。

- 如果是硬件中断，调节devintr()。

- 如果是非法操作，杀掉进程。

**3. 第三阶段：返回 (usertrapret -> userret)(trap.c->trampoline.S)**


原路返回，但在userret自定义里，会satp切回用户页表，并恢复所有用户注册，最后执行sret回到用户态。


``` c
用户态 (User Mode)           |    内核态 (Supervisor Mode)
-----------------------------------------------------------
[ 执行用户程序 ]              |
      |                      |
(发生 Trap: ecall/中断)        |
      |                      |
      V                      |
[ TRAMPOLINE (uservec) ] <---|--- 1. 硬件将 PC 指向这里 (stvec)
      |                      |    2. 还在使用【用户页表】
      | (保存寄存器到         |
      |  TRAPFRAME)          |
      |                      |
      | (切换 satp) -------->|--- 3. 切换到【内核页表】
      |                      |
      V                      |
[ usertrap (C code) ]        |--- 4. 处理业务逻辑
      |                      |
      V                      |
[ TRAMPOLINE (userret) ] <---|--- 5. 准备切回用户态
      |                      |
      | (切换 satp) -------->|--- 6. 切换回【用户页表】
      |                      |
      V                      |
(执行 sret) ---------------->|--- 7. 回到用户程序下一行
```

**重点理解：`Trapframe`到底是什么？**


`对用户状态（用户层）而言`：它是唯一的避风港，用于暂存那32个注册。

`对内核态（C语言层）而言`：它是一个结构体struct trapframe，内核可以随时读取或修改用户之前留下的寄存器值（比如获取系统调用的参数）。

`Trampoline`：代码中转站。在两个页表里的地址完全一样，保证切换页表时代码不会跑飞。

`Trapframe`：数据中转站。保存了用户的注册，也保存了内核需要用于“接手”的参数（如内核栈指针）。


## 从TRAPFRAME里面写入内核Usertrap栈的一些地址是物理地址吗？什么时候写到trapframe中的？
不是，它们都是`内核页表的虚拟地址`。

`内核页表地址（kernel_satp）`：这是一个要写入`satp`注册的值，虽然satp最终指向物理内存，但在代码逻辑层面，我们把它当作内核地址空间的“根”。

`内核栈指针（kernel_sp）`：这是`内核栈`在`内核页表中`的虚拟地址。

`usertrap指针`：这是`usertrap函数(trap.c)`在内核页表中的虚拟地址。

为什么必须是虚拟地址？ 因为在 `uservec` 执行过程中，一旦你完成了 csrw satp, a1（切换页表）这一行指令，CPU 的 MMU 就会立即按照新页表（`内核页表`）来解析地址。`如果此时 sp 或跳转地址是物理地址`，而内核页表没做等值映射（Identity Mapping），程序就会立刻崩溃


### 关于什么时候创建的trapframe中的内核状态？
**1. 第一个进程 (initproc) 的“无中生有”**

init 进程不是被 fork 出来的，而是由内核手动“捏”出来的。

内核启动：在 `main.c` 中调用 `userinit()`。

手动搭建：userinit `调用 allocproc` 分配 `trapframe` 和 `kstack`。

伪造现场：内核手动把初始的用户指令（即 `initcode.S` 编译后的二进制）`加载到用户内存起始位置`。

设置“返程票”：

它手动设置 p->trapframe->epc = 0（这样返回用户态后从第 0 行开始执行）。

它手动设置 p->trapframe->sp = PGSIZE（用户栈顶）。

第一次“返回”：虽然它从来没去过用户态，但内核通过 scheduler 调度它，走 forkret -> `usertrapret`。

关键点：就在这里，执行了你之前搜到的那行代码，把 kernel_sp、kernel_satp 等信息填进了 trapframe。

着陆：执行 userret，跳入用户态执行 init。

此时，第一个进程的 trapframe 已经完美初始化了。

**2. 后续进程的“克隆”**

一旦有了第一个进程，剩下的确实如你所说，大多是通过 fork() 产生的。

fork() 的逻辑：
完全拷贝：fork 会调用 uvmcopy 拷贝父进程的物理内存，也会拷贝父进程的 trapframe 内容。

`子进程的微调`：

fork 会把子进程 trapframe 里的 a0 寄存器强制设为 0（这就是为什么 if(fork() == 0) 能判断出子进程）。

继承“路标”：因为父进程的 trapframe 里已经写好了正确的 kernel_sp、kernel_satp 等内核路标，子进程拷贝过去后，下次发生 Trap 时，子进程也能顺利找到内核的路。

**3. 修正一个小细节：kernel_sp 真的能完全拷贝吗？**

这里有一个非常细微但重要的点：每个进程的内核栈（kstack）是独立的。

虽然 fork 拷贝了父进程 trapframe 的大部分内容，但子进程必须拥有自己独立的内核栈指针。

在 fork() 调用 allocproc() 时，allocproc 会为子进程分配一个新的 kstack。

随后在 `usertrapret 返回用户态之前`，那行 `p->trapframe->kernel_sp = p->kstack + PGSIZE`; 会再次执行。

这意味着：`即使是从父进程拷贝过来的旧 kernel_sp，也会在返回用户态前的最后一刻，被修正为子进程自己的内核栈地址`。

**总结你的疑问**

- **第一个进程**：通过 userinit 手动创建，在第一次通过 usertrapret “返回”用户态时填满 trapframe。

- **后续进程**：通过 fork 拷贝。虽然拷贝了父进程的 trapframe，但每个进程在每次离开内核前，都会通过 usertrapret 重新刷新一遍 trapframe 里的内核信息，确保万无一失。

`stvec寄存器`: 告诉CPU，当异常或中断（Trap）发生时，该跳到哪行代码去执行。


## 页面错误异常的应用
可以利用页面错误异常+页表，来实现：
1. COW fork（写时复制）
   
   一开始父子进程共享一片物理内存，当开始写时，发生访问异常，进行复制，一般用在fork+exec处，因为父进程的内容是没什么用的。

2. 惰性sbrk
   
   不是一次性的直接拓展完成，而是随着时间推移，当访问到了再开辟。

3. demand paging

    由于应用程序可能很大并且从磁盘读取数据的成本很高，因此这种启动成本可能会引起用户的注意：当用户从 shell 启动大型应用程序时，用户可能需要很长时间才能看到响应。**为了缩短响应时间**，现代内核为用户地址空间创建页表，但将页面的 PTE 标记为无效。发生页面错误时，内核从磁盘读取页面内容并将其映射到用户地址空间。

4. paging to disk

    只将一部分用户页面存储在 RAM 中，并将其余部
分存储在磁盘上 paging area，不在 RAM 中的内存相对
应的 PTE 标记为无效



## 关于内核栈的结构

在 RISC-V 中，`栈帧的结构并不是由 C 语言的 struct 定义的`，而是由 编译器（`GCC`）的`调用约定`（Calling Convention） 决定的。

根据讲义和提示，RISC-V 的栈`向下增长`（从高地址往低地址），而 `s0` 寄存器（即`帧指针 fp`）指向`当前栈帧的顶部`（`高地址端`）。


内核栈中的最小单元是一个帧，里面的结构如下：
![alt text](../images/19.1.png)

当前帧指针fp指向的是每一帧的最高地址。
但是读取每一个内容还是从低地址到高地址来读取，

所以fp-8是`该帧的返回地址` 的起始低地址，表示`调用当前函数后的下一条指令`

fp-16就是`上一帧的最高地址`
``` c
地址偏移	        存储内容	                    说明
fp - 8	        返回地址 (Return Address)	指向调用当前函数后的下一条指令。
fp - 16	        前一个 fp (Previous Frame Pointer)	指向调用者（Caller）的栈帧起始位置。
<fp - 16	    局部变量/被保存的寄存器	    函数内部使用的其他数据。
```

> **那这个s0读出来的fp内核栈的栈帧指针，和sp指针有什么区别呢？**
>
> sp 是为了让程序跑下去，而 s0 是为了让程序能“回头”。 不管是 s0 还是 sp，在开启虚拟内存的 xv6 内核中，它们`指向的都是内核虚拟地址`。

虽然它们都指向内核栈，但分工完全不同
- `sp (栈指针)`
  
  动态变化： 它是“最前线”的指针。每当函数内部定义局部变量、压栈寄存器时，sp 就会不断地向下移动（向低地址增长）。

>用途： 它是 CPU 寻找当前栈顶的唯一依据。

- `s0 / fp (帧指针)`：
  
    静态快照： 当一个函数刚开始运行（函数序言阶段）时，它会将当前的 sp 记录在 s0 中。

> 用途： 在整个函数执行期间，`s0 的值保持不变。它就像是一个锚点`，无论 sp 怎么折腾，函数都可以通过 s0 加上固定的偏移量来找到函数的局部变量、返回地址和调用者的 fp。


**如何理解“当前帧（Current Frame）?**

当 Function A 调用 Function B 时：

- 栈上会开辟一块新的领地（Frame）。

- 这块领地的“大门”地址就存放在 s0 (fp) 里。

- 在这块领地内，`Function B `存放着它的局部变量。

- 由于 `s0 指向当前帧的“起点”（高地址端）`，而 xv6 的布局规定：

- s0 - 8 固定存放当前函数的返回地址 (ra)。

- s0 - 16 固定存放上一个函数的帧指针 (previous fp)。

这就形成了一条链表。backtrace 实验其实就是在遍历这个以 s0 为头节点的单向链表。

``` c
内核栈页面 (Kernel Stack Page)
+---------------------------+ <--- PGROUNDUP(fp) (栈底，起始地址)
|      ... 上一帧 ...        |
+---------------------------+
|  Saved Return Address     | <--- 当前 s0 - 8 (这就是你要打印的地址)
+---------------------------+
|  Saved Previous fp  ------+-----> 指向上一帧的 s0
+---------------------------+ <--- 当前 s0 (fp) 的位置
|      局部变量              |
|      ...                  |
|      临时数据              |
+---------------------------+ <--- 当前 sp (指向最底部的动态位置)
|                           |
+---------------------------+ <--- PGROUNDDOWN(fp) (栈顶边界，循环终止处)
```

>**为什么不用 sp 做 backtrace？** 
>
>因为 sp 是不固定的。编译器在不同的优化等级下，局部变量占用的空间可能不同，导致返回地址相对于 sp 的距离不固定。而返回地址相对于 s0 的偏移总是固定的（-8 和 -16）

## 实现
该backtrace，其实就是把内核栈的东西溯源，打印出来，上面已经分析了内核栈的结构，当在sys_sleep中测试完成后，即可合并到panic中，这样，当出现panic之前，cpu会把当前的内核栈的函数调用全部打印出来。这样就可以知道是什么原因导致内核死掉了。


```c
From 81a2d27242d2d285b7ac70d7b733297f6b161685 Mon Sep 17 00:00:00 2001
From: liangji-seu <15262272286@163.com>
Date: Sat, 31 Jan 2026 16:00:42 +0800
Subject: [PATCH 1/2] feat: support backtrace()

---
 kernel/defs.h    |  1 +
 kernel/printf.c  | 25 +++++++++++++++++++++++++
 kernel/riscv.h   |  9 +++++++++
 kernel/sysproc.c |  1 +
 4 files changed, 36 insertions(+)

diff --git a/kernel/defs.h b/kernel/defs.h
index 3564db4..9224b0f 100644
--- a/kernel/defs.h
+++ b/kernel/defs.h
@@ -80,6 +80,7 @@ int             pipewrite(struct pipe*, uint64, int);
 void            printf(char*, ...);
 void            panic(char*) __attribute__((noreturn));
 void            printfinit(void);
+void            backtrace(void);
 
 // proc.c
 int             cpuid(void);
diff --git a/kernel/printf.c b/kernel/printf.c
index e1347de..ec8d335 100644
--- a/kernel/printf.c
+++ b/kernel/printf.c
@@ -114,6 +114,30 @@ printf(char *fmt, ...)
     release(&pr.lock);
 }
 
+// seu liangji add
+void backtrace()
+{
+    //TODO: trace the function call on the stack above the point 
+    //at which the error occurred.
+    uint64 fp = r_fp();
+    uint64 kernel_stack_top = PGROUNDUP(fp);
+    uint64 kernel_stack_bottom = PGROUNDDOWN(fp);
+
+    printf("backtrace:\n");
+    while(fp >= kernel_stack_bottom && fp < kernel_stack_top)
+    {
+        // get the return address
+        uint64 ret_addr = *(uint64*)(fp - 8);
+
+        printf("%p\n", ret_addr);
+
+        // set fp = last stack frame point
+        fp = *(uint64*)(fp - 16);
+    }
+}
+
+
+
 void
 panic(char *s)
 {
@@ -122,6 +146,7 @@ panic(char *s)
   printf(s);
   printf("\n");
   panicked = 1; // freeze uart output from other CPUs
+  backtrace();
   for(;;)
     ;
 }
diff --git a/kernel/riscv.h b/kernel/riscv.h
index 1691faf..7de406b 100644
--- a/kernel/riscv.h
+++ b/kernel/riscv.h
@@ -364,3 +364,12 @@ sfence_vma()
 
 typedef uint64 pte_t;
 typedef uint64 *pagetable_t; // 512 PTEs
+
+// gcc will put fp->now function into s0 register
+static inline uint64
+r_fp()
+{
+  uint64 x;
+  asm volatile("mv %0, s0" : "=r" (x) );
+  return x;
+}
diff --git a/kernel/sysproc.c b/kernel/sysproc.c
index e8bcda9..5f0d204 100644
--- a/kernel/sysproc.c
+++ b/kernel/sysproc.c
@@ -57,6 +57,7 @@ sys_sleep(void)
 {
   int n;
   uint ticks0;
+  backtrace();
 
   if(argint(0, &n) < 0)
     return -1;
-- 
2.25.1


```




# alarm
**实验要求解析**：
按他的实验要求，就是要求用户进程先调用系统调用sigalarm，标记上该进程的tick阈值，以及用户进程中的回调函数。然后用户进程持续运行。

之后每当内核的计时器中断（1个tick一次中断，进入usertrap），对该进程的tick计数开始增加，当增加到tick阈值后，触发一次中断回调函数。

该**实验的核心**就在于，**如何在内核态的中断事件中，执行用户态的函数**。

> **Unix 信号机制（Signal）** 工作原理：
>
> `注册`：用户程序告诉内核“如果发生某事，请运行函数 X”。
>
>`触发`：内核在处理中断/异常时发现满足条件。
>
>`传递`：内核在返回用户态前，强行修改用户的 PC 指针和栈。
>
>`执行`：用户执行函数 X。
>
>`恢复`：执行完后通过系统调用回到原始状态。

所以要实现这个signal机制，需要先对xv6的整个用户态和内核态的切换做一个系统的理解

## 用户态内核态切换分析
下面总结以下，risc v xv6 从用户态-内核态-用户态的一个过程：

**1. cpu的核心控制状态寄存器（CSR）**
``` c
┌─────────────┬────────────────────────────────────────────┐
│   寄存器     │                    作用                    │
├─────────────┼────────────────────────────────────────────┤
│   stvec     │ Trap入口地址 (指向 uservec)                 │
│   sepc      │ 保存触发Trap时的用户PC                      │
│   scause    │ Trap原因 (syscall=8, 中断, 异常等)          │
│   sscratch  │ 中转站: 用户态时存trapframe地址             │
│   sstatus   │ 状态寄存器 (SPP位记录之前的特权级)           │
│   satp      │ 页表基址寄存器                              │
│   x0-x31,sp │ cpu的通用寄存器                              │
└─────────────┴────────────────────────────────────────────┘

```

**2. 完整流程图**
``` c
 用户态 (U-Mode)                        内核态 (S-Mode)
 ══════════════                        ═══════════════
       │
       │  用户程序执行 write() 等系统调用
       │
       ▼
  ┌─────────┐
  │  ecall  │  ←── 用户代码触发陷入
  └────┬────┘
       │
       │ ┌──────────────────────────────────┐
       │ │  ★ 硬件自动完成 (瞬间)            │
       │ │  1. sepc ← PC (保存用户PC)        │
       │ │  2. 切换到 S-Mode                 │
       │ │  3. PC ← stvec (跳转到uservec)    │
       │ │  4. scause ← 8 (syscall)         │
       │ └──────────────────────────────────┘
       │
       ▼
  ┌─────────────────────────────────────────────────────┐
  │              uservec (trampoline.S)                 │
  │  ─────────────────────────────────────────────────  │
  │  此时: S-Mode + 用户页表 + 用户寄存器                │
  │                                                     │
  │  1. //a0指向trapframe                                  │
  │     csrrw a0, sscratch, a0                          │
  │     (a0 ↔ sscratch, 现在a0指向trapframe)            │
  │                                                     │
  │  2. sd ra, 40(a0)   // 保存用户态所有通用寄存器，包括sp到trapframe  │
  │     sd sp, 48(a0)                                   │
  │     sd t0, 56(a0)                                   │
  │     ...                                             │
  │                                                     │
  │  3. ld sp, 8(a0)    // 切换内核态 栈指针                 │
  │     ld tp, 32(a0)   // 加载 hartid                   │
  │     ld t0, 16(a0)   // 加载 下一个跳转指令usertrap 地址到寄存器            │
  │     ld t1, 0(a0)    // 加载 内核页表 到寄存器                  │
  │                                                     │
  │  4. csrw satp, t1   // 切换到内核页表                 │
  │     sfence.vma      // 刷新 TLB                      │
  │                                                     │
  │  5. jr t0           // 跳转到 usertrap()             │
  └─────────────────────────────────────────────────────┘
       │
       ▼
  ┌─────────────────────────────────────────────────────┐
  │              usertrap() (trap.c)                    │
  │  ─────────────────────────────────────────────────  │
  │  此时: S-Mode + 内核页表 + 内核栈                    │
  │                                                     │
  │  1. 修改 stvec 指向 kernelvec (防止嵌套trap)        │
  │  2. 保存 sepc 到 p->trapframe->epc                  │
  │  3. 判断 scause:                                    │
  │     - syscall → syscall()                          │
  │     - 中断    → devintr()                          │
  │     - 异常    → kill process                       │
  │  4. 调用 usertrapret() 准备返回                     │
  └─────────────────────────────────────────────────────┘
       │
       ▼
  ┌─────────────────────────────────────────────────────┐
  │           usertrapret() (trap.c)                    │
  │  ─────────────────────────────────────────────────  │
  │  1. 关中断                                          │
  │  2. 设置 stvec 指回 uservec                         │
  │  3. 准备 trapframe:                                 │
  │     - kernel_satp, kernel_sp, usertrap地址          │
  │  4. 设置 sstatus (SPP=0, SPIE=1)                    │
  │  5. 设置 sepc = p->trapframe->epc                   │
  │  6. 计算用户页表 satp 值                             │
  │  7. 跳转到 userret (在trampoline中)                 │
  └─────────────────────────────────────────────────────┘
       │
       ▼
  ┌─────────────────────────────────────────────────────┐
  │              userret (trampoline.S)                 │
  │  ─────────────────────────────────────────────────  │
  │  参数: a0=trapframe地址, a1=用户satp                │
  │                                                     │
  │  1. csrw satp, a1   // 切换回用户页表                 │
  │     sfence.vma      // 刷新 TLB                      │
  │                                                     │
  │  2. ld ra, 40(a0)   // 从trapframe恢复用户态      │
  │     ld sp, 48(a0)                                   │
  │     ld t0, 56(a0)                                   │
  │     ...                                             │
  │                                                     │
  │  3. csrw sscratch, a0  // 把trapframe地址存回sscratch│
  │     ld a0, 112(a0)     // 恢复用户态的a0               │
  │                                                     │
  │  4. sret            // 返回用户态!                   │
  └─────────────────────────────────────────────────────┘
       │
       │ ┌──────────────────────────────────┐
       │ │  ★ sret 硬件自动完成             │
       │ │  1. PC ← sepc (恢复用户PC)       │
       │ │  2. 切换到 U-Mode (根据SPP)      │
       │ │  3. 开启中断 (根据SPIE)          │
       │ └──────────────────────────────────┘
       │
       ▼
  ┌─────────┐
  │ 用户代码 │  ←── ecall 的下一条指令继续执行
  └─────────┘

```

**3. sscratch的用法总结**
``` c
时间线 ─────────────────────────────────────────────────────────►

用户态运行时:
┌──────────┐     ┌───────────┐
│ sscratch │ ──► │ trapframe │  (存着trapframe地址，备用)
└──────────┘     └───────────┘
      │
      │  csrrw a0, sscratch, a0 (进入uservec时交换)
      ▼
内核态运行时:
┌──────────┐     
│ sscratch │ ──► 用户的 a0 值  (暂存用户a0)
└──────────┘     
┌──────────┐     ┌───────────┐
│    a0    │ ──► │ trapframe │  (现在用a0访问trapframe)
└──────────┘     └───────────┘
      │
      │  返回前再次交换
      ▼
用户态恢复:
┌──────────┐     ┌───────────┐
│ sscratch │ ──► │ trapframe │  (恢复原状，等待下次trap)
└──────────┘     └───────────┘

```

**4. 页表切换时机**
``` c
          用户页表                    内核页表
         ┌────────┐                  ┌────────┐
         │ 用户代码 │                  │ 内核代码 │
         │ 用户数据 │                  │ 内核数据 │
         │ 用户栈   │                  │ 内核栈   │
         ├────────┤                  ├────────┤
 相同 ──►│trampoline│◄── 映射到同一物理地址 ──►│trampoline│◄── 相同
         │ (顶部)   │                  │ (顶部)   │
         └────────┘                  └────────┘

为什么 trampoline 必须在两个页表中映射到相同虚拟地址？
因为切换 satp 的那一刻，PC 还在执行 trampoline 中的代码！
如果地址不同，切换后 PC 就会跳到错误的地方。

```

**5. trapframe结构布局**
``` c
struct trapframe {    // 偏移量
  uint64 kernel_satp;   //   0  内核页表
  uint64 kernel_sp;     //   8  内核栈指针
  uint64 kernel_trap;   //  16  usertrap() 地址
  uint64 epc;           //  24  用户 PC (来自sepc)
  uint64 kernel_hartid; //  32  CPU 核心号
  uint64 ra;            //  40  ─┐
  uint64 sp;            //  48   │
  uint64 gp;            //  56   │
  uint64 tp;            //  64   │
  uint64 t0-t6;         //  ...  ├─ 31个通用寄存器
  uint64 s0-s11;        //  ...  │
  uint64 a0-a7;         //  ...  │
  ...                   //      ─┘
};

```

## c语言变量在虚拟内存空间分布
**1. 进程虚拟地址空间布局**
```c
高地址
┌─────────────────────────────────────┐ 0xFFFFFFFF (32位) 或更高
│           内核空间                   │ ← 用户不可访问
├─────────────────────────────────────┤
│             栈 (Stack)              │ ← 向下增长 ↓
│         局部变量、函数参数            │
│                 ↓                   │
├─────────────────────────────────────┤
│                                     │
│           (未分配区域)               │
│                                     │
├─────────────────────────────────────┤
│                 ↑                   │
│             堆 (Heap)               │ ← 向上增长 ↑
│         malloc/new 分配              │
├─────────────────────────────────────┤
│             BSS 段                   │ ← 未初始化的全局/静态变量
│         (Block Started by Symbol)    │
├─────────────────────────────────────┤
│            Data 段                   │ ← 已初始化的全局/静态变量
│           (数据段)                   │
├─────────────────────────────────────┤
│           rodata 段                  │ ← 只读数据 (字符串常量等)
│          (只读数据段)                 │
├─────────────────────────────────────┤
│           Text 段                    │ ← 代码/指令
│           (代码段)                   │
└─────────────────────────────────────┘ 0x00000000
低地址

```

**2. 各变量存储位置**
``` c
┌────────────────────┬─────────────┬──────────────────────────────┐
│      变量类型       │   存储位置   │            示例              │
├────────────────────┼─────────────┼──────────────────────────────┤
│ 局部变量            │    栈       │ void f() { int x = 1; }      │
│ 函数参数            │    栈       │ void f(int a, int b)         │
│ 局部数组            │    栈       │ void f() { int arr[10]; }    │
├────────────────────┼─────────────┼──────────────────────────────┤
│ malloc/calloc/new  │    堆       │ int *p = malloc(100);        │
├────────────────────┼─────────────┼──────────────────────────────┤
│ 全局变量(已初始化)   │   Data段    │ int g = 100;                 │
│ 静态变量(已初始化)   │   Data段    │ static int s = 100;          │
├────────────────────┼─────────────┼──────────────────────────────┤
│ 全局变量(未初始化)   │   BSS段     │ int g;                       │
│ 静态变量(未初始化)   │   BSS段     │ static int s;                │
│ 初始化为0的全局/静态 │   BSS段     │ int g = 0; static int s = 0; │
├────────────────────┼─────────────┼──────────────────────────────┤
│ 字符串常量          │  rodata段   │ char *s = "hello";           │
│ const全局变量       │  rodata段   │ const int MAX = 100;         │
├────────────────────┼─────────────┼──────────────────────────────┤
│ 函数代码            │   Text段    │ void foo() { ... }           │
└────────────────────┴─────────────┴──────────────────────────────┘

//字符串的特殊情况
char *p = "hello";           char s[] = "hello";
                             
   栈                            栈
┌──────┐                     ┌──────────────┐
│  p   │──────┐              │ h e l l o \0 │  ← 数据直接在栈上
└──────┘      │              └──────────────┘
              │              
              ▼              
   rodata段                  
┌──────────────┐             
│ h e l l o \0 │  ← 只读！    
└──────────────┘             


```

**3. static变量的特点**
```c
Data段（或BSS段）里的值直接被修改。


static int count = 0;  // 程序启动时在 BSS段 分配

void f() {
    count = 5;  // 直接修改 BSS段 中那个固定地址的值
    count++;    // BSS段 中的值变为 6
}
```


## alarm解法

所以**关于如何在内核态执行用户态的回调函数**，`不能直接执行`，必须通过`重返用户态执行`，但是重返用户态，又只能重返陷入内核之前的trapframe，也就是继续执行`旧的用户态`。

所以**关键**就在于`sigreturn()`, 这个又是一个系统调用，

说明`如果切换回用户态执行回调函数后，又会执行系统调用陷入内核态`, 相当于截断了用户态的执行。



所以：**解决方案**就是：
  - 自己`新增一个中间的用户态`（trapframe）,备份旧的用户态,`一个用户态状态就是一个trapframe`
   
   也就是说，我们`如果有一个新的用户态，直接飞过去执行用户态回调函数，然后由sigreturn系统调用结束这个用户态`。**再次进入内核态**后，才恢复原来的用户态。
   
   
>这样就相当于可以`在原来用户态继续执行前，插入一个用户态的函数执行`。
   
>并且由于，该回调函数里面只涉及虚拟空间的**代码段**和**data段**，不涉及栈，所以两个用户态可以相互交换信息。

## 代码实现
``` c
From dd29a06e07bfa92c225fe4434579a2ba2ed1dee3 Mon Sep 17 00:00:00 2001
From: liangji-seu <15262272286@163.com>
Date: Sat, 31 Jan 2026 21:37:21 +0800
Subject: [PATCH] feat: support signal

---
From 642dcb9609338240accf1ff4a0493065414bb16e Mon Sep 17 00:00:00 2001
From: liangji-seu <15262272286@163.com>
Date: Sat, 31 Jan 2026 21:37:21 +0800
Subject: [PATCH] feat: support signal

---
 Makefile         |  1 +
 kernel/proc.c    |  6 ++++++
 kernel/proc.h    | 10 ++++++++++
 kernel/syscall.c |  4 ++++
 kernel/syscall.h |  2 ++
 kernel/sysproc.c | 30 ++++++++++++++++++++++++++++++
 kernel/trap.c    | 31 +++++++++++++++++++++++++++++++
 user/user.h      |  4 ++++
 user/usys.pl     |  2 ++
 9 files changed, 90 insertions(+)

diff --git a/Makefile b/Makefile
index 7a7e380..8de30a0 100644
--- a/Makefile
+++ b/Makefile
@@ -183,6 +183,7 @@ UPROGS=\
 	$U/_mkdir\
 	$U/_rm\
 	$U/_sh\
+	$U/_alarmtest\
 	$U/_stressfs\
 	$U/_usertests\
 	$U/_grind\
diff --git a/kernel/proc.c b/kernel/proc.c
index 22e7ce4..6c0300b 100644
--- a/kernel/proc.c
+++ b/kernel/proc.c
@@ -141,6 +141,12 @@ found:
   p->context.ra = (uint64)forkret;
   p->context.sp = p->kstack + PGSIZE;
 
+  // init ticks and alarm;
+  p->ticks_cnt = 0;
+  p->ticks_inv = 0;
+  p->func_cb = 0;
+  p->ticks_lock = 0;
+
   return p;
 }
 
diff --git a/kernel/proc.h b/kernel/proc.h
index f6ca8b7..4913318 100644
--- a/kernel/proc.h
+++ b/kernel/proc.h
@@ -47,6 +47,9 @@ struct trapframe {
   /*  16 */ uint64 kernel_trap;   // usertrap()
   /*  24 */ uint64 epc;           // saved user program counter
   /*  32 */ uint64 kernel_hartid; // saved kernel tp
+
+
+  // save common register
   /*  40 */ uint64 ra;
   /*  48 */ uint64 sp;
   /*  56 */ uint64 gp;
@@ -105,4 +108,11 @@ struct proc {
   struct file *ofile[NOFILE];  // Open files
   struct inode *cwd;           // Current directory
   char name[16];               // Process name (debugging)
+
+  int ticks_cnt;
+  int ticks_inv;
+  uint64 func_cb;
+  int ticks_lock;
+  struct trapframe *trapframe_signal_backup;
+
 };
diff --git a/kernel/syscall.c b/kernel/syscall.c
index c1b3670..a74be20 100644
--- a/kernel/syscall.c
+++ b/kernel/syscall.c
@@ -104,6 +104,8 @@ extern uint64 sys_unlink(void);
 extern uint64 sys_wait(void);
 extern uint64 sys_write(void);
 extern uint64 sys_uptime(void);
+extern uint64 sys_sigalarm(void);
+extern uint64 sys_sigreturn(void);
 
 static uint64 (*syscalls[])(void) = {
 [SYS_fork]    sys_fork,
@@ -127,6 +129,8 @@ static uint64 (*syscalls[])(void) = {
 [SYS_link]    sys_link,
 [SYS_mkdir]   sys_mkdir,
 [SYS_close]   sys_close,
+[SYS_sigalarm]   sys_sigalarm,
+[SYS_sigreturn]   sys_sigreturn,
 };
 
 void
diff --git a/kernel/syscall.h b/kernel/syscall.h
index bc5f356..7b88b81 100644
--- a/kernel/syscall.h
+++ b/kernel/syscall.h
@@ -20,3 +20,5 @@
 #define SYS_link   19
 #define SYS_mkdir  20
 #define SYS_close  21
+#define SYS_sigalarm  22
+#define SYS_sigreturn  23
diff --git a/kernel/sysproc.c b/kernel/sysproc.c
index 5f0d204..79bd1a2 100644
--- a/kernel/sysproc.c
+++ b/kernel/sysproc.c
@@ -96,3 +96,33 @@ sys_uptime(void)
   release(&tickslock);
   return xticks;
 }
+
+uint64 sys_sigalarm(void)
+{
+    struct proc* p = myproc();
+    int ticks_interval;
+    if(argint(0, &ticks_interval) < 0)
+    {
+        return -1;
+    }
+
+    uint64 function_callback;
+    if(argaddr(1, &function_callback) < 0)
+    {
+        return -1;
+    }
+
+    p->ticks_inv = ticks_interval;
+    p->func_cb = function_callback;
+    //printf("sys_sigalarm, set p->ticks_inv = %d, func_cb va = %p\n", p->ticks_inv, p->func_cb);
+    return 0;
+}
+uint64 sys_sigreturn(void)
+{
+    struct proc *p = myproc();
+    memmove(p->trapframe, p->trapframe_signal_backup, sizeof(struct trapframe));
+    p->ticks_lock = 0;
+    return 0;
+}
+
+
diff --git a/kernel/trap.c b/kernel/trap.c
index a63249e..0c62033 100644
--- a/kernel/trap.c
+++ b/kernel/trap.c
@@ -49,6 +49,37 @@ usertrap(void)
   
   // save user program counter.
   p->trapframe->epc = r_sepc();
+
+
+  // seu liangji add, to use timer intr
+  if(devintr() == 2 && ((p->func_cb !=0) || (p->ticks_inv !=0))){
+
+      p->ticks_cnt++;
+
+      //printf("p->ticks_cnt = %d\n", p->ticks_cnt);
+      if( p->ticks_inv != 0 && p->ticks_cnt >= p->ticks_inv && p->ticks_lock == 0){
+          //printf("hint!, cnt = %d\n", p->ticks_cnt);
+          p->ticks_cnt = 0;
+          //get lock
+          p->ticks_lock = 1;
+          // need to run signal callback function, first should copy trapframe, and then use sigreturn to return trapframe
+          // Allocate a trapframe page.
+          acquire(&p->lock);
+          if((p->trapframe_signal_backup = (struct trapframe *)kalloc()) == 0){
+              panic("fail to kalloc trapframe_signal_backup");
+          }
+          release(&p->lock);
+          // copy trapframe , old user space
+          memmove(p->trapframe_signal_backup, p->trapframe, sizeof(struct trapframe));
+
+          // change user space
+          // because func_cb is just involve static var(BSS), not use stack, so just jump pc to func_cb
+          p->trapframe->epc = p->func_cb;
+
+          //not unlock until sigreturn, callback is ok
+          //p->ticks_lock = 0;
+      }
+  }
   
   if(r_scause() == 8){
     // system call
diff --git a/user/user.h b/user/user.h
index b71ecda..fd97ee2 100644
--- a/user/user.h
+++ b/user/user.h
@@ -40,3 +40,7 @@ void free(void*);
 int atoi(const char*);
 int memcmp(const void *, const void *, uint);
 void *memcpy(void *, const void *, uint);
+
+//alarm
+int sigalarm(int ticks, void (*handler)());
+int sigreturn(void);
diff --git a/user/usys.pl b/user/usys.pl
index 01e426e..fa548b0 100755
--- a/user/usys.pl
+++ b/user/usys.pl
@@ -36,3 +36,5 @@ entry("getpid");
 entry("sbrk");
 entry("sleep");
 entry("uptime");
+entry("sigalarm");
+entry("sigreturn");
-- 
2.25.1



```

## 后续思考
**1. 必须写sigreturn()系统调用来终止吗？**

在计算机科学中，这被称为信号处理的收尾（Signal Cleanup）。

虽然看起来麻烦，但**所有的异步信号机制都需要类似的收尾逻辑**。原因是：

- **栈和寄存器的隔离**：当信号（或中断）发生时，它是异步的。用户程序可能运行在任何指令处。如果没有一个机制（如系统调用）告诉内核“我已经处理完了，请把刚才偷走的寄存器还给我”，CPU 根本无法自动找回之前的执行状态。

`主流系统的做法`：

>**Linux/Unix**：实际上也是这么做的。内核会在`用户栈上放置一段微型的代码（称为 Signal Trampoline）`，这段代码的唯一作用就是执行 sigreturn 系统调用。

`封装`：在标准库（如 Glibc）中，这些细节都被封装好了。程序员只需要写 handler，而库函数会自动帮你处理跳转和收尾。

**2. 对回调函数（Handler）的要求**
   
你提到的“对栈的要求”切中了要害。

**栈的破坏问题**

目前的实验版本中，`handler回调函数` 直接运行在原程序的`用户栈`上。如果：

- handler 函数定义了巨大的局部变量。

原程序本来就已经快把栈用完了（Stack Overflow）。 那么执行 handler 就会彻底破坏原程序的栈数据，导致 sigreturn 之后原程序依然崩溃。

**解决方案**：`信号栈（Signal Stack）`

为了解决这个问题，高级系统（如 Linux）允许进程通过 sigaltstack 系统调用**注册一个独立的信号栈**。当信号发生时，内核不但修改 `epc`，还会修改 trapframe->`sp` 指向这个`独立的栈空间`。

**数据段的影响**

正如你所观察到的，**handler 和原程序共享数据段**：

`副作用`：如果 handler 修改了全局变量，原程序确实会感知到。

`重入性限制`：这要求 handler 尽量是“`可重入`”的。
如果在 handler 里调用了像 printf 或 malloc 这样使用了全局锁的函数，而原程序恰好在被中断时也持有这些锁，就会发生死锁。
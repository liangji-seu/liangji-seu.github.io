---
title: xv6 lab3
date: 2026-01-27 14:56:47
categories: [学习笔记, 嵌入式, OS] 
tags: [嵌入式, OS, XV6]
---
# 页表
本节主要学习页表，包括内核的地址空间，物理内存的分配，用户进程的地址空间，页表的作用和实现逻辑等。

## usyscall
这个实验的目的是希望通过在用户态和内核态之间创建一个只读的共享内存，来加快系统调用。

正常系统调用，需要系统调用保存参数到cpu寄存器，保存现场到trapframe中，然后ecall，进行内核态的切换，这一系列操作很花时间，主要是内核态的切换比较耗时。

所以这个实验想要通过共享只读内存的方式，来代替内核态的切换。

通过观察kernel/memlayout.h，可以看出
``` c
// the kernel expects there to be RAM
// for use by the kernel and user pages
// from physical address 0x80000000 to PHYSTOP.
#define KERNBASE 0x80000000L
#define PHYSTOP (KERNBASE + 128*1024*1024)

// map the trampoline page to the highest address,
// in both user and kernel space.
#define TRAMPOLINE (MAXVA - PGSIZE)

// map kernel stacks beneath the trampoline,
// each surrounded by invalid guard pages.
#define KSTACK(p) (TRAMPOLINE - (p)*2*PGSIZE - 3*PGSIZE)

// User memory layout.
// Address zero first:
//   text
//   original data and bss
//   fixed-size stack
//   expandable heap
//   ...
//   USYSCALL (shared with kernel)
//   TRAPFRAME (p->trapframe, used by the trampoline)
//   TRAMPOLINE (the same page as in the kernel)
#define TRAPFRAME (TRAMPOLINE - PGSIZE)
#ifdef LAB_PGTBL
#define USYSCALL (TRAPFRAME - PGSIZE)

struct usyscall {
  int pid;  // Process ID
};
#endif
```

可以看到，`KERNBASE，PHYSTOP`，这两个是物理地址。
后面的TRAMPOLINE，KSTACK，TRAPFRAME都是指的虚拟内存的一个划分。
从这个布局，可以看出，他希望在TRAPFRAME向下，安排一个**新的虚拟内存的区域**，USYSCALL。

这样也就是要在页表里面，增加这一项的映射关系。

所以主要的实现，是在进程创建页表的逻辑里面。

具体实现逻辑如下：

``` c
From b49d8707169474d9c12af12f970f345fb1eab1be Mon Sep 17 00:00:00 2001
From: liangji-seu <15262272286@163.com>
Date: Thu, 29 Jan 2026 21:53:28 +0800
Subject: [PATCH 1/2] support speed up syscall using share user space mem

---
 kernel/proc.c | 27 +++++++++++++++++++++++++++
 kernel/proc.h |  1 +
 2 files changed, 28 insertions(+)

diff --git a/kernel/proc.c b/kernel/proc.c
index 22e7ce4..a09de1b 100644
--- a/kernel/proc.c
+++ b/kernel/proc.c
@@ -127,6 +127,15 @@ found:
     return 0;
   }
 
+  // Allocate a usyscall page by liangji
+  if((p->usyscall = (struct usyscall *)kalloc()) == 0){
+    freeproc(p);
+    release(&p->lock);
+    return 0;
+  }else{
+    p->usyscall->pid = p->pid;
+  }
+
   // An empty user page table.
   p->pagetable = proc_pagetable(p);
   if(p->pagetable == 0){
@@ -153,6 +162,15 @@ freeproc(struct proc *p)
   if(p->trapframe)
     kfree((void*)p->trapframe);
   p->trapframe = 0;
+
+  // liangji free usyscall
+  if(p->usyscall)
+  {
+      kfree((void*)p->usyscall);
+  }
+  p->usyscall = 0;
+
+
   if(p->pagetable)
     proc_freepagetable(p->pagetable, p->sz);
   p->pagetable = 0;
@@ -164,6 +182,7 @@ freeproc(struct proc *p)
   p->killed = 0;
   p->xstate = 0;
   p->state = UNUSED;
+
 }
 
 // Create a user page table for a given process,
@@ -196,6 +215,13 @@ proc_pagetable(struct proc *p)
     return 0;
   }
 
+  // map the usyscall just below TRAPFRAME by seu liangji
+  if(mappages(pagetable, USYSCALL, PGSIZE,
+              (uint64)(p->usyscall), PTE_U | PTE_R) < 0){
+    uvmfree(pagetable, 0);
+    return 0;
+  }
+
   return pagetable;
 }
 
@@ -206,6 +232,7 @@ proc_freepagetable(pagetable_t pagetable, uint64 sz)
 {
   uvmunmap(pagetable, TRAMPOLINE, 1, 0);
   uvmunmap(pagetable, TRAPFRAME, 1, 0);
+  uvmunmap(pagetable, USYSCALL, 1, 0);
   uvmfree(pagetable, sz);
 }
 
diff --git a/kernel/proc.h b/kernel/proc.h
index f6ca8b7..cb4ba0e 100644
--- a/kernel/proc.h
+++ b/kernel/proc.h
@@ -101,6 +101,7 @@ struct proc {
   uint64 sz;                   // Size of process memory (bytes)
   pagetable_t pagetable;       // User page table
   struct trapframe *trapframe; // data page for trampoline.S
+  struct usyscall *usyscall; // data page for trampoline.S
   struct context context;      // swtch() here to run process
   struct file *ofile[NOFILE];  // Open files
   struct inode *cwd;           // Current directory
-- 
2.25.1


```
## vmprint
这个实验比较简单，就是考察对用户进程的页表创建过程的理解。

xv6 使用sv39，有3级页表机制来进行从虚拟内存-物理内存的映射。

根据你提供的 xv6 源代码（`vm.c`, `proc.c`, `kalloc.c`）和参考图片，我为你总结了内核页表创建与进程页表操作的流程笔记。

---

### 1. 内核页表创建流程 (Kernel Page Table Initialization)

当系统启动进入 `main()` 函数后，首先会通过 `kvminit()` 初始化全局内核页表。这一过程建立了内核运行所需的物理地址到虚拟地址的**直接映射**。

```text
硬件上电 → ... → main() 
                   ↓
            kvminit() : 创建全局内核页表 kernel_pagetable
                   ↓
            kvmmake() : 核心映射逻辑
                   ↓
    +-------------------------------------------------------+
    | 1. kalloc()        : 申请一个 4KB 页面作为页表根目录      |
    | 2. memset()        : 清零该页面                          |
    | 3. kvmmap(...)     : 建立如下关键映射 (Direct Map)       |
    |    - UART0         : 串口设备 I/O 地址                  |
    |    - VIRTIO0       : 磁盘接口 I/O 地址                  |
    |    - PLIC          : 中断控制器地址                      |
    |    - KERNBASE      : 内核代码段 (etext 以前, RX 权限)      |
    |    - etext         : 内核数据段 & RAM (etext 以后, RW 权限)|
    |    - TRAMPOLINE    : 映射最高虚拟地址处的跳板代码          |
    | 4. proc_mapstacks(): 为每个进程的内核栈分配物理内存并映射   |
    +-------------------------------------------------------+
                   ↓
            kvminithart() : 激活分页机制
                   ↓
    +-------------------------------------------------------+
    | 1. w_satp()        : 将 kernel_pagetable 地址写入 satp 寄存器
    | 2. sfence_vma()    : 刷新 TLB 快照，确保映射立即生效        |
    +-------------------------------------------------------+

```

---

### 2. 进程创建中的页表操作 (Process Page Table Operations)

在 xv6 中，每个进程都有独立的页表。在 `allocproc()` 和 `fork()` 过程中，页表的操作是确保进程隔离的核心。

#### A. 初始创建流程 (`allocproc` & `proc_pagetable`)

当你创建一个新进程（如第一个进程 `userinit`）时：

```text
allocproc() : 基础资源分配
      ↓
kalloc() -> p->trapframe : 分配物理页存放中断帧
      ↓
kalloc() -> p->usyscall  : 分配物理页存放用户系统调用数据 (由你的代码定制)
      ↓
p->pagetable = proc_pagetable(p) : 构造页表
      ↓
      +----------------------------------------------------------+
      | 1. uvmcreate()    : 申请一页物理内存作为用户页表根目录       |
      | 2. mappages(...)  : 映射 TRAMPOLINE (最高虚拟地址)         |
      | 3. mappages(...)  : 映射 TRAPFRAME (跳板下方, 指向 p->trapframe)
      | 4. mappages(...)  : 映射 USYSCALL (指向 p->usyscall, PTE_U) |
      +----------------------------------------------------------+

```

#### B. 复制进程流程 (`fork`)

当父进程产生子进程时，涉及内存内容的完全拷贝：

```text
fork() : 进程复制
  ↓
allocproc()        : 获取新进程结构及空页表
  ↓
uvmcopy(old, new)  : 物理内存深拷贝核心
  ↓
  +--------------------------------------------------------------+
  | loop (i = 0 to parent->sz)                                   |
  |  1. walk(old_pgtbl) : 找到父进程物理页地址 (pa)                |
  |  2. kalloc()        : 为子进程申请一个新的物理页 (mem)         |
  |  3. memmove()       : 将父进程页内容复制到新页                 |
  |  4. mappages(new)   : 在子进程页表中建立该虚拟地址到新物理页的映射 |
  +--------------------------------------------------------------+

```

---

### 3. 关键函数逻辑摘要 (Note Summary)

| 函数名 | 作用 | 核心代码细节 |
| --- | --- | --- |
| **`walk()`** | 页表查找/建立 | 模拟 RISC-V 三级页表查找，若 `alloc` 为真且中间页表缺失，则调用 `kalloc` 补齐。 |
| **`mappages()`** | 建立映射 | 将一段虚拟地址区间映射到物理地址区间，并在 PTE 中设置权限位（`PTE_R/W/X/U`）。 |
| **`uvmunmap()`** | 撤销映射 | 解除映射，若 `do_free` 为真，则通过 `kfree` 释放物理内存。 |
| **`kalloc/kfree`** | 物理页管理 | 管理空闲链表 `kmem.freelist`，分配和回收 4096 字节的物理页面。 |


### vmprint实现
``` c
From 71a9a91a6eecbcbc8bf9b8347becadb65ddea61d Mon Sep 17 00:00:00 2001
From: liangji-seu <15262272286@163.com>
Date: Fri, 30 Jan 2026 13:27:37 +0800
Subject: [PATCH 2/2] feat: support vmprint

---
 kernel/defs.h |  1 +
 kernel/exec.c |  7 +++++++
 kernel/vm.c   | 26 ++++++++++++++++++++++++++
 3 files changed, 34 insertions(+)

diff --git a/kernel/defs.h b/kernel/defs.h
index 3564db4..38ad8dd 100644
--- a/kernel/defs.h
+++ b/kernel/defs.h
@@ -170,6 +170,7 @@ uint64          walkaddr(pagetable_t, uint64);
 int             copyout(pagetable_t, uint64, char *, uint64);
 int             copyin(pagetable_t, char *, uint64, uint64);
 int             copyinstr(pagetable_t, char *, uint64, uint64);
+void            vmprint(pagetable_t, int);
 
 // plic.c
 void            plicinit(void);
diff --git a/kernel/exec.c b/kernel/exec.c
index d62d29d..bc3466f 100644
--- a/kernel/exec.c
+++ b/kernel/exec.c
@@ -116,6 +116,13 @@ exec(char *path, char **argv)
   p->trapframe->sp = sp; // initial stack pointer
   proc_freepagetable(oldpagetable, oldsz);
 
+  // liangji add, to test vmprint pagetable
+  if(p->pid == 1)
+  {
+      printf("page table %p\n", p->pagetable);
+      vmprint(p->pagetable, 2);
+
+  }
   return argc; // this ends up in a0, the first argument to main(argc, argv)
 
  bad:
diff --git a/kernel/vm.c b/kernel/vm.c
index d5a12a0..a135d6c 100644
--- a/kernel/vm.c
+++ b/kernel/vm.c
@@ -432,3 +432,29 @@ copyinstr(pagetable_t pagetable, char *dst, uint64 srcva, uint64 max)
     return -1;
   }
 }
+
+
+// print user process pagetable
+void vmprint(pagetable_t pagetable, int level)
+{
+    int l = level;
+    for(int i = 0; i< 512; i++){
+        pte_t pte = pagetable[i];
+
+        if((pte & PTE_V) && l == 2){
+            // pte is valid, and is not final pagetable pte
+            uint64 child = PTE2PA(pte);
+            printf("..%d: pte %p pa %p\n", i, pte, child);
+            vmprint((pagetable_t)child, l-1);
+
+        }else if((pte & PTE_V) && l == 1){
+            uint64 child = PTE2PA(pte);
+            printf(".. ..%d: pte %p pa %p\n", i, pte, child);
+            vmprint((pagetable_t)child, l-1);
+
+        } else if((pte & PTE_V) && l == 0){
+            printf(".. .. ..%d: pte %p pa %p\n", i, pte, PTE2PA(pte));
+        }
+    }
+
+}
-- 
2.25.1


```


## pgaccess

这个实验的目的是为了利用系统调用来查看数据页是否被人访问。

简单来说，就是该系统调用，传入参数：用户空间malloc出32个数据页，得到这个的虚拟地址，传入页数量，最终结果放到一个unsigned int 里面。

在这里我犯了以下几个错误：
1. **页表和数据页的区分：**
页表是每个进程用来记录用户空间的虚拟地址到物理地址映射的。所以，页表，顾名思义，是一个关于页的映射的表。pagetable里面每一项（pte）表示的是从va（一页）映射到pa（一页，4096KB），所以，正确的做法是，malloc出来的32*PAGESIZE大小的内存在堆中，返回的指针（就是一个地址，实际上就是uint64，用argaddr得到）。这个就是虚拟地址va（第一页的地址），所以需要做的就是已知va，想到知道这一页是否被访问（即想要得到va的pte，因为只有pte才有符号位，不需要知道pa），所以就需要walk

2. **指针位移和地址数据位移的区别：**
uint64 addr和 uint64* p, 如果都指向的是32*page的开头，如何后移指向第二个页的开头地址呢？
因为uint64是数值，里面的数值表示地址，指向第一个页的第一个字节，所以直接+字节数即可。（所以它可以表示的地址最小间隔是一个字节）
如果是uint64*， 是指针，指针内容才是地址。所以一次后移，必须是指针类型大小的整数倍，指针变量的“步进”

> 那一个地址里面的数值代表多少？比如告诉你一个uint64 的地址，地址和地址里面的值，我有点混淆，他们都有多少位？

> 1. 位数对比：地址 vs. 数值
在 xv6 (RISC-V 64-bit) 架构下：
```
对象	        位数 (Bits)	  存储内容	                形象比喻
地址 (Address)	64 位	      指向内存中某个字节的位置。	门牌号（比如：长安街 100 号）
数值 (Value)	64 位 (常见)	  该内存位置存储的具体二进制数据。	房间里的住户（比如：住了 8 个人）

地址的位数：决定了 CPU 理论上能管理的内存有多大。64 位地址意味着可以寻址 2 
64
  字节的空间。
  ```

> 数值的位数：取决于你如何“解读”内存。虽然物理上内存是按字节（8 位）排列的，但我们通常一次读 64 位（即一个 uint64）。

         1. 深度剖析：它们是如何对应的？
当你声明 uint64 *p 时，变量 p 本身占 64 位，它存的是一个地址。当你执行 uint64 v = *p（解引用）时，你是在告诉 CPU：

“去 p 存的那个门牌号，把里面住的 64 位数据取出来传给 v。”

         1. 在 xv6 页表实验中的具体应用
在你的 pgaccess 实验中，这种混淆通常发生在处理 PTE（页表项） 时：

PTE 的地址：这是一个 64 位的 uint64 数值，代表这个条目在内存中的位置。

PTE 的值：这也是一个 64 位的数值，但它的内部被拆分了：

低 10 位：是标志位（Flags），比如 PTE_V, PTE_R, PTE_A。

高 44 位：是物理页号（PPN）。

         1. 常见误区：为什么你之前的代码会“跑飞”？
如果你有一个地址 0x80001000：

数值运算：0x80001000 + 1 = 0x80001001（移动了 1 个字节）。

指针运算：(uint64*)0x80001000 + 1 = 0x80001008（移动了 8 个字节，因为一个 uint64 占 8 字节）。

在 pgaccess 中：

如果你要找下一个页面，你应该在地址数值上加 4096 (PGSIZE)。

如果你要找同一个页表里的下一个条目，你应该在 pte_t * 指针上加 1。



> 所以**最小访问的数据单元就是一个字节**？

**是的**，在绝大多数现代计算机架构（包括 xv6 使用的 RISC-V）中，内存寻址的最小单位就是 1 个字节（1 Byte = 8 Bits）。

这意味着每一个唯一的内存地址都对应着内存中的 1 个字节。

1. “字节寻址”是什么意思？
如果一个内存地址是 0x80001000，它指向的是内存中某一个特定的 8 位（1 字节）数据。

地址 0x80001000：存着第 1 个字节。

地址 0x80001001：存着第 2 个字节。

地址 0x80001002：存着第 3 个字节。

2. 为什么我们常说 64 位（8 字节）？
虽然最小单元是字节，但为了效率，CPU 通常会“成块”地读写数据。

寄存器大小：RISC-V 的 uint64 变量占 8 个字节（64 位）。

内存访问：当你让 CPU 读取一个 uint64 时，它会一次性从内存中抓取连续的 8 个地址单元。

你的实验案例：
在 xv6 的页表（Pagetable）中，一个页面是 4096 字节。

它包含了 4096÷8=512 个页表项（PTE）。

每个 PTE 是一个 uint64，也就是 8 个字节。




3. PTE_A 是标志位的第6位，是固定的，是由riscv标准决定的，不是自己决定的，这个有硬件定义，所以必须是6
4. 关于置位：
``` c
//i位置0
&~(1<<i)

//i位置1
| (1<<i)
```



```c

From e0c7e67170c56a90d1228cde82f47f01ef4ee6be Mon Sep 17 00:00:00 2001
From: liangji-seu <15262272286@163.com>
Date: Fri, 30 Jan 2026 15:07:24 +0800
Subject: [PATCH] feat: support pgaccess

---
 kernel/defs.h    |  4 +++
 kernel/riscv.h   |  1 +
 kernel/string.c  |  2 ++
 kernel/sysproc.c | 77 ++++++++++++++++++++++++++++++++++++++++++++++++
 kernel/vm.c      |  2 ++
 5 files changed, 86 insertions(+)

diff --git a/kernel/defs.h b/kernel/defs.h
index 38ad8dd..7398a96 100644
--- a/kernel/defs.h
+++ b/kernel/defs.h
@@ -130,6 +130,7 @@ char*           safestrcpy(char*, const char*, int);
 int             strlen(const char*);
 int             strncmp(const char*, const char*, uint);
 char*           strncpy(char*, const char*, int);
+void            print_last_10_bits(uint64);
 
 // syscall.c
 int             argint(int, int*);
@@ -171,6 +172,9 @@ int             copyout(pagetable_t, uint64, char *, uint64);
 int             copyin(pagetable_t, char *, uint64, uint64);
 int             copyinstr(pagetable_t, char *, uint64, uint64);
 void            vmprint(pagetable_t, int);
+pte_t *         walk(pagetable_t, uint64, int);
+
+
 
 // plic.c
 void            plicinit(void);
diff --git a/kernel/riscv.h b/kernel/riscv.h
index 1691faf..8d8c34f 100644
--- a/kernel/riscv.h
+++ b/kernel/riscv.h
@@ -343,6 +343,7 @@ sfence_vma()
 #define PTE_W (1L << 2)
 #define PTE_X (1L << 3)
 #define PTE_U (1L << 4) // 1 -> user can access
+#define PTE_A (1L << 6) // 1 -> PTE has been accessed
 
 // shift a physical address to the right place for a PTE.
 #define PA2PTE(pa) ((((uint64)pa) >> 12) << 10)
diff --git a/kernel/string.c b/kernel/string.c
index 153536f..a9f5134 100644
--- a/kernel/string.c
+++ b/kernel/string.c
@@ -105,3 +105,5 @@ strlen(const char *s)
   return n;
 }
 
+
+
diff --git a/kernel/sysproc.c b/kernel/sysproc.c
index 3bd0007..7a9b924 100644
--- a/kernel/sysproc.c
+++ b/kernel/sysproc.c
@@ -77,10 +77,87 @@ sys_sleep(void)
 
 
 #ifdef LAB_PGTBL
+void
+clear_access(pagetable_t pagetable){
+
+    for(int i =0; i< 512; i++)
+    {
+        pte_t *pte = &(pagetable[i]);
+        *pte = *pte & ~(PTE_A);
+    }
+    return;
+}
+
+void print_last_10_bits(uint64 num) {
+    // 步骤1：用掩码 0x3FF（二进制 10 个 1）提取最后 10 位
+    uint64 last_10 = num & 0x3FF;  // 0x3FF = 2^10 - 1 = 1023
+
+    // 步骤2：逐位打印最后 10 位（从第9位到第0位，保证补全前导0）
+    for (int i = 9; i >= 0; i--) {
+        // 按位判断：1 则打印 1，0 则打印 0
+        printf("%d", (last_10 >> i) & 1);
+    }
+    printf("\n");
+}
+
 int
 sys_pgaccess(void)
 {
   // lab pgtbl: your code here.
+  uint64 base_addr;
+  int page_num;
+  uint64 dst_addr;
+  unsigned int result = 0;
+  
+
+
+  //get arg1 = addr
+  if(argaddr(0, &base_addr) != 0 ){
+      return -1;
+  }
+
+  //get arg2 = len
+  if(argint(1, &page_num) !=0 ){
+      return -1;
+  }
+
+  //get arg1 = addr
+  if(argaddr(2, &dst_addr) != 0 ){
+      return -1;
+  }
+
+  printf("pgaccess: %p %d %p\n", base_addr, page_num, dst_addr);
+
+  // for each page
+  for(int i =0; i<page_num; i++){
+      // get va of each page
+
+      //uint64 va = ((pagetable_t)base_addr)[i];
+      uint64 va = base_addr + i*(4096);
+
+      //printf("get va = %p of this page\n", va);
+      // search in user process pagetable  va -> pa
+      // get pa of each page from proc pagetable
+
+      pte_t *pte;
+      pte = walk(myproc()->pagetable, va, 0);
+      if(pte == 0){
+        printf("fail to find pte of page %d\n", i);
+        return 0;
+      }
+
+        // if find one pte is accessed
+        if((*pte & PTE_V) && (*pte & PTE_A)){
+            *pte = *pte & ~(PTE_A);
+            result = result | (1<<i);
+    }
+  }
+
+  //copy result to user space
+  if(copyout(myproc()->pagetable, dst_addr, (char*)&result, sizeof(unsigned int)) < 0 ){
+    printf("fail to copyout\n");
+  }
+
   return 0;
 }
 #endif
diff --git a/kernel/vm.c b/kernel/vm.c
index a135d6c..3d61968 100644
--- a/kernel/vm.c
+++ b/kernel/vm.c
@@ -87,6 +87,7 @@ walk(pagetable_t pagetable, uint64 va, int alloc)
     pte_t *pte = &pagetable[PX(level, va)];
     if(*pte & PTE_V) {
       pagetable = (pagetable_t)PTE2PA(*pte);
+
     } else {
       if(!alloc || (pagetable = (pde_t*)kalloc()) == 0)
         return 0;
@@ -94,6 +95,7 @@ walk(pagetable_t pagetable, uint64 va, int alloc)
       *pte = PA2PTE(pagetable) | PTE_V;
     }
   }
+
   return &pagetable[PX(0, va)];
 }
 
-- 
2.25.1



```
---
title: xv6 lab5
date: 2026-02-03 12:53:23
categories: [学习笔记, 嵌入式, OS] 
tags: [嵌入式, OS, XV6]
---

# cow fork
## 存储空间定义
关于存储，首先，存储器的访问颗粒是1个字 = 8bit, 所以每个字节 都有一个物理地址。
![alt text](../images/20.1.png)
![alt text](../images/20.2.png)

>所以如果定义一个指针，uint64* p; 他实际上是一块uint64的内存，里面存放的是一个uint64内存的开始地址，也可以表示一片连着的uint64内存的初始块的起始地址（数组）

这也就解释了，为什么如果uint64 a, a++, 则表示的是下一个字节，而uint64 *a, a++, 则a指向的是下一个uint64内存。

## pagetable_t
```c
//riscv.h
typedef uint64 pte_t;                          
typedef uint64 *pagetable_t; // 512 PTEs 
```

所以pagetable是一个指向uint64_t的内存块的**数组**的指针

里面每一项，**是pte,也就是一个8字节的内存**。64位，但是我们只使用里面的后面一部分的位数

**硬件是如何转换的？**

CPU访问一个虚拟地址（例如0x80001234）时，`硬件（MMU）`会进行以下动作：

VPN : xv6 (Sv39) 中，前27位（0x234）是偏移量。

查表寻踪：MMU 持有 VPN 去查表，找到对应的 PTE。

PTE中取出对应的物理页号（PPN），这就是物理内存中那一页的“起始” 。

直接调整12位偏移量，就得到了最终的物理地址。

关键点：映射对称，低12位是完全不动、原封不动地复制过去的。

>**VA**：[ 虚拟页号 A ]+[ 偏移量 0x234 ]
>
>**PA**：[ 物理页号 B ]+[ 偏移量 0x234 ]


## fork
分析一下普通的fork的内容
1. **创建子进程allocproc()**
   1. np->pid
   2. np->status = USED
   3. np->trapframe = kalloc() 分配一页（4096字节）的物理内存地址
   4. np->pagetable 创建空的页表
      1. uvmcreate()，默认分配一页内存 创建pagetable_t变量指向这段内存
      2. mappage(trampoline) 添加一页映射trampoline
      3. mappage(trapframe) 添加一页映射前面分配的trapframe
   5. np->context, 指定上下文
      1. context->ra = forkret
      2. context->sp = kstack + PIGESIZE (sp栈底到栈顶1页大小)
2. **uvmcopy**(p->pagetable, np->pagetable, p->sz) 拷贝父进程页表到子进程
      1. 针对每一页虚拟内存的起始地址va(uint64)（0 ~ p->sz）
         1. 从父进程的pagetable中walk出该页虚拟地址va对应的pte(一段uint64内存)
         2. 验证该pte是否有效（PTE_V）
         3. (因为我们不需要父进程pte，而是需要在子进程复制一份pte)
         4. PTE2PA 得到 该va对应的pa
         5. 拷贝父进程该va对应的pte的flag
         6. 申请一页空的内存mem kalloc
         7. 从父进程的pa拷贝父进程的该页内存到mem
         8. mappage 添加该va ~ mem 的映射在子进程的页表中
3. np->sz = p->sz 拷贝父进程的虚拟地址空间大小
4. 拷贝父进程trapframe内容
5. 设置子进程的fork()返回值a0寄存器 = 0
6.  复制文件描述符引用
7.  复制进程名
8.  np->parent = p
9.  设置子进程状态RUNABLE，加入调度器，开始运行
10. 返回子进程pid

> p->sz, kstack什么时候定的？

## kalloc
`kalloc.c`负责对物理内存的管理，因为这里涉及到一个链表结构：
``` c
struct run {
  struct run *next;
};

struct {
  struct spinlock lock;
  struct run *freelist;
} kmem;

```

kmem就是我们实际的内核的物理内存管理员，他持有一个锁（针对多cpu申请内存），还有一个struct run的指针，

注意这里struct run的结构体，他这里只是借用了struct结构体的一个内部变量内存结构，这样就相当于说明，一个一小块内存，里面排头的一个8字节指针，指向下一块小内存。就这样一直指下去，至于里面的值是什么，不知道，纯粹的野指针。

他先创建了这么个结构，然后有一个头：struct run *freelist, 她指向第一块这个小struc内存

``` c
void
freerange(void *pa_start, void *pa_end)
{
  char *p;
  p = (char*)PGROUNDUP((uint64)pa_start);
  for(; p + PGSIZE <= (char*)pa_end; p += PGSIZE)
    kfree(p);
}
```

这里是freerange，他是在系统初始化的时候在init的时候被调用的，告知他物理内存的起始和终止位置。freerange会把这块物理内存，按页大小（4096字节）**划分好**，并传入每页的起始地址，**给kfree，用于释放，串联**。

```c
void
kfree(void *pa)
{
  struct run *r;

  if(((uint64)pa % PGSIZE) != 0 || (char*)pa < end || (uint64)pa >= PHYSTOP)
    panic("kfree");

  // Fill with junk to catch dangling refs.
  memset(pa, 1, PGSIZE);

  r = (struct run*)pa;

  acquire(&kmem.lock);
  r->next = kmem.freelist;
  kmem.freelist = r;
  release(&kmem.lock);
}
```

kfree，当freerange传入一页物理内存的指针，他会格式化这一页内存，然后把这个指针改成struct run的指针，这样就完成了r对这个内存的指向，虽`然他实际上还是指向的一个struct run这块小内存，但起始地址是相同的`，**指针r里面存的地址才是我们想要的**，至于struct run是什么我们不关心。
这样就可以逐步把这些指针串起来，变成一个一页一页的链表，至此，freerange就完成了对初始状态下，空闲内存列表的收集。


```c
void *
kalloc(void)
{
  struct run *r;

  acquire(&kmem.lock);
  r = kmem.freelist;
  if(r)
    kmem.freelist = r->next;
  release(&kmem.lock);

  if(r)
    memset((char*)r, 5, PGSIZE); // fill with junk
  return (void*)r;
}
```
最后就是kalloc了，就是从这个空闲链表上摘下一个空闲页。如果用完了要释放了，就还用上面的kfree释放物理页，让他重新回归空闲列表。

## cow fork实现

> **注意一点**：
> 
> cow fork 和 fork本质上没什么不同，只是延时创建内存，共同的，`子进程还是无法写父进程的只读区域`，也就是无法动父进程的代码段。
>
> 这里要区分于`fork + exec`， exec才是真正把所有内存区域全部写，覆盖成你要执行的指令程序。这样覆盖完后，`只读区域，和读写区域就变了`。就完成了一个全新的指令进程了。

**1. 分配**

应该修改uvmcopy的内容，不能直接mem = kalloc分配内存拷贝，而是就用父进程的那一页物理内存，直接加入页表，同时设置父进程页表和子进程页表为合法，只读

**2. 使用**

思路如下：
![alt text](../images/20.3.png)



**3. 释放**

这里也很关键，不然sh执行指令exec覆盖的时候，就会出现释放kfree灾难，所以有必要了解一下总结在上面的`kalloc的内容`

所以要关注什么时候，需要真正释放，而不是结束一次进程就要释放一次进程，这样就释放灾难了。

这里非常关键，如果你没有内存页统计管理的话，就会导致进程在执行中，容易释放掉所有的内存，因为子进程不管你的父进程有啥，直接free了，

这样容易报错：
``` bash
xv6 kernel is booting

hart 2 starting
hart 1 starting
init: starting sh
$ ls
.              1 1 1024
..             1 1 1024
README         2 2 2226
cat            2 3 23896
echo           2 4 22728
forktest       2 5 13088
grep           2 6 27256
init           2 7 23832
kill           2 8 22704
ln             2 9 22656
ls             2 10 26128
mkdir          2 11 22800
rm             2 12 22792
sh             2 13 41664
stressfs       2 14 23800
usertests      2 15 156016
grind          2 16 37976
wc             2 17 25040
zombie         2 18 22192
cowtest        2 19 30232
console        3 20 0
usertrap(): unexpected scause 0x0000000000000002 pid=2, name = sh
            sepc=0x0000000000001000 stval=0x0000000000000000
Fault info: VA=0x0000000000001000, PTE_VAL=0x0000000021fda50b, Flags=0x000000000000010b
usertrap(): unexpected scause 0x000000000000000c pid=1, name = init
            sepc=0x0000000000001000 stval=0x0000000000001000
panic: init exiting
QEMU: Terminated
```


kalloc.c里面的实现逻辑，需要有一个对物理内存页的全局计数：

总结规则就是：

**1. kalloc** -> 申请新的物理内存 （cnt = 1）

**2. kfree** ->
   1. cnt > 1, (实际上不止一个进程拥有这块内存页)， cnt -1
   2. cng <=0, (此时需要回收内存)， cnt = 0

**3. kinit** -> 初始化统计数组为0，（这样freerange里面才能触发kfree，统一收集所有空闲内存页）

```c
diff --git a/kernel/kalloc.c b/kernel/kalloc.c
index fa6a0ac..0cac44a 100644
--- a/kernel/kalloc.c
+++ b/kernel/kalloc.c
@@ -18,15 +18,29 @@ struct run {
   struct run *next;
 };

+#define MEM_NUM (PHYSTOP-KERNBASE)/PGSIZE
+
 struct {
   struct spinlock lock;
   struct run *freelist;
+  uint8 pa_mem_cnt[MEM_NUM];
 } kmem;

+void
+kmem_py_mem_cnt_add(uint64 pa)
+{
+    //add pa_mem_cnt
+    acquire(&kmem.lock);
+    int id = (pa-KERNBASE)/PGSIZE;
+    kmem.pa_mem_cnt[id]++;
+    release(&kmem.lock);
+}
+
 void
 kinit()
 {
   initlock(&kmem.lock, "kmem");
+  memset(kmem.pa_mem_cnt, 0, sizeof(kmem.pa_mem_cnt));
   freerange(end, (void*)PHYSTOP);
 }

@@ -51,12 +65,28 @@ kfree(void *pa)
   if(((uint64)pa % PGSIZE) != 0 || (char*)pa < end || (uint64)pa >= PHYSTOP)
     panic("kfree");

+/*
+  if(kmem_py_mem_cnt_modify((uint64)pa, 0) != 0){
+      // find pa page minus , but not == 0
+      return;
+  }
+  */
+
+  acquire(&kmem.lock);
+  int id = ((uint64)pa-KERNBASE)/PGSIZE;
+  if(kmem.pa_mem_cnt[id] > 1){
+      kmem.pa_mem_cnt[id]--;
+      release(&kmem.lock);
+      return;
+  }
+
+  kmem.pa_mem_cnt[id] = 0;
+
   // Fill with junk to catch dangling refs.
   memset(pa, 1, PGSIZE);

   r = (struct run*)pa;

-  acquire(&kmem.lock);
   r->next = kmem.freelist;
   kmem.freelist = r;
   release(&kmem.lock);
@@ -74,9 +104,16 @@ kalloc(void)
   r = kmem.freelist;
   if(r)
     kmem.freelist = r->next;
+
+  // add 1 in r page
+  // 拿出新内存
+  int id = ((uint64)r-KERNBASE)/PGSIZE;
+  kmem.pa_mem_cnt[id] = 1;
+
   release(&kmem.lock);

   if(r)
     memset((char*)r, 5, PGSIZE); // fill with junk
+
   return (void*)r;
 }
```
> 这边我犯了一些错误，只考虑了单个cpu的情况，事实上，会有很多个cpu，这会导致，如果你修改kmem内存管理员内的任何东西的时候，如果不**加锁**，会出现数据被意外修改。所以一定要完整的加锁才行



**4. 使用支持内存计数统计**
当我们在kalloc.c中支持了物理内存页的计数统计，肯定需要让cpu在处理访问页的时候，用上。
所以，还要在之前的uvmcopy，usertrap中用上。

因为对于进程和内存来说，总共就3种涉及的关系：
1. 申请新的kalloc()
2. 释放旧的kfree()
3. 拷贝内存uvmcopy()

所以这里需要再次修改之前的uvmcopy(), 之前只实现了cow的标志位逻辑和申请拷贝逻辑，没有计数。后面trap的时候，就无法根据计数正确的释放free

```c
//uvmcopy()
//完成标志位C设置
kmem_py_mem_cnt_add(pa); //对该内存计数+1
//拷贝含C的页表项


//usertrap()
// 申请新内存
kfree((void *)pa); //释放老内存，实际上是只对计数-1，不是真的释放
// 制作新的页表项.....
```
此时，进行cowtest测试, 可以看到简单测试已经通过了，还有一个file的test
``` bash
cowtest        2 19 30232
console        3 20 0
$ cowtest
simple: ok
simple: ok
three: ok
three: ok
three: ok
file: usertrap(): unexpected scause 0x0000000000000002 pid=5, name = cowtest
            sepc=0x0000000000000dbc stval=0x0000000000000004
$
$
$
$ QEMU: Terminated
```

这个file的test，实际上是要copyout也要实现缺页处理
## copyout
正常普通的**写内存**可能发生在：
1. cpu修改变量的值
2. exec覆盖内存
3. copyout内核把数据往用户空间的内存拷贝。
4. ......

这些情况都可以因为mmu+pagetable，出现页异常。

所以，copyout也要像usertrap一样，进行页处理
``` c
@@ -356,12 +378,51 @@ copyout(pagetable_t pagetable, uint64 dstva, char *src, uint64 len)
     n = PGSIZE - (dstva - va0);
     if(n > len)
       n = len;
-    memmove((void *)(pa0 + (dstva - va0)), src, n);
+
+    // liangji add
+    pte_t *pte;
+    char *mem = (char*)pa0;
+    uint flags;
+    if((pte = walk(pagetable, va0, 0)) == 0)
+    {
+        panic("write page, cannot walk pte");
+    }
+    if((*pte & PTE_V) == 0)
+    {
+        panic("write page, walk pte, but not valid");
+    }
+
+    // if w=0 && c=1
+    if(((*pte & PTE_W) == 0 ) && ((*pte & PTE_C) != 0)){
+          //alloc and copy mem
+          if((mem = kalloc()) == 0)
+              panic("fail to alloc new mem in cow fork");
+          memmove((void*)(uint64)mem, (void*)pa0, PGSIZE);
+
+          //old pa should cnt --
+          kfree((void *)pa0);
+
+          // set w = 1, and c = 0
+          flags = PTE_FLAGS(*pte);
+          flags |= PTE_W;
+          flags &= ~PTE_C;
+
+          //change child pte
+          uint64 new_pte = PA2PTE((uint64)mem);
+          new_pte &= ~(0x3FF);
+          new_pte |= flags;
+          *pte = new_pte;
+    }
+
+    //memmove((void *)(pa0 + (dstva - va0)), src, n);
+    memmove((void *)((uint64)mem + (dstva - va0)), src, n);

     len -= n;
     src += n;
     dstva = va0 + PGSIZE;
   }
+
+  sfence_vma();
   return 0;
 }

--
2.25.1
```

> 这边我也犯了几个错误
>
> **1. 数据拷贝的时机**
> 
> 因为触发页异常，申请一页新内存，`必须要在释放旧内存前，拷贝旧内存数据到新内存`，原因是：我们实际写数据，不可能刚好写一页4096字节，可能旧写一个字节，甚至只改变一些标志位，`剩下的旧内存数据，依然是有效的`，不能丢弃。
>
> **2. 引用计数逻辑的死循环风险**
> 
> 按道理来说，当释放到这页物理内存，只有一个进程的时候，就不需要再释放，然后申请新页了，直接默认属于最后一个进程就行了。也可以不修复，只是让最后一个进程重新申请一次内存，麻烦一点而已。



## cow fork 的基本实现（cowtest）
``` c
From 43bc35e4289e3d3261ff4a7b7691665b1856c228 Mon Sep 17 00:00:00 2001
From: liangji-seu <15262272286@163.com>
Date: Tue, 3 Feb 2026 23:34:01 +0800
Subject: [PATCH] test: cow

---
 kernel/defs.h   |  3 +++
 kernel/kalloc.c | 39 +++++++++++++++++++++++++++-
 kernel/riscv.h  |  1 +
 kernel/trap.c   | 50 +++++++++++++++++++++++++++++++++++-
 kernel/vm.c     | 67 ++++++++++++++++++++++++++++++++++++++++++++++---
 5 files changed, 155 insertions(+), 5 deletions(-)

diff --git a/kernel/defs.h b/kernel/defs.h
index 3564db4..84df726 100644
--- a/kernel/defs.h
+++ b/kernel/defs.h
@@ -63,6 +63,7 @@ void            ramdiskrw(struct buf*);
 void*           kalloc(void);
 void            kfree(void *);
 void            kinit(void);
+void            kmem_py_mem_cnt_add(uint64);
 
 // log.c
 void            initlog(int, struct superblock*);
@@ -170,6 +171,8 @@ uint64          walkaddr(pagetable_t, uint64);
 int             copyout(pagetable_t, uint64, char *, uint64);
 int             copyin(pagetable_t, char *, uint64, uint64);
 int             copyinstr(pagetable_t, char *, uint64, uint64);
+pte_t *         walk(pagetable_t, uint64 , int);
+
 
 // plic.c
 void            plicinit(void);
diff --git a/kernel/kalloc.c b/kernel/kalloc.c
index fa6a0ac..0cac44a 100644
--- a/kernel/kalloc.c
+++ b/kernel/kalloc.c
@@ -18,15 +18,29 @@ struct run {
   struct run *next;
 };
 
+#define MEM_NUM (PHYSTOP-KERNBASE)/PGSIZE
+
 struct {
   struct spinlock lock;
   struct run *freelist;
+  uint8 pa_mem_cnt[MEM_NUM];
 } kmem;
 
+void
+kmem_py_mem_cnt_add(uint64 pa)
+{
+    //add pa_mem_cnt
+    acquire(&kmem.lock);
+    int id = (pa-KERNBASE)/PGSIZE;
+    kmem.pa_mem_cnt[id]++;
+    release(&kmem.lock);
+}
+
 void
 kinit()
 {
   initlock(&kmem.lock, "kmem");
+  memset(kmem.pa_mem_cnt, 0, sizeof(kmem.pa_mem_cnt));
   freerange(end, (void*)PHYSTOP);
 }
 
@@ -51,12 +65,28 @@ kfree(void *pa)
   if(((uint64)pa % PGSIZE) != 0 || (char*)pa < end || (uint64)pa >= PHYSTOP)
     panic("kfree");
 
+/*
+  if(kmem_py_mem_cnt_modify((uint64)pa, 0) != 0){
+      // find pa page minus , but not == 0
+      return;
+  }
+  */
+
+  acquire(&kmem.lock);
+  int id = ((uint64)pa-KERNBASE)/PGSIZE;
+  if(kmem.pa_mem_cnt[id] > 1){
+      kmem.pa_mem_cnt[id]--;
+      release(&kmem.lock);
+      return;
+  }
+
+  kmem.pa_mem_cnt[id] = 0;
+
   // Fill with junk to catch dangling refs.
   memset(pa, 1, PGSIZE);
 
   r = (struct run*)pa;
 
-  acquire(&kmem.lock);
   r->next = kmem.freelist;
   kmem.freelist = r;
   release(&kmem.lock);
@@ -74,9 +104,16 @@ kalloc(void)
   r = kmem.freelist;
   if(r)
     kmem.freelist = r->next;
+
+  // add 1 in r page 
+  // 拿出新内存
+  int id = ((uint64)r-KERNBASE)/PGSIZE;
+  kmem.pa_mem_cnt[id] = 1;
+
   release(&kmem.lock);
 
   if(r)
     memset((char*)r, 5, PGSIZE); // fill with junk
+
   return (void*)r;
 }
diff --git a/kernel/riscv.h b/kernel/riscv.h
index 1691faf..a578894 100644
--- a/kernel/riscv.h
+++ b/kernel/riscv.h
@@ -343,6 +343,7 @@ sfence_vma()
 #define PTE_W (1L << 2)
 #define PTE_X (1L << 3)
 #define PTE_U (1L << 4) // 1 -> user can access
+#define PTE_C (1L << 8) // 1 -> user can access
 
 // shift a physical address to the right place for a PTE.
 #define PA2PTE(pa) ((((uint64)pa) >> 12) << 10)
diff --git a/kernel/trap.c b/kernel/trap.c
index a63249e..ffa887c 100644
--- a/kernel/trap.c
+++ b/kernel/trap.c
@@ -65,14 +65,62 @@ usertrap(void)
     intr_on();
 
     syscall();
+  } else if (r_scause() == 15){
+      // cannot write va in pagetable
+      // copy mem
+      uint64 stval = PGROUNDDOWN(r_stval());
+      char *mem;
+      pte_t *pte;
+      uint flags;
+      if((pte = walk(p->pagetable, stval, 0)) == 0)
+      {
+          panic("write page, cannot walk pte");
+      }
+      if((*pte & PTE_V) == 0)
+      {
+          panic("write page, walk pte, but not valid");
+      }
+
+      // if w=0 && c=1
+      if(((*pte & PTE_W) == 0 ) && ((*pte & PTE_C) != 0)){
+          //alloc and copy mem
+          uint64 pa = PTE2PA(*pte);
+          if((mem = kalloc()) == 0)
+              panic("fail to alloc new mem in cow fork");
+
+          memmove(mem, (char*)pa, PGSIZE);
+          //old pa should cnt --
+          kfree((void *)pa);
+
+
+          // set w = 1, and c = 0
+          flags = PTE_FLAGS(*pte);
+          flags |= PTE_W;
+          flags &= ~PTE_C;
+
+          //change child pte
+          uint64 new_pte = PA2PTE((uint64)mem);
+          new_pte &= ~(0x3FF);
+          new_pte |= flags;
+          *pte = new_pte;
+          sfence_vma();
+    }
+
   } else if((which_dev = devintr()) != 0){
     // ok
   } else {
-    printf("usertrap(): unexpected scause %p pid=%d\n", r_scause(), p->pid);
+
+    if (r_scause() == 12 || r_scause() == 13 || r_scause() == 15) {
+        pte_t *debug_pte = walk(p->pagetable, r_stval(), 0);
+        printf("Fault info: VA=%p, PTE_VAL=%p, Flags=%p\n", r_stval(), *debug_pte, PTE_FLAGS(*debug_pte));
+    }
+
+    printf("usertrap(): unexpected scause %p pid=%d, name = %s\n", r_scause(), p->pid, p->name);
     printf("            sepc=%p stval=%p\n", r_sepc(), r_stval());
     p->killed = 1;
   }
 
+
   if(p->killed)
     exit(-1);
 
diff --git a/kernel/vm.c b/kernel/vm.c
index d5a12a0..82eab08 100644
--- a/kernel/vm.c
+++ b/kernel/vm.c
@@ -148,8 +148,10 @@ mappages(pagetable_t pagetable, uint64 va, uint64 size, uint64 pa, int perm)
   for(;;){
     if((pte = walk(pagetable, a, 1)) == 0)
       return -1;
-    if(*pte & PTE_V)
+    if(*pte & PTE_V){
+      printf("panic: %p\n", *pte);
       panic("mappages: remap");
+    }
     *pte = PA2PTE(pa) | perm | PTE_V;
     if(a == last)
       break;
@@ -303,7 +305,7 @@ uvmcopy(pagetable_t old, pagetable_t new, uint64 sz)
   pte_t *pte;
   uint64 pa, i;
   uint flags;
-  char *mem;
+  //char *mem;
 
   for(i = 0; i < sz; i += PGSIZE){
     if((pte = walk(old, i, 0)) == 0)
@@ -311,7 +313,17 @@ uvmcopy(pagetable_t old, pagetable_t new, uint64 sz)
     if((*pte & PTE_V) == 0)
       panic("uvmcopy: page not present");
     pa = PTE2PA(*pte);
+
+    //set pte w=0, c=1
+    if(((*pte) & PTE_W) !=0 ){
+        (*pte) &= ~PTE_W;
+        (*pte) |= PTE_C;
+    }
     flags = PTE_FLAGS(*pte);
+
+    //add pa_mem_cnt
+    kmem_py_mem_cnt_add(pa);
+    /*
     if((mem = kalloc()) == 0)
       goto err;
     memmove(mem, (char*)pa, PGSIZE);
@@ -319,7 +331,17 @@ uvmcopy(pagetable_t old, pagetable_t new, uint64 sz)
       kfree(mem);
       goto err;
     }
+
+    */
+
+    if(mappages(new, i, PGSIZE, (uint64)pa, flags) != 0){
+        printf("mappage new pagetable fail\n");
+        goto err;
+    }
+
+
   }
+  sfence_vma();
   return 0;
 
  err:
@@ -356,12 +378,51 @@ copyout(pagetable_t pagetable, uint64 dstva, char *src, uint64 len)
     n = PGSIZE - (dstva - va0);
     if(n > len)
       n = len;
-    memmove((void *)(pa0 + (dstva - va0)), src, n);
+
+    // liangji add 
+    pte_t *pte;
+    char *mem = (char*)pa0;
+    uint flags;
+    if((pte = walk(pagetable, va0, 0)) == 0)
+    {
+        panic("write page, cannot walk pte");
+    }
+    if((*pte & PTE_V) == 0)
+    {
+        panic("write page, walk pte, but not valid");
+    }
+
+    // if w=0 && c=1
+    if(((*pte & PTE_W) == 0 ) && ((*pte & PTE_C) != 0)){
+          //alloc and copy mem
+          if((mem = kalloc()) == 0)
+              panic("fail to alloc new mem in cow fork");
+          memmove((void*)(uint64)mem, (void*)pa0, PGSIZE);
+
+          //old pa should cnt --
+          kfree((void *)pa0);
+          
+          // set w = 1, and c = 0
+          flags = PTE_FLAGS(*pte);
+          flags |= PTE_W;
+          flags &= ~PTE_C;
+
+          //change child pte
+          uint64 new_pte = PA2PTE((uint64)mem);
+          new_pte &= ~(0x3FF);
+          new_pte |= flags;
+          *pte = new_pte;
+    }
+
+    //memmove((void *)(pa0 + (dstva - va0)), src, n);
+    memmove((void *)((uint64)mem + (dstva - va0)), src, n);
 
     len -= n;
     src += n;
     dstva = va0 + PGSIZE;
   }
+
+  sfence_vma();
   return 0;
 }
 
-- 
2.25.1


```


## usertests分析

---
title: imx6ull linux 阻塞与非阻塞
date: 2026-03-06 21:08:17
categories: [学习笔记, 嵌入式, LINUX] 
tags: [嵌入式, linux, 驱动]
---

# linux 阻塞与非阻塞
这里的IO指的是**用户态程序**通过系统调用和**内核态的驱动程序**之间的**输入输出**。

- 阻塞IO：
  - 没获取到需要的资源
  - 进程**进入阻塞状态**，让出cpu，直到获得设备资源为止
  - ![alt text](../images/imx6ull-linux-阻塞与非阻塞-01-0306230232.png)
  - ![alt text](../images/imx6ull-linux-阻塞与非阻塞-02-0306230232.png)
- 非阻塞IO:
  - 没获取到需要的资源，用户态进程不会进入阻塞状态
  - 用户态的IO函数，**直接返回**
  - ![alt text](../images/imx6ull-linux-阻塞与非阻塞-03-0306230232.png)
  - ![alt text](../images/imx6ull-linux-阻塞与非阻塞-04-0306230232.png)
- > **注意**：
- > 这里的**阻塞**，需要**驱动程序配合**，如果配合，还是阻塞不了.

# linux实现**阻塞/非阻塞IO**的几个机制
## 等待队列 wait queue（**阻塞**）
阻塞访问的最大好处就是省资源，因为进程进入阻塞状态，让出了cpu。

但是当设备文件可以操作的时候，必须要唤醒进程（一般在中断函数中完成唤醒工作）

所以，linux内核提供了**等待队列机制**，来实现**阻塞进程的唤醒工作**，主要工作就两个：
- 进程进入内核态，发现资源没准备号，**主动休眠等待**
- 在**中断**中，资源准备好，**唤醒休眠的进程**。

等待队列定义在`include/linux/wait.h`中
### 等待队列 API 梳理
- **A. 核心数据结构**
  - ![alt text](../images/imx6ull-linux-阻塞与非阻塞-05-0306230232.png)
- **B. 初始化 (Initialization)**
  - ![alt text](../images/imx6ull-linux-阻塞与非阻塞-06-0306230232.png)
- **C. 入队与阻塞 (Wait Events) —— 最常用**
  - ![alt text](../images/imx6ull-linux-阻塞与非阻塞-07-0306230232.png)
- **D. 唤醒 (Wake Up)**
  - ![alt text](../images/imx6ull-linux-阻塞与非阻塞-08-0306230232.png)
### demo
**1. 设备体结构定义**
```c
struct timer_dev {
    /* ... 之前的成员 ... */
    wait_queue_head_t r_wait;  /* 定义等待队列头 */
    atomic_t releasekey;       /* 按键状态变量（原子操作更安全） */
};
```

**2. 在 init 函数中初始化**
```c
static int __init timer_init(void) {
    /* ... 之前的初始化 ... */
    init_waitqueue_head(&timerdev.r_wait); /* 初始化等待队列头 */
    atomic_set(&timerdev.releasekey, 0);   /* 初始设为无按键按下 */
    return 0;
}
```

**3. 在 read 函数中实现阻塞**
```c
static ssize_t timer_read(struct file *filp, char __user *buf, size_t cnt, loff_t *offt) {
    struct timer_dev *dev = (struct timer_dev *)filp->private_data;

    /* 1. 使用自动化宏进入休眠 
     * 条件为假 (0) 时休眠，条件为真 (1) 时苏醒并执行后续逻辑
     */
    if (wait_event_interruptible(dev->r_wait, atomic_read(&dev->releasekey))) {
        return -ERESTARTSYS; /* 如果是被信号唤醒的，返回错误告知系统重启调用 */
    }

    /* 2. 醒来后说明有数据了，执行 copy_to_user ... */
    atomic_set(&dev->releasekey, 0); /* 处理完后记得清除状态 */
    
    return 0;
}
```






**4. 在中断/定时器处理函数中唤醒**
```c
void timer_function(unsigned long arg) {
    struct timer_dev *dev = (struct timer_dev *)arg;
    
    /* 1. 更新按键状态 */
    atomic_set(&dev->releasekey, 1);

    /* 2. 唤醒等待该队列的进程 */
    wake_up_interruptible(&dev->r_wait); 
}
```
> - **不要在中断里调用 wait_event**：**中断**处理函数（Top Half）**绝不能休眠**。
> - 条件检查要严谨：wait_event 醒来后会重新检查 condition。如果多个进程在等同一个队列，**其中一个抢先处理了数据并把 condition 改回了 0**，其他进程会继续睡回去。
> - 信号处理：`wait_event_interruptible` 返回非 0 值表示是被信号（信号量、Ctrl+C等）**意外叫醒的**，驱动应该及时返回并处理这个异常

## 轮询
如果**用户进程**以**非阻塞方式**访问设备，设备**驱动**程序就要**提供非阻塞的处理方式**

前面我们说**非阻塞**，就是直接返回嘛，那么就是**轮询**了

`poll`, `epoll`, `select`可以用于**处理轮询**

**应用程序**通过 `select、epoll 或 poll` 函数来**查询设备是否可以操作**，如果**可以操作**的话**就从设备读取或者向设备写入数据**
> 原来我们while read，是不停的读，这里他是不停的查询是否可读。相当于不停的读是否可读的标志位。


当**应用程序**调用 `select、epoll 或 poll` 函数的时候**设备驱动程序中**的 `poll` 函数就会执行，因此**需要在设备驱动程序中编写 poll 函数**

> 所以，用户态的select,epoll,poll, 都是靠内核态的poll函数来实现的。

### 用户态的轮询api
#### select
![alt text](../images/imx6ull-linux-阻塞与非阻塞-09-0306230232.png)
![alt text](../images/imx6ull-linux-阻塞与非阻塞-10-0306230232.png)
![alt text](../images/imx6ull-linux-阻塞与非阻塞-11-0306230232.png)

可以看到，select其实可以通过超时时间的设置，来实现阻塞/非阻塞的轮询
> 我们这里说的**轮询**，本质上是**基于等待队列机制**的唤醒机制,是**阻塞等待** + **批量检查**，
> 
> **不是**我们用while循环的**主动轮询**

##### select底层实现机制
下面来看一下`select`的**底层实现机制**。

**用户态代码**
```c
fd_set readfds;
FD_ZERO(&readfds);
FD_SET(fd, &readfds);
struct timeval timeout = {1, 0}; // 1秒超时
int ret = select(fd+1, &readfds, NULL, NULL, &timeout);
```

**场景设定**
- **监听**：
  - `读集合`：设备 A（fd_a）、设备 B（fd_b）
  - `写集合`：设备 C（fd_c）
  - `异常集合`：无
- **超时**：1 秒
- 实际唤醒：300ms 时，设备 A 可读
---
**步骤 1：用户态→内核态，参数拷贝**
- `select` 是**系统调用**，会触发 `sys_select` **内核函数**；
- **内核**把用户态的 fd_set（监听的 fd 集合）、timeout **拷贝到内核空间**（避免用户态篡改）；
- 内核会先做**合法性检查**：fd 是否有效、是否超出进程的 fd 限制（默认 1024）。

---
**步骤 2：初始化 “等待队列”，挂起当前进程**
> 这是 `select` **不 “轮询” 的核心**：
- 内核为**当前进程**创建一个 `struct wait_queue_entry`（等待队列**项**）；
- **遍历用户监听的所有 fd**（这里是 fd），把这个等待队列项**挂到每个 fd 对应的等待队列**上；
  - 比如`串口 fd` 的等待队列，由**串口驱动**维护，当串口有数据时，驱动会唤醒这个队列上的所有进程；
- **内核修改当前进程的状态**为 TASK_INTERRUPTIBLE（可中断睡眠），并调用 schedule() 让出 CPU；
  - 此时进程不再占用 CPU，直到被唤醒。
---
**步骤 3：进程睡眠，等待唤醒**

> **进程睡眠**期间，CPU 去执行其他任务，直到以下任一事件发生：
- **有fd 就绪**：比如串口收到数据，**驱动**会调用 **wake_up() 唤醒**对应 fd 的**等待队列**，当前进程被唤醒；
- **超时**：内核有一个定时器，超时时间到后，定时器触发，唤醒当前进程；
- **信号打断**：比如进程收到 SIGINT 信号，也会被唤醒。

---

**步骤 4：进程被唤醒，检查 fd 状态**

进程被唤醒后，内核会做两件事：

- 把**进程的这个等待队列项**从**所有** fd 的**等待队列**中移除（避免重复唤醒）；
  - 前面我们一个进程的等待队列项，被加入到两个读，一个写的对应的驱动的等待队列里面了，现在要**全部清除掉**，**防止被重复唤醒**
- **一次性遍历所有监听的 fd**，检查每个 fd 的状态（可读 / 可写 / 异常）：
  - 内核通过 fd 对应的 file_operations 结构体里的 **poll 函数**（比如**串口驱动的 uart_poll**），获取 `fd` 的**就绪状态**；
  - 把就绪的 fd **标记到 fd_set** 中。
---
**步骤 5：计算超时剩余时间（可选）**

此时仍在内核态

如果是 “超时唤醒”，内核会更新 timeout 结构体，把剩余时间写回用户态（比如原本 1 秒超时，300ms 就被唤醒，用户态能拿到剩余的 700ms）；如果是 “fd 就绪唤醒”，

超时时间会被清空。

---

**步骤 6：内核态→用户态，结果返回**
- 内核把**更新后**的 `fd_set`（标记了就绪的 fd）、**返回值**（就绪 fd 数量 / 0/-1）**拷贝回用户态**；
- 用户态代码从 select 返回，**继续执行后续逻辑**（比如 判断哪个可读，read 读取数据）
  - 用户态代码继续执行，通过 `FD_ISSET(fd_a, &readfds)` 检查，发现 fd_a 可读，于是调用 `read(fd_a, ...)` 读取数据
---
**`select`的缺陷**：
![alt text](../images/imx6ull-linux-阻塞与非阻塞-12-0306230232.png)


#### poll
因为前面分析的select能够监视的fs的数量最大是1024，而且要遍历检查，所以开销太大。

因此，有了poll函数。

**poll函数和select本质上没有太大的差别**

`poll`函数**没有最大文件描述符的限制**



## poll
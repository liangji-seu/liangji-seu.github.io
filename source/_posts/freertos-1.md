---
title: freertos 基础实现
date: 2026-02-08 17:26:23
categories: [学习笔记, 嵌入式, RTOS] 
tags: [嵌入式, RTOS, freertos]
---


# Freertos 基础实现
## freertos 代码结构分析
![alt text](../images/21.1.png)
## stm32中，freertos内存分布预览
stm32f103zet6 rtos的内存分布
```c
[ 高地址 (High Address) ]  0x2001 0000 (SRAM 结束/64KB)
          |
          v
+------------------------------------------+
|          System Stack (MSP)              | <--- 栈顶(Top), 向下生长 ↓
| (用于中断服务 ISR、启动前的 main 函数)      |
+------------------------------------------+
|                (空闲区)                   |
+------------------------------------------+
|        FreeRTOS Heap (ucHeap[])          | <--- 这里的管理是源码阅读重点
|  +------------------------------------+  |
|  | [空闲堆内存] (Free Heap Block)      |  |
|  +------------------------------------+  |
|  | Task B Stack (任务B栈)              |  |
|  | Task B TCB (任务B控制块)            |  |
|  +------------------------------------+  |
|  | Task A Stack (任务A栈)              |  |
|  | Task A TCB (任务A控制块)            |  |
|  +------------------------------------+  |
+------------------------------------------+
|          .bss (未初始化的全局变量)         | <--- 包括上面的 ucHeap 数组
+------------------------------------------+
|          .data (已初始化的全局变量)         |
+------------------------------------------+
   [ 低地址 (Low Address) ]   0x2000 0000 (SRAM 起始)


----------------- 物理分界线 (SRAM vs Flash) -----------------


   [ 高地址 (High Address) ]  0x0808 0000 (Flash 结束/512KB)
          |
+------------------------------------------+
|          .rodata (只读常量)               |
+------------------------------------------+
|          .text (程序代码/FreeRTOS源码)     |
+------------------------------------------+
|          Vector Table (中断向量表)        |
+------------------------------------------+
   [ 低地址 (Low Address) ]   0x0800 0000 (Flash 起始)
```

## (前置知识)，CM3中断
rtos本质上是要依赖mcu的中断来实现的，所以有必要先复习一下cm3内核的中断相关的知识了。

> **中断**是 CPU 的一种常见特性，中断一般由硬件产生，当中断发生后，会中断 CPU 当前正
在执行的程序而跳转到中断对应的服务程序种去执行
>
>ARM Cortex-M 内核的 MCU 具有一个用于中断管理的嵌套向量中断控制器（**NVIC**，全称：Nested vectored interrupt controller）。

STM32的NVIC 最多支持**256个中断源**（`16个系统中断` + `240个外部中断`）

(zet6只用到了10个系统中断 + 60个外部中断)

**1. 外部中断优先级配置**

NVIC这个外设，在芯片定义层的结构体定义：我们主要使用`IP`，来设置`外部中断优先级`，**一共240个字节，刚好对应240个外部中断**
``` c
typedef struct
{
 __IOM uint32_t ISER[8U]; /* 中断使能寄存器 */
 uint32_t RESERVED0[24U];
 __IOM uint32_t ICER[8U]; /* 中断除能寄存器 */
 uint32_t RSERVED1[24U];
 __IOM uint32_t ISPR[8U]; /* 中断使能挂起寄存器 */
 uint32_t RESERVED2[24U];
 __IOM uint32_t ICPR[8U]; /* 中断除能挂起寄存器 */
 uint32_t RESERVED3[24U];
 __IOM uint32_t IABR[8U]; /* 中断有效位寄存器 */
 uint32_t RESERVED4[56U];
 __IOM uint8_t IP[240U]; /* 中断优先级寄存器 */
 uint32_t RESERVED5[644U];
 __OM uint32_t STIR; /* 软件触发中断寄存器 */
} NVIC_Type;
```

IP的每一个字节，对应一种外部中断的优先级，但是**8位只用到了高4位**（里面又可以**再细分为抢占优先级+子优先级**），一般设置成抢占式4位，子优先级不用，这样最简单。

**2. 系统中断优先级配置**

`系统中断优先级配置`，由独立的`SHPR1、SHPR2、SHPR3`来进行配置，不是通过NVIC（因为不是嵌套嘛）。
里面，比较重要的就是`PendSV`中断和 `SysTick` 中断，`SVCall` 中断优先级

**3. 三个中断屏蔽寄存器**

1. PRIMASK
   1. 屏蔽除 NMI 和 HardFault 外的所有异常和中断，
2. FAULTMASK 
   1. 屏蔽除 NMI 外的所有异常和中断
3. BASEPRI
   1. 中断优先级`低于` BASEPRI `阈值`的中断就都会被屏蔽掉

我们主要关注的是BASEPRI这个
> 除了NMI 和 hardfault， reset这些中断是无法设置优先级的外
> 
> 剩下的所有中断（系统中断（由CM3自己受理） + 外部中断（由st的NVIC受理）），他们对外都是一致的，
> 也就是都可以被上面3个屏蔽寄存器屏蔽。
>
> 也就意味着freertos可以通过设置systick中断+pendSV中断（系统中断）的优先级为15（最低），
> 同时设置阈值5-15为rtos可控制中断，在进入临界区的时候，就可以关中断+关闭任务调度了。

**总结**：

`中断的“两个家族”`

在 Cortex-M3 内核中，所有的中断统称为“异常（Exception）”，但管理上分为两派：

- 系统异常 (System Exceptions)： 由 ARM 内核定义（如 `SVC`, `PendSV`, `SysTick`），由 `SCB `寄存器管理。

- 外部中断 (External Interrupts/IRQs)： 由芯片厂家（如 ST）定义（如 UART, Timer, DMA），由 `NVIC` 寄存器管理。

> 统一规则： 无论属于哪个家族，优先级逻辑是通用的——数字越小，优先级越高。**对外地位等价**

` 核心机制`：

- BASEPRI 与“围栏”BASEPRI 寄存器： 是 FreeRTOS 实现临界区保护的“秘密武器”。
- **工作原理**： 当 RTOS 进入临界区，会将 BASEPRI 设为 0x50。此时，硬件会自动屏蔽掉所有优先级 $\ge 5$ 的中断。
- 系统心脏： **SysTick 和 PendSV 必须被设为最低优先级 (15)**。这样它们永远不会打断硬件中断。它们在临界区内会**被一起屏蔽**，保证任务切换时内核数据（如就绪列表）的绝对安全。
- API 调用禁区： 如果在 0-4 级中断里调用了 API，会破坏 RTOS 内部链表的原子性，导致系统崩溃（通常卡在 configASSERT）。


## A. freertos 中断配置
根据freertos的框图架构，可以看出，freertos，利用NVIC和SHPR寄存器来配置内核中断+外部中断的优先级，

**pendSV 中断和systick中断优先级配置**

在port.c中
``` c
//在port.c中，定义好pendSV, systick这两个内核中断的优先级
#define portNVIC_PENDSV_PRI                   ( ( ( uint32_t ) configKERNEL_INTERRUPT_PRIORITY ) << 16UL )
#define portNVIC_SYSTICK_PRI                  ( ( ( uint32_t ) configKERNEL_INTERRUPT_PRIORITY ) << 24UL )

//这个才是实际的启动调度器，调度器内部会开始设置任务调度所需的任务的优先级。
BaseType_t xPortStartScheduler( void )
{
 /* ... */
 
 /* 设置 PendSV 和 SysTick 的中断优先级为最低中断优先级 */
 portNVIC_SHPR3_REG |= portNVIC_PENDSV_PRI;
 portNVIC_SHPR3_REG |= portNVIC_SYSTICK_PRI;
 
 /* ... */
}

//configKERNEL_INTERRUPT_PRIORITY 这个在FreeRTOSConfig.h中定义，内核中断优先级为15
```

**开关中断的接口**

``` c

//portmacro.h 中定义实际用BASEPRI来控制可控制的中断
    #define portDISABLE_INTERRUPTS()                  vPortRaiseBASEPRI()
    #define portENABLE_INTERRUPTS()                   vPortSetBASEPRI( 0 )
```

**freertos进出临界区api分两套**：
1. 普通任务进出临界区：
   1. 可嵌套
   2. 无需备份之前的basepri
2. 中断进出临界区：
   1. 不可以嵌套
   2. 需要备份之前的basepri



## B. freertos 任务
在传统的裸机开发中，一般是一个while大循环，然后里面顺序的执行函数（后台），当中断来临，这时候进入中断服务程序（前台）。

但是这在大型嵌入式系统设计中，实时性严重不足

**多任务系统**的多个任务可以“`同时`”运行，是从宏观的角度而言的，对于单核
的 CPU 而言，CPU 在同一时刻只能够处理一个任务

![alt text](../images/21.2.png)
多任务系统的**任务也是具有优先级的**，高优先
级的任务可以像中断的抢占一样，抢占低优先级任务的 CPU 使用权

**任务调度**则分为`抢占式调度`+`时间片轮询`


**任务的状态**
1. `运行态`（正在占用cpu）
2. `就绪态`（排队等待执行）（当前有同或更高优先级的任务）
3. `阻塞态`（延时一段时间`vTaskDelay()`；等待外部事件发生(超时时间)）
4. `挂起态`（通过函数 `vTaskSuspend()`和函数 `vTaskResums()`进入和退出挂起态）
![alt text](../images/21.3.png)


**任务优先级**

每一个任务都被分配一个`0~(configMAX_PRIORITIES-1)`的任务优先级，宏 `configMAX_PRIORITIES` 在 `FreeRTOSConfig.h`文件中定义

宏 `configMAX_PRIORITIES 的值不能超过 32`,原因是freertos里面有选择是否用硬件计算前导0指令，最大支持32位

任务优先级**高低**与其对应的优先级数值，是成**正比的**

![alt text](../images/21.4.png)

### 任务task
在rtos中，task由TCB和栈空间组成。

`TCB结构体`如下：

``` c
typedef struct tskTaskControlBlock
{
 /* 指向任务栈栈顶的指针 */
 volatile StackType_t * pxTopOfStack;
 
#if ( portUSING_MPU_WRAPPERS == 1 )
 /* MPU 相关设置 */
 xMPU_SETTINGS xMPUSettings;
#endif
 
 /* 任务状态列表项 */
 ListItem_t xStateListItem;
 /* 任务等待事件列表项 */
 ListItem_t xEventListItem;
 /* 任务的任务优先级 */
 UBaseType_t uxPriority;
 /* 任务栈的起始地址 */
 StackType_t * pxStack;
 /* 任务的任务名 */
 char pcTaskName[ configMAX_TASK_NAME_LEN ];
 
#if ( ( portSTACK_GROWTH > 0 ) || ( configRECORD_STACK_HIGH_ADDRESS == 1 ) )
 /* 指向任务栈栈底的指针 */
 StackType_t * pxEndOfStack;
#endif
 
#if ( portCRITICAL_NESTING_IN_TCB == 1 )
 /* 记录任务独自的临界区嵌套次数 */
 UBaseType_t uxCriticalNesting;
#endif
 
#if ( configUSE_TRACE_FACILITY == 1 )
/* 由系统分配（每创建一个任务，值增加一），分配任务的值都不同，用于调试 */
 UBaseType_t uxTCBNumber;
 /* 由函数 vTaskSetTaskNumber()设置，用于调试 */
 UBaseType_t uxTaskNumber;
#endif
 
#if ( configUSE_MUTEXES == 1 )
 /* 保存任务原始优先级，用于互斥信号量的优先级翻转 */
 UBaseType_t uxBasePriority;
 /* 记录任务获取的互斥信号量数量 */
 UBaseType_t uxMutexesHeld;
#endif
 
#if ( configUSE_APPLICATION_TASK_TAG == 1 )
 /* 用户可自定义任务的钩子函数用于调试 */
 TaskHookFunction_t pxTaskTag;
#endif
 
#if ( configNUM_THREAD_LOCAL_STORAGE_POINTERS > 0 )
 /* 保存任务独有的数据 */
 void *pvThreadLocalStoragePointers[configNUM_THREAD_LOCAL_STORAGE_POINTERS];
#endif
 
#if ( configGENERATE_RUN_TIME_STATS == 1 )
 /* 记录任务处于运行态的时间 */
 configRUN_TIME_COUNTER_TYPE ulRunTimeCounter;
#endif
 
#if ( configUSE_NEWLIB_REENTRANT == 1 )
 /* 用于 Newlib */
 struct _reent xNewLib_reent;
#endif
 
#if ( configUSE_TASK_NOTIFICATIONS == 1 )
 /* 任务通知值 */
 volatile uint32_t ulNotifiedValue[ configTASK_NOTIFICATION_ARRAY_ENTRIES ];
 /* 任务通知状态 */
 volatile uint8_t ucNotifyState[ configTASK_NOTIFICATION_ARRAY_ENTRIES ];
#endif
 
#if ( tskSTATIC_AND_DYNAMIC_ALLOCATION_POSSIBLE != 0 )
 /* 任务静态创建标志 */
 uint8_t ucStaticallyAllocated;
#endif
 
#if ( INCLUDE_xTaskAbortDelay == 1 )
 /* 任务被中断延时标志 */
 uint8_t ucDelayAborted;
#endif
 
#if ( configUSE_POSIX_ERRNO == 1 )
 /* 用于 POSIX */
 int iTaskErrno;
#endif
} tskTCB;

/* The old tskTCB name is maintained above then typedefed to the new TCB_t name
 * below to enable the use of older kernel aware debuggers. */
typedef tskTCB TCB_t;

typedef struct tskTaskControlBlock * TaskHandle_t;
```

可以理解为，一个TCB（任务控制块），就是一个`任务的本体`。
一个任务TCB，里面包含了比如任务栈空间`栈顶的指针`，`优先级`，`临界区的嵌套次数`等等。

> 可以看到**所谓的任务句柄**，实际上就是**TCB内存块的指针**。

而**栈空间**，是和一个任务在运行过程中，和函数的局部变量，函数调用的现场和返回地址有关的，所以是在**创建过程**中开辟的一段内存。

#### task创建

`通过静态创建，可以很清晰的看出一个任务的内存分布和内部结构。`

**1. 静态创建**
``` c
#if ( configSUPPORT_STATIC_ALLOCATION == 1 )

    TaskHandle_t xTaskCreateStatic( TaskFunction_t pxTaskCode,
                                    const char * const pcName, 
                                    const uint32_t ulStackDepth,// 栈空间长度（StackType_t（4字节） 的个数）
                                    void * const pvParameters,
                                    UBaseType_t uxPriority,
                                    StackType_t * const puxStackBuffer,
                                    StaticTask_t * const pxTaskBuffer )
    {
        TCB_t * pxNewTCB; //先声明一个指向TCB任务本体内存区域的指针
        TaskHandle_t xReturn;

        configASSERT( puxStackBuffer != NULL ); //校验参数：任务栈空间的起始地址
        configASSERT( pxTaskBuffer != NULL );//校验参数：TCB内存起始地址

        #if ( configASSERT_DEFINED == 1 )
            {
               //校验开辟的TCB内存大小是否符合sizeof(TCB_t)
                volatile size_t xSize = sizeof( StaticTask_t );
                configASSERT( xSize == sizeof( TCB_t ) );
                ( void ) xSize; /* Prevent lint warning when configASSERT() is not used. */
            }
        #endif /* configASSERT_DEFINED */

        if( ( pxTaskBuffer != NULL ) && ( puxStackBuffer != NULL ) )
        {
            //指定这块内存作为TCB，记录下他的起始地址
            pxNewTCB = ( TCB_t * ) pxTaskBuffer; 
            //在这块内存（TCB）中记录，属于这个任务的栈空间的起始地址
            pxNewTCB->pxStack = ( StackType_t * ) puxStackBuffer;

            #if ( tskSTATIC_AND_DYNAMIC_ALLOCATION_POSSIBLE != 0 ) 
                    pxNewTCB->ucStaticallyAllocated = tskSTATICALLY_ALLOCATED_STACK_AND_TCB;
                }
            #endif /* tskSTATIC_AND_DYNAMIC_ALLOCATION_POSSIBLE */

            //初始化这块TCB，把其他剩余的TCB参数补全，并获得句柄
            prvInitialiseNewTask( pxTaskCode, pcName, ulStackDepth, pvParameters, uxPriority, &xReturn, pxNewTCB, NULL );

            //将这个新task（TCB内存空间的指针）加入就绪链表
            prvAddNewTaskToReadyList( pxNewTCB );
        }
        else
        {
            xReturn = NULL;
        }

         //返回task句柄
        return xReturn;
    }

#endif /* SUPPORT_STATIC_ALLOCATION */
```



**2. 动态创建**

```c
#if ( configSUPPORT_DYNAMIC_ALLOCATION == 1 )

    BaseType_t xTaskCreate( TaskFunction_t pxTaskCode,
                            const char * const pcName, 
                            const configSTACK_DEPTH_TYPE usStackDepth,//直接就是表示任务栈空间的大小（字）
                            void * const pvParameters,
                            UBaseType_t uxPriority,
                            TaskHandle_t * const pxCreatedTask )//最后这个参数返回自动创建的任务的TCB的地址
    {
        TCB_t * pxNewTCB;
        BaseType_t xReturn;

        //portmacro.h中定义#define portSTACK_GROWTH          ( -1 )
        //表示栈是向下增长的。

        #if ( portSTACK_GROWTH > 0 )
            {
                //忽略
            }
        #else /* portSTACK_GROWTH */
            {
                StackType_t * pxStack;

                // 用port里面绑定的heap_4.c中的方法，分配栈空间
                pxStack = pvPortMallocStack( ( ( ( size_t ) usStackDepth ) * sizeof( StackType_t ) ) ); 

                if( pxStack != NULL )
                {
                    //开始开辟TCB的内存区域
                    pxNewTCB = ( TCB_t * ) pvPortMalloc( sizeof( TCB_t ) ); 

                    if( pxNewTCB != NULL )
                    {
                        //在这个TCB中记录好该任务的栈空间起始地址
                        pxNewTCB->pxStack = pxStack;
                    }
                    else
                    {
                        vPortFreeStack( pxStack );
                    }
                }
                else
                {
                    pxNewTCB = NULL;
                }
            }
        #endif /* portSTACK_GROWTH */

        if( pxNewTCB != NULL )
        {
            #if ( tskSTATIC_AND_DYNAMIC_ALLOCATION_POSSIBLE != 0 )
                {

                    pxNewTCB->ucStaticallyAllocated = tskDYNAMICALLY_ALLOCATED_STACK_AND_TCB;
                }
            #endif /* tskSTATIC_AND_DYNAMIC_ALLOCATION_POSSIBLE */

            //和静态创建一样，开始初始化这个新的任务TCB，并返回该TCB的地址
            prvInitialiseNewTask( pxTaskCode, pcName, ( uint32_t ) usStackDepth, pvParameters, uxPriority, pxCreatedTask, pxNewTCB, NULL );
            //将该TCB的地址加入就绪任务链表
            prvAddNewTaskToReadyList( pxNewTCB );
            xReturn = pdPASS;
        }
        else
        {
            xReturn = errCOULD_NOT_ALLOCATE_REQUIRED_MEMORY;
        }

        return xReturn;
    }

#endif /* configSUPPORT_DYNAMIC_ALLOCATION */
```























## 调度实现
## 软件定时
## 通信相关
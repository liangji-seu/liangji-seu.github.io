---
title: stm32 sys层实现
date: 2026-02-12 19:02:21
categories: [学习笔记, 嵌入式, MCU] 
tags: [嵌入式, mcu, stm32]
---

# sys层
这一层，主要剖析一下底层核心驱动函数, 基本上要访问一个系统的最小驱动就是这三个。
## delay
### 原理
首先，stm32里面的delay 延时的编程思想：

`CM3 内核`处理器，内部包含了`一个 SysTick 定时器`
> SysTick 是一个 24 位的**向下递减**的计数定时器，当计数值减到 0 时，将从 RELOAD 寄存器中自动重装载定时初值，开始新一轮计数。只要不把它在 SysTick 控制及状态寄存器中的使能位清除，就永不停息

所以，这里的delay延时，依赖我们的**第一个外设**：CM3内部的一个**systick的定时器**。

利用 `STM32的内部 SysTick` 来实现延时的，这样既`不占用中断`，也`不占用系统定时器`。

这里说的**不占用中断**的意思是**不开定时器中断**：

> SysTick 是内核外设，它确实有一个专属的异常向量（Exception），即 SysTick_Handler。但在实现 delay 函数时，市面上常见的做法（尤其是正点原子、野火等教程）确实是不开启中断的。

这里不占用中断的意思是：**不进入中断服务函数（ISR）**
```c
                // startup.S 中，是有systick中断的处理函数的
                DCD     SysTick_Handler            ; SysTick Handler
```

### 实现
ucos/freertos 运行需要一个**系统时钟节拍**（类似“心跳”），而这个节拍是固定的（由 OS_TICKS_PER_SEC 宏定义设置），比如要求 **5ms 一次**。

一般是由 **SysTick 来提供这个节拍**，也就是 SysTick要设置为 `5ms 中断一次`，为 ucos 提供时钟节拍，而且这个时钟一般是不能被打断的（否则就不准了）。

> systick定时器，是一个外设，给定主频sysclk时钟，设置技术周期，就可以实现节拍中断

当你实现了系统节拍定时中断后，systick 不能再被随意更改，如果我们还想利用 systick 来做 delay_us 或者 delay_ms 的延时，就必须想点办法了，这里我们利用的是**时钟摘取法**。

> delay_us 为例, 
>
> `sysclk = 72Mhz`, 输入systick定时器，计数`分频`（1/8）得到 `9Mhz的systick信号`。那么一个systick脉冲周期 = （1/9）us. 
>
> 此时如果要delay_us(50), 一直统计 systick 的计数变化，直到数到（50 * 9）， 那么就是50us

> 优点：只是抓取 SysTick 计数器的变化，并不需要修改 SysTick 的任何状态，完全不影响 SysTick 作为 UCOS时钟节拍的功能
> 
> 缺点：占用cpu

#### delay_init()
delay_init(72Mhz), 意味着，systick的输入是72Mhz，**systick计数值减少72，经过1us**
```c
//main.c
    delay_init(72);                         /* 延时初始化 */


static uint32_t g_fac_us = 0;       /* us延时倍乘数 */
 
// sysclk = 72 (Mhz), g_fac_us = 72,即数72下，算1us
void delay_init(uint16_t sysclk)
{
#if SYS_SUPPORT_OS                                      /* 如果需要支持OS */
    uint32_t reload;
#endif

    g_fac_us = sysclk;                                  /* 由于在HAL_Init中已对systick做了配置，所以这里无需重新配置 */
    //g_fac_us = 72,即数72下，算1us, 1us时基计数值


#if SYS_SUPPORT_OS                                      /* 如果需要支持OS. */
    reload = sysclk;                                    /* 每秒钟的计数次数 单位为M */
    reload *= 1000000 / delay_ostickspersec;            /* 根据delay_ostickspersec设定溢出时间,reload为24位
                                                         * 寄存器,最大值:16777216,在168M下,约合0.09986s左右
                                                         */
    g_fac_ms = 1000 / delay_ostickspersec;              /* 代表OS可以延时的最少单位 */
    SysTick->CTRL |= 1 << 1;                            /* 开启SYSTICK中断 */
    SysTick->LOAD = reload;                             /* 每1/delay_ostickspersec秒中断一次 */
    SysTick->CTRL |= 1 << 0;                            /* 开启SYSTICK */
#endif 
}
```

#### delay_us()
> 可见，是占用cpu资源的等待，不停的去读systick->val
```c
//nus = 要延时多少us
void delay_us(uint32_t nus)
{
    uint32_t ticks;
    uint32_t told, tnow, tcnt = 0;
    uint32_t reload = SysTick->LOAD;        /* LOAD的值 */

    //需要数多少节拍
    ticks = nus * g_fac_us;                 /* 需要的节拍数 */
    
#if SYS_SUPPORT_OS                          /* 如果需要支持OS */
    delay_osschedlock();                    /* 锁定 OS 的任务调度器 */
#endif

    told = SysTick->VAL;                    /* 刚进入时的计数器值 */
    while (1)
    {
        tnow = SysTick->VAL;
        if (tnow != told)
        {
            if (tnow < told)
            {
                tcnt += told - tnow;        /* 这里注意一下SYSTICK是一个递减的计数器就可以了 */
            }
            else
            {
                tcnt += reload - tnow + told;
            }
            told = tnow;
            if (tcnt >= ticks) 
            {
                break;                      /* 时间超过/等于要延迟的时间,则退出 */
            }
        }
    }

#if SYS_SUPPORT_OS                          /* 如果需要支持OS */
    delay_osschedunlock();                  /* 恢复 OS 的任务调度器 */
#endif 

}
```

> 可见，这种最基础的延时，就是不停的读systick的计数累计变化，来实现延时的。所以如果支持OS，他需要锁住调度。
>
> 当 OS 还未运行的时候，我们的 delay_ms 就是直接由 delay_us 实现的，OS 下的 delay_us
可以实现很长的延时（**达到 53 秒**）而不溢出！，所以放心的使用 delay_us 来实现 delay_ms，不
过由于 delay_us 的时候，任务调度被上锁了，所以还是建议不要用 delay_us 来延时很长的时间，否则影响整个系统的性能

总结
![alt text](../images/24.1.png)


>在**没有os**的情况下，是**不需要systick中断的**，

>但是如果**有rtos**，则必须要systick中断来提供系统节拍进行调度
## sys

`sys_nvic_set_vector_table`()
设置中断向量表的偏移（VTOR）
```c
/**
 * @brief       设置中断向量表偏移地址
 * @param       baseaddr: 基址
 * @param       offset: 偏移量(必须是0, 或者0X100的倍数)
 * @retval      无
 */
void sys_nvic_set_vector_table(uint32_t baseaddr, uint32_t offset)
{
    /* 设置NVIC的向量表偏移寄存器,VTOR低9位保留,即[8:0]保留 */
    SCB->VTOR = baseaddr | (offset & (uint32_t)0xFFFFFE00);
}
```
`sys_stm32_clock_init`()
设置从时钟源到系统时钟sysclk，到所有外设总线时钟
```c
/**
 * @brief       系统时钟初始化函数
 * @param       plln: PLL倍频系数(PLL倍频), 取值范围: 2~16
                中断向量表位置在启动时已经在SystemInit()中初始化
 * @retval      无
 */
void sys_stm32_clock_init(uint32_t plln)
{
    HAL_StatusTypeDef ret = HAL_ERROR;
    RCC_OscInitTypeDef rcc_osc_init = {0};
    RCC_ClkInitTypeDef rcc_clk_init = {0};

    rcc_osc_init.OscillatorType = RCC_OSCILLATORTYPE_HSE;       /* 选择要配置HSE */
    rcc_osc_init.HSEState = RCC_HSE_ON;                         /* 打开HSE */
    rcc_osc_init.HSEPredivValue = RCC_HSE_PREDIV_DIV1;          /* HSE预分频系数 */
    rcc_osc_init.PLL.PLLState = RCC_PLL_ON;                     /* 打开PLL */
    rcc_osc_init.PLL.PLLSource = RCC_PLLSOURCE_HSE;             /* PLL时钟源选择HSE */
    rcc_osc_init.PLL.PLLMUL = plln;                             /* PLL倍频系数 */
    ret = HAL_RCC_OscConfig(&rcc_osc_init);                     /* 初始化 */

    if (ret != HAL_OK)
    {
        while (1);                                              /* 时钟初始化失败，之后的程序将可能无法正常执行，可以在这里加入自己的处理 */
    }

    /* 选中PLL作为系统时钟源并且配置HCLK,PCLK1和PCLK2*/
    rcc_clk_init.ClockType = (RCC_CLOCKTYPE_SYSCLK | RCC_CLOCKTYPE_HCLK | RCC_CLOCKTYPE_PCLK1 | RCC_CLOCKTYPE_PCLK2);
    rcc_clk_init.SYSCLKSource = RCC_SYSCLKSOURCE_PLLCLK;        /* 设置系统时钟来自PLL */
    rcc_clk_init.AHBCLKDivider = RCC_SYSCLK_DIV1;               /* AHB分频系数为1 */
    rcc_clk_init.APB1CLKDivider = RCC_HCLK_DIV2;                /* APB1分频系数为2 */
    rcc_clk_init.APB2CLKDivider = RCC_HCLK_DIV1;                /* APB2分频系数为1 */
    ret = HAL_RCC_ClockConfig(&rcc_clk_init, FLASH_LATENCY_2);  /* 同时设置FLASH延时周期为2WS，也就是3个CPU周期。 */

    if (ret != HAL_OK)
    {
        while (1);                                              /* 时钟初始化失败，之后的程序将可能无法正常执行，可以在这里加入自己的处理 */
    }
}

```
## uart
这个单独一章节讲
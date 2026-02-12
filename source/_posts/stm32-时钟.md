---
title: stm32 时钟
date: 2025-12-24 23:14:45
categories: [学习笔记, 嵌入式, MCU] 
tags: [嵌入式, mcu, stm32]
---
# stm32 时钟系统

首先肯定得有时钟系统，stm32f103的时钟系统比较复杂，不像简单的51，就一个系统时钟解决一切。stm32主频可到`72Mhz`，但是不是所有的外设都需要这么高的时钟。有些如看门狗以及 RTC 只需要`几十 kHZ` 的时钟即可

同一个电路，`时钟越快功耗越大`，同时抗电磁干扰能力也会越弱，所以对于较为复杂的 MCU 一般
都是采取`多时钟源`的方法来解决这些问题

所以必须得搞清楚：`时钟源有哪些`，`时钟树的线路匹配`（时钟信号的传递）

外设非常的多，为了`保持低功耗工作`，STM32 的主控`默认不开启这些外设功能`。这个`功能开关`在 STM32主控中也就是`各个外设的时钟`。

> 所以`时钟`就是`外设的开关`
>


## 4个时钟源

STM32F1，`输入时钟源`（Input Clock）主要包括 `HSI`(内部高速)，`HSE`（外部高速），`LSI`（内部低速），`LSE`（外部低速）

`外部时钟源`就是从`外部`通过**接晶振**的方式获取时钟源，其中 HSE 和 LSE 是外部时钟源

`内部时钟源`，芯片**上电即可产生**，不需要借助外部电路

下面详细说一下这4个时钟源：
1. HSE（外部高速）
   1. 外接`石英`、陶瓷瓷谐振器，频率为 4MHz~16MHz。本开发板使用的是 `8MHz`
2. LSE (外部低速)
   1. 外接 `32.768kHz` 石英晶体，主要作用于 RTC 的时钟源
> 可见，外部时钟，全部都是石英

3. HSI（内部高速）
   1. `内部 RC `振荡器产生，频率为 `8MHz`
4. LSI(内部低速)
   1. `内部 RC` 振荡器产生，频率为 `40kHz`，可作为`独立看门狗`的时钟源

>芯片**上电**时默认由**内部的 HSI 时钟启动** (8Mhz)，如果用户进行了硬件和软件的配置，芯片才会根据`用户配置`调试尝试`切换到对应的外部时钟源`

## 锁相环pll

作用：**输入时钟净化**和**倍频**

![alt text](../images/23.2.png)

所以，要实现 `72MHz` 的`主频率` `SYSCLK`，因为默认高速时钟是8Mhz, 所以pll倍频系数要为9

## 系统时钟 sysclk
以上，介绍了时钟源，倍频pll，接下来就得到了我们的**系统时钟sysclk**

**系统时钟 SYSCLK 为整个芯片提供了时序信号**

![alt text](../images/23.3.png)

系统时钟为以下提供时钟信号：
1. 外设总线时钟
2. 内核时钟
3. 等等，均由sysclk分频得到。


## 实验

该实验，就是让stm32工作在系统时钟sysclk = 72Mhz下。

之前讲到，内核上电后开始执行reset_handler, 里面有两个环节:
1. SystemInit
   1. 配置外部sram（没用到）
   2. 重定向ivt到内部ram（没用到）
2. main

所以我们主要看main干了些什么

```c
int main(void)
{
    uint8_t key;

    HAL_Init();                             /* 初始化HAL库 */
    sys_stm32_clock_init(RCC_PLL_MUL9);     /* 设置时钟, 72Mhz */
    delay_init(72);                         /* 延时初始化 */
    //......
```

可以看到就直接在CM3用内部8M时钟的情况下，就直接跳转到main执行了。

所以我们是在main里面重新设置时钟，配置主频为72Mhz的。

先看一下`sys_stm32_clock_init`这个函数

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
干了两件事：

1. 配置 `PLL = 9倍频` 相关参数确定系统时钟`SYSCLK = 72Mhz`
2. 配置了 `AHB`、`APB1` 和 `APB2` 的分频系数，也就是确定了 HCLK，PCLK1和 PCLK2 的时钟值

```c
SYSCLK(系统时钟) =72MHz
PLL 主时钟 =72MHz
AHB 总线时钟（HCLK=SYSCLK/1） =72MHz
APB1 总线时钟（PCLK1=HCLK/2） =36MHz
APB2 总线时钟（PCLK2=HCLK/1） =72MHz
```

如果要打开某个外设：

上一节我们讲解了时钟系统配置步骤。在`配置好时钟系统之后`，如果我们要`使用某些外设`，例如 GPIO，ADC 等，我们还要`使能这些外设时钟`。

这里大家必须注意，如果在使用外设之前没有使能外设时钟，这个外设是不可能正常运行的。

> STM32 的外设时钟使能是在 `RCC 相关寄存器中配置`的

**HAL 库中**，外设时钟使能操作都是在 RCC 相关固件库文件头文件`STM32F1xx_hal_rcc.h` 定义的. 每个**外设的时钟使能**，都通过**宏**来实现

![alt text](../images/23.4.png)

> 我们只需要在我们的用户程序中**调用宏定义标识符**就可以实现 GPIOA 时钟使能。
> 
> 禁止外设时钟使用方法和使能外设时钟非常类似
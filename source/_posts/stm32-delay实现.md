---
title: stm32 delay实现
date: 2025-12-24 23:15:03
categories: [学习笔记, 嵌入式, MCU] 
tags: [嵌入式, mcu, stm32]
---
# stm32 计时
1. hal_init()里面HAL_InitTick（）会设置好CM3内部的systick模块的时钟源头,为sysclk的/8，和节拍中断优先级。
2. stm32 在设置好时钟树之后,sysclk = 72MHZ
3. delay的初始化delay_init()，也就是设置按照当前的sysclk来说，计算得出1us要多少个时钟周期计数。或运行OS，则设置好LOAD为系统节拍（之后就不会变了）
4. 之后就可以开始使用delay_us, delay_ms这些延时函数了
## systick模块，sysclk时钟源 和 tick节拍
![alt text](../images/12.1.png)


systick是一个模块，是CM3内部的固有硬件，负责给整个系统提供一个简易的定时。

![alt text](../images/12.2.png)

1次节拍 = LOAD次 计数
1次计数 = 1/（9M）s 或者 1/（72M）s
       = 1/9  us  或者  1/72   us
    

## delay_us
### 无OS
``` c
void delay_us(uint32_t nus)
{
uint32_t temp;
SysTick->LOAD = nus * g_fac_us;
/* 时间加载 */
SysTick->VAL = 0x00;
/* 清空计数器 */
SysTick->CTRL |= 1 << 0 ;
/* 开始倒数 */
do
{
temp = SysTick->CTRL;
} while ((temp & 0x01) && !(temp & (1 << 16)));
/* CTRL.ENABLE 位必须为 1, 并等待时间到达 */
SysTick->CTRL &= ~(1 << 0) ;
SysTick->VAL = 0X00;
/* 关闭 SYSTICK */
/* 清空计数器 */
}
```
直接设置一个节拍的LOAD计数 =  总共的计数（根据n us * g_per_us）

通过读systick是否完成LOAD的计数来判断

### 有OS

``` c
void delay_us(uint32_t nus)
{
uint32_t ticks;
uint32_t told, tnow, tcnt = 0;
uint32_t reload;
reload = SysTick->LOAD;
/* LOAD 的值 */
ticks = nus * g_fac_us;
/* 需要的节拍数 */
delay_osschedlock();
/* 阻止 OS 调度，防止打断 us 延时 */
told = SysTick->VAL;
/* 刚进入时的计数器值 */
while (1)
{
tnow = SysTick->VAL;
if (tnow != told)
{
if (tnow < told)
{
tcnt += told - tnow; /* 这里注意一下 SYSTICK 是一个递减的计数器就可以了 */
}
else
{
tcnt += reload - tnow + told;
}
told = tnow;
if (tcnt >= ticks) break;
/* 时间超过/等于要延迟的时间,则退出. */
}
};
delay_osschedunlock();
/* 恢复 OS 调度 */
}
```
通过数总的计数，不能修改systick的LOAD。


## delay_ms
### 无OS

``` c
void delay_ms(uint16_t nms)
{
/*这里用 1000,是考虑到可能有超频应用,如 128Mhz 时,delay_us 最大只能延时 1048576us 左右*/
uint32_t repeat = nms / 1000;
uint32_t remain = nms % 1000;
while (repeat)
{
delay_us(1000 * 1000);
repeat--;
}
if (remain)
{
delay_us(remain * 1000);
}
/* 利用 delay_us 实现 1000ms 延时 */
/* 利用 delay_us, 把尾数延时(remain ms)给做了 */
}
```

### 有OS
``` c
void delay_ms(uint16_t nms)
{
/* 如果 OS 已经在跑了,并且不是在中断里面(中断里面不能任务调度) */
if (delay_osrunning && delay_osintnesting == 0)
{
if (nms >= g_fac_ms)
/* 延时的时间大于 OS 的最少时间周期 */
{
delay_ostimedly(nms / g_fac_ms);
/* OS 延时 */
}
nms %= g_fac_ms;
/* OS 已经无法提供这么小的延时了,采用普通方式延时 */
}
/* 普通方式延时 */
delay_us((uint32_t)(nms * 1000));
}
```
大于OS延时的用OS内部的延时，不足的部分，用delay_us来凑。不过此时任务无法调度，因为OS的delay_us下锁调度。
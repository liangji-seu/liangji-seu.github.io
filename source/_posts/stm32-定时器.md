---
title: stm32 定时器
date: 2025-12-24 23:14:25
categories: [学习笔记, 嵌入式, MCU] 
tags: [嵌入式, mcu, stm32]
---
# STM32 定时器
## 硬件总线分布
APB1：TIM2-7
APB2：TIM1, TIM8

## 分类
1. 2个基本定时器（TIM6, TIM7）
2. 4个通用定时器（TIM2-5）
3. 2个高级控制定时器（TIM1, TIM8）

这些定时器属于独立外设

## 基本定时器（6，7）
16位自动重载**递增**计数器

16位可编程分频器(倍频
![alt text](../images/8.1.png)

预分频器-影子寄存器：
    预分频器作为缓冲作用，等更新事件发生，送入影子寄存器

重装载寄存器-影子寄存器：
1. ARPE位 = 0：不缓冲，直接更新
2. ARPE位 = 1：等更新事件发生才写入。

更新事件的产生：
1. 软件产生:
   1. UG位 =1, 产生更新事件
2. 硬件产生 
   1. 计数器的值 = TIMx_ARR设定值， 产生 DMA 请求、产生更新事件，比如中断信号或者触发 DAC 同步电路， 此时叫定时器上溢，定时器溢
出就伴随着更新事件的发生


### 配置逻辑

一定记得
1. 使能时钟
2. 找到HAL库的寄存器描述
   1. 配置设备寄存器基地址
   2. 配置设备描述
3. HAL_init 配置设备
4. 使能设备
5. 使能设备中断
6. 使能NVIC中断响应
7. 初始化完成

1. 覆写IRQ原本的中断处理函数，指向HAL的中断处理函数（他内部会实现关中断，判断中断类型，调用回调函数，开中断，清标志位等）
2. 回调函数callback里面实现具体的业务逻辑，所以放在main里面


```
TIM_HandleTypeDef init_TIM;

#define liangji_TIM6_IRQHandler TIM6_IRQHandler
void liangji_init_TIM6(uint32_t psc, uint32_t period)
{
	//enable clk
	__HAL_RCC_TIM6_CLK_ENABLE();
	
	//enable NVIC
	HAL_NVIC_SetPriority(TIM6_IRQn,2,3);
	HAL_NVIC_EnableIRQ(TIM6_IRQn);
	
	//config tim reg
	init_TIM.Instance = TIM6;
	init_TIM.Init.Prescaler=psc;//7200 divf
	init_TIM.Init.CounterMode=TIM_COUNTERMODE_UP;
	init_TIM.Init.Period=period;//5000 ~ 500ms
	//init_TIM.Init.ClockDivision=TIM_CLOCKDIVISION_DIV2;//72M
	init_TIM.Init.AutoReloadPreload=TIM_AUTORELOAD_PRELOAD_DISABLE;

	HAL_TIM_Base_Init(&init_TIM);
	
	//enable TIM6, and enable TIM6_IT
	HAL_TIM_Base_Start_IT(&init_TIM);
}

void liangji_TIM6_IRQHandler(void)
{
	HAL_TIM_IRQHandler(&init_TIM);
}

/*
void HAL_TIM_PeriodElapsedCallback(TIM_HandleTypeDef *htim)
{
	__HAL_TIM_DISABLE(htim);
	__HAL_TIM_DISABLE_IT (htim, TIM_IT_UPDATE);
	
	//do your thing
	LED1_TOGGLE();
	__HAL_TIM_ENABLE(htim);
	__HAL_TIM_ENABLE_IT(htim, TIM_IT_UPDATE);
}
*/

```


## 通用定时器（2-5）
和基本定时器区别：多了输入捕获，PWM输出，输出比较，单脉冲模式

下面是组成部分

### 1. 时钟源选择
1. 内部时钟(CK_INT)
2. 外部时钟模式 1：外部输入引脚(TIx)，x=1，2（即只能来自于通道 1 或者通道 2）

        外部时钟源信号→IO→TIMx_CH1（或者 TIMx_CH2）


1. 外部时钟模式 2：外部触发输入(ETR)
2. 内部触发输入(ITRx)：使用一个定时器作为另一定时器的预分频器

### 2. 控制器
### 3. 时基单元
### 4. 输入捕获
### 5. 输入捕获和输出比较公用部分
### 6. 输出比较


### 定时器中断实验
1. TIMx_CR1   （时基单元）
   1. APRE（选择是否自动重载缓冲）
   2. CMS 和 DIR (选择计数模式)
   3. CEN 使能计数器
2. TIMx_SMCR（从模式控制）  （时钟源选择）
   1. SMS （配置输入时钟来源）
3. TIMx_DIER （DMA/中断使能寄存器）  （配置溢出更新中断使能）
   1. UIE
4. TIMx_SR  （状态寄存器） （显示中断标志位，通知产生了中断，需要手动清除）
   1. UIF
5. TIMx_CNT  （计数寄存器）
6. TIMx_PSC  （预分频）
7. TIMx_ARR  （自动重载）

通用定时器（TIM2-TIM5 等）虽然支持 4 种时钟源（内部时钟、外部 TIx、外部 ETR、内部触发 ITRx），但复位后默认选择的是 “内部时钟（CK_INT）”，这是由硬件寄存器的复位值决定的

可以尝试自己直接实现中断处理，最后清除中断flag即可
```
void liangji_TIM3_IRQHandler(void)
{
	//HAL_TIM_IRQHandler(&init_TIM3);
	if(__HAL_TIM_GET_FLAG(&init_TIM3, TIM_FLAG_UPDATE))
	{
		LED1_TOGGLE();
		__HAL_TIM_CLEAR_FLAG(&init_TIM3, TIM_FLAG_UPDATE);
	}
}
```

### 定时器输出PWM波实验
实现原理
![alt text](../images/8.2.png)


使用寄存器，除了上面的中断用到的基本定时器相关寄存器之外
还有
1. TIMx_CCMR1/2 （捕获 /比较模式寄 存器）
2. TIMx_CCER   （捕获/比较使能寄存器）
3. TIMx_CCR1~4   （捕获/比较寄存器）

```
TIM_HandleTypeDef init_TIM3;
TIM_OC_InitTypeDef init_TIM3_OC;
GPIO_InitTypeDef init_gpio7;
void liangji_init_TIM3_PWM(uint32_t psc, uint32_t period)
{
	//enable clk
	__HAL_RCC_TIM3_CLK_ENABLE();
	
	//enable NVIC
	HAL_NVIC_SetPriority(TIM3_IRQn,2,3);
	HAL_NVIC_EnableIRQ(TIM3_IRQn);
	
	//io mux, PA7->TIM3_CH2, REMAP
	__HAL_RCC_GPIOB_CLK_ENABLE();
	init_gpio7.Pin = GPIO_PIN_5;
	init_gpio7.Mode = GPIO_MODE_AF_PP;
	init_gpio7.Speed = GPIO_SPEED_FREQ_HIGH;
	init_gpio7.Pull = GPIO_PULLUP;
	HAL_GPIO_Init(GPIOB, &init_gpio7);
	
	//GTIM_TIMX_PWM_CHY_GPIO_REMAP();
	__HAL_RCC_AFIO_CLK_ENABLE();
	__HAL_AFIO_REMAP_TIM3_PARTIAL();
	//AFIO_BASE
	
	
	//CLK src sel, default choose ck_int
	
	
	//config TIM BASE
	init_TIM3.Instance = TIM3;
	init_TIM3.Init.Prescaler=psc;
	init_TIM3.Init.CounterMode=TIM_COUNTERMODE_UP;
	init_TIM3.Init.Period=period;
	init_TIM3.Init.AutoReloadPreload=TIM_AUTORELOAD_PRELOAD_DISABLE;
	//init_TIM3.Channel = HAL_TIM_ACTIVE_CHANNEL_2;
	HAL_TIM_PWM_Init(&init_TIM3);
	
	//config TIM compare and output
	init_TIM3_OC.OCMode=TIM_OCMODE_PWM1;
	init_TIM3_OC.Pulse=period/2;
	init_TIM3_OC.OCPolarity=TIM_OCPOLARITY_LOW;
	HAL_TIM_PWM_ConfigChannel(&init_TIM3, &init_TIM3_OC, TIM_CHANNEL_2);
	
	//TIM3 IT
	//HAL_TIM_Base_Start_IT(&init_TIM3);
	HAL_TIM_PWM_Start(&init_TIM3, TIM_CHANNEL_2);

}

void liangji_pwm_led(void)
{
	static uint8_t dir = 1;
	static uint16_t ledrpwmval = 0;
	
	if (dir)
		ledrpwmval++;
	else
		ledrpwmval--;
		
	//switch
	if (ledrpwmval > 300)
		dir = 0;
	if (ledrpwmval == 0)
		dir = 1;

	__HAL_TIM_SET_COMPARE(&init_TIM3, TIM_CHANNEL_2, ledrpwmval);

}

```

注意：关于引脚复用，和引脚重映射，最终你用到那个IO，你就配置那个IO就行了，重映射的原来的那个IO不需要配置了。

TIM3方面

![alt text](../images/8.3.png)
![alt text](../images/8.4.png)
![alt text](../images/8.5.png)
主要配置：
时基
时钟源（无需配置，默认就行）
比较主电路
输出部分


### 输入捕获实验
![alt text](../images/8.6.png)
![alt text](../images/8.7.png)


要做的事情
1. 给TIM时钟
2. 配置时钟源
3. 配置输入IO
4. 配置时基
5. 配置输入通道
6. 配置捕获主电路
7. 配置捕获中断

```

//TIM COMMON - Capture Project
//PA0 -> TIM5_CH1
TIM_HandleTypeDef init_TIM5;
GPIO_InitTypeDef init_gpio_capture;
TIM_IC_InitTypeDef init_IC;
#define liangji_TIM5_IRQHandler TIM5_IRQHandler
uint8_t g_timxchy_cap_sta = 0; //this count N
uint16_t g_timxchy_cap_val = 0; //count Once cnt < arr
uint16_t count_up = 0;


void liangji_init_TIM5_CAPTURE(uint32_t psc, uint32_t period)
{
	//NVIC
	HAL_NVIC_SetPriority(TIM5_IRQn,2,3);
	HAL_NVIC_EnableIRQ(TIM5_IRQn);
	
	//IO
	__HAL_RCC_GPIOA_CLK_ENABLE();
	init_gpio_capture.Pin = GPIO_PIN_0;
	init_gpio_capture.Mode = GPIO_MODE_AF_PP;
	init_gpio_capture.Speed = GPIO_SPEED_FREQ_HIGH;
	init_gpio_capture.Pull = GPIO_PULLUP;
	HAL_GPIO_Init(GPIOA, &init_gpio_capture);

	
	//enable TIM5 CLK
	__HAL_RCC_TIM5_CLK_ENABLE();
	
	//TIM5 CLK SOURCE SEL
	//stay Default
	
	//TIM5 TIM BASE
	init_TIM5.Instance = TIM5;
	init_TIM5.Init.Prescaler=psc;
	init_TIM5.Init.CounterMode=TIM_COUNTERMODE_UP;
	init_TIM5.Init.Period=period;
	init_TIM5.Init.ClockDivision=TIM_CLOCKDIVISION_DIV1;
	init_TIM5.Init.AutoReloadPreload=TIM_AUTORELOAD_PRELOAD_DISABLE;
	init_TIM5.Channel = HAL_TIM_ACTIVE_CHANNEL_1;
	HAL_TIM_IC_Init(&init_TIM5);
	
	//TIM5 Capture
	init_IC.ICFilter = 0;//dont use filter
	init_IC.ICPrescaler = TIM_ICPSC_DIV1;
	init_IC.ICSelection = TIM_ICSELECTION_DIRECTTI;
	init_IC.ICPolarity = TIM_ICPOLARITY_RISING;
	HAL_TIM_IC_ConfigChannel(&init_TIM5, &init_IC, TIM_CHANNEL_1);
	
	//TIM5 Capture IT and IT
	HAL_TIM_IC_Start_IT(&init_TIM5, TIM_CHANNEL_1);
	HAL_TIM_Base_Start_IT(&init_TIM5);
}

void liangji_TIM5_Capture(void)
{
	if((g_timxchy_cap_sta & 0x80)!= 0)
	{
		//we get a pulse
		uint16_t N = g_timxchy_cap_sta & 0x3F;
		N*= 65536;
		N+=g_timxchy_cap_val;
		printf("HIGH PULSE : %d us \r\n", N);
		g_timxchy_cap_sta = 0;
	}
	
	//just LED0 TOGGLE
	static uint8_t t = 0;
	t++;
	if(t>20){
		t=0;
		LED0_TOGGLE();
	}
	
}




void liangji_TIM5_IRQHandler(void)
{
		HAL_TIM_IRQHandler(&init_TIM5);
}

/*
			Update IT callback
			impel in main, toggle led1, and count up ++
      HAL_TIM_PeriodElapsedCallback(htim);
*/

void HAL_TIM_PeriodElapsedCallback(TIM_HandleTypeDef *htim)
{
	if (htim->Instance == TIM6){
		//LED1_TOGGLE();
	} else if (htim->Instance == TIM3){
		//LED1_TOGGLE();
	} else if (htim->Instance == TIM5) {
			if((g_timxchy_cap_sta & 0X80) == 0){
					if(g_timxchy_cap_sta & 0X40){
							if ((g_timxchy_cap_sta & 0X3F) == 0X3F){
								//  wait for falling, over the N max, is too long,think it is success, so re-wait for up, give up wait falling
								TIM_RESET_CAPTUREPOLARITY(&init_TIM5, TIM_CHANNEL_1);
								TIM_SET_CAPTUREPOLARITY(&init_TIM5, TIM_CHANNEL_1, TIM_ICPOLARITY_RISING);
								g_timxchy_cap_sta |= 0x80;     
								g_timxchy_cap_val = 0xffff; //mean: N(max)*arr + N(max)
							}
							else {
								g_timxchy_cap_sta++;  //N +1
							}
					}
			
			}
	}
}

/*
      HAL_TIM_IC_CaptureCallback(htim);
*/
void HAL_TIM_IC_CaptureCallback(TIM_HandleTypeDef *htim)
{
	//get up cnt
	//set fall detect
	if((g_timxchy_cap_sta & 0X80) == 0){
		if(g_timxchy_cap_sta & 0X40){ //now 0 1, but now capture falling because when capture up, we detect falling
			g_timxchy_cap_sta |= 0x80;
			g_timxchy_cap_val = HAL_TIM_ReadCapturedValue(&init_TIM5, TIM_CHANNEL_1);//get falling cnt t2 (t2<arr)
			//reset detect up
			TIM_RESET_CAPTUREPOLARITY(&init_TIM5, TIM_CHANNEL_1);
			TIM_SET_CAPTUREPOLARITY(&init_TIM5, TIM_CHANNEL_1, TIM_ICPOLARITY_RISING);
		} else { //now 0 0, wait for up edge, but now capture interupt, so start a new detect
			g_timxchy_cap_sta = 0;
			g_timxchy_cap_val = 0;
			g_timxchy_cap_sta |= 0x40;   // set 0 1, we have get up edge
			//set polo falling detect, no need to record now cnt t1, because t1 + N*arr + t2 = now
			__HAL_TIM_DISABLE(&init_TIM5);
			__HAL_TIM_SET_COUNTER(&init_TIM5, 0); 
			TIM_RESET_CAPTUREPOLARITY(&init_TIM5, TIM_CHANNEL_1);			
			TIM_SET_CAPTUREPOLARITY(&init_TIM5, TIM_CHANNEL_1, TIM_ICPOLARITY_RISING);
			__HAL_TIM_ENABLE(&init_TIM5);
		}
	}
}


```
![alt text](../images/8.8.png)
重点在于在捕获中断和更新事件中断中，统计溢出次数N和上升下降沿。




### 脉冲计数实验
这次我们使用外部时钟模式1, 多一个配置控制器。

![alt text](../images/8.9.png)

注意所有功能的使能， 中断的使能
1. 时钟的使能
2. 输入通道的使能（如果有）
3. 更新事件中断使能
## 高级定时器（1,8）
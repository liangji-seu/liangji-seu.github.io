---
title: imx6ull 蜂鸣器驱动编写实验
date: 2026-03-04 18:33:04
categories: [学习笔记, 嵌入式, LINUX] 
tags: [嵌入式, linux, 驱动]
---

# 实验
这一节接着自己编写一个gpio应用的外设：蜂鸣器的驱动，巩固一下gpio子系统，pinctrl子系统，以及dts的使用

## 资源
蜂鸣器引脚：`SNVS_TAMPER1`
> 这里的SNVS就是指一块具有独立供电策略和安全属性的特殊区域，SNVS 域最核心的特点是它由专门的 VDD_SNVS_IN 供电（通常接纽扣电池或电容）。


和led驱动一样，都是gpio输出，很简单，代码就不放了
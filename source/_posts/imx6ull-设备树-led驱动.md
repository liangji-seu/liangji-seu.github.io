---
title: imx6ull 设备树-led驱动
date: 2026-03-03 12:09:38
categories: [学习笔记, 嵌入式, LINUX] 
tags: [嵌入式, linux, 驱动]
---
- [方案](#方案)
- [实现](#实现)


# 方案
前面我们在模块里面，像裸机那样宏定义了外设寄存器的基地址。但是由于我们linux内核开启了mmu，所以内核空间依然是有独立的虚拟地址的。所以需要
- ioremap
- iounmap

来进行**物理地址-内核空间虚拟地址的映射**

后来学习了设备树dts之后，可以把这些和具体板卡SOC相关的物理地址的参数，全部写到dts里面。

**使用设备树来向 Linux 内核传递相关的寄存器物理地址**

使用内核提供的**OF函数**从**设备树**中获取所需的属性值，然后使用获取到的属性值来初始化相关的 IO


# 实现
这个还是比较简单的，我自己也手写了一遍led dts的驱动
```c
//通用
#include <linux/types.h>
#include <linux/kernel.h>
#include <linux/delay.h>
#include <linux/ide.h>

//module
#include <linux/init.h>
#include <linux/module.h>

//err, gpio_macro
#include <linux/errno.h>
#include <linux/gpio.h>

//register_cdev
#include <linux/cdev.h>

//mknod
#include <linux/device.h>

//dts OF
#include <linux/of.h>
#include <linux/of_address.h>

//ioremap
#include <asm/mach/map.h>
#include <asm/uaccess.h>
#include <asm/io.h>


#define DEV_CNT 1
#define DEV_NAME "mydtsled"
#define DEV_CLASS "mydtsled_class"
#define DEV_DEVICE "mydtsled_device"

/* 映射后的寄存器虚拟地址指针 */
static void __iomem *IMX6U_CCM_CCGR1;
static void __iomem *SW_MUX_GPIO1_IO03;
static void __iomem *SW_PAD_GPIO1_IO03;
static void __iomem *GPIO1_DR;
static void __iomem *GPIO1_GDIR;


//desc a led
struct led {
		//alloc devid
		dev_t devid;
		int major;
		int minor;

		//register cdev
		struct cdev _cdev;

		//mknod class and device
		struct class * _class;
		struct device * _device;

		//dts node
		struct device_node * _dtb_node;
} mydtsled;



static int led_open(struct inode *inode, struct file *filp)
{
	printk("led is open!\r\n");
	filp->private_data = &mydtsled;
	return 0;
}

static ssize_t led_read(struct file *filp, char __user *buf, size_t cnt, loff_t *offt)
{
	printk("mytest read!\r\n");
	return 0;
}

#define LEDOFF 					0			/* 关灯 */
#define LEDON 					1			/* 开灯 */

static void led_switch(u8 sta)
{
	u32 val = 0;
	if(sta == LEDON) {
		val = readl(GPIO1_DR);
		val &= ~(1 << 3);	
		writel(val, GPIO1_DR);
	}else if(sta == LEDOFF) {
		val = readl(GPIO1_DR);
		val|= (1 << 3);	
		writel(val, GPIO1_DR);
	}	
}

static ssize_t led_write(struct file *filp, const char __user *buf, size_t cnt, loff_t *offt)
{
	int retvalue = 0;
	unsigned char databuf[1];

	printk("mydtsled write! : filp->private_data->major = %d\r\n", 
				(*(struct led *)(filp->private_data)).major);
	retvalue = copy_from_user(databuf, buf, cnt);
	if(retvalue < 0){
		printk("kernel get user write failed\n");
		return -EFAULT;
	} else {
		printk("kernel get user char = %s\n", buf);
	}

	if(databuf[0] == LEDON){
		led_switch(LEDON);
	} else if(databuf[0] == LEDOFF) {
		led_switch(LEDOFF);
	}

	return 0;
}

static int led_release(struct inode *inode, struct file *filp)
{
	printk("chrdevbase release！\r\n");
	return 0;
}


 static struct file_operations led_fops = {
	.owner = THIS_MODULE,	
	.open = led_open,
	.read = led_read,
	.write = led_write,
	.release = led_release,
};


static int __init dtsled_init(void){
		struct property* prop;
		int ret;
		const char * str;	//常量指针，能重定向，无法改值
		u32 regdata[14];


		printk("my dts led driver start init\n");


		//dts of
		mydtsled._dtb_node = of_find_node_by_path("/led@0");
		if(mydtsled._dtb_node == NULL){
			printk("not find dtb node\n");
			return -EINVAL;
		} else {
			printk("find node\n");
		}

		//get prop from dtb node
		prop = of_find_property(mydtsled._dtb_node , "compatible", NULL);
		if(prop == NULL){
			printk("not find dtb compatible\n");
		} else {
			printk("compatible = %s\n", (char*)(prop->value));
		}

		//get status
		ret = of_property_read_string(mydtsled._dtb_node , "status", &str);
		if(ret < 0){
			printk("status read failed\n");
		} else {
			printk("status = %s\n", str);
		}

		//get reg
		ret = of_property_read_u32_array(mydtsled._dtb_node, "reg", regdata, 10);
		if(ret < 0){
				printk("reg read failed\n");
		} else {
			u8 i = 0;
			printk("read reg = \n");
			for(i = 0; i<10; i++)
				printk("%x ", regdata[i]);
			printk("\n");
		}



		//init led
		IMX6U_CCM_CCGR1 = of_iomap(mydtsled._dtb_node, 0);
		SW_MUX_GPIO1_IO03 = of_iomap(mydtsled._dtb_node, 1);
		SW_PAD_GPIO1_IO03 = of_iomap(mydtsled._dtb_node, 2);
		GPIO1_DR = of_iomap(mydtsled._dtb_node, 3);
		GPIO1_GDIR = of_iomap(mydtsled._dtb_node, 4);
		
		//ccm enable clock of gpio1
		u32 val = 0;
		val = readl(IMX6U_CCM_CCGR1);
		val &= ~(3<<26);
		val |= (3<<26);
		writel(val, IMX6U_CCM_CCGR1);

		//iomux iopad
		//为什么这里不用使能时钟？
		writel(5, SW_MUX_GPIO1_IO03);	//IOMUX
		writel(0x10B0, SW_PAD_GPIO1_IO03);	//IOPAD

		//gpio cr: output
		val = readl(GPIO1_GDIR);
		val &= ~(1<<3);
		val |= (1<<3);
		writel(val, GPIO1_GDIR);

		//gpio dr
		val = readl(GPIO1_DR);
		val |= (1<<3);
		writel(val, GPIO1_DR);


		//alloc devid
		alloc_chrdev_region(&(mydtsled.devid), 0, DEV_CNT, DEV_NAME);
		mydtsled.major = MAJOR(mydtsled.devid);
		mydtsled.minor = MINOR(mydtsled.devid);
		printk("mydtsled alloc devid over, major = %d, minor = %d\n", 
						mydtsled.major, mydtsled.minor);


		//register cdev
		mydtsled._cdev.owner = THIS_MODULE;
		cdev_init(&(mydtsled._cdev), &led_fops);
		cdev_add(&(mydtsled._cdev), mydtsled.devid, DEV_CNT);

		//mknod
		mydtsled._class = class_create(THIS_MODULE, DEV_CLASS);
		mydtsled._device = device_create(mydtsled._class, NULL, mydtsled.devid, NULL, DEV_DEVICE);


		printk("my dts led driver init over\n");
		return 0;
}

static void __exit dtsled_exit(void){
		printk("my dts led driver start exit\n");

		
    	//注销devid
	    unregister_chrdev_region(mydtsled.devid, DEV_CNT);
	
		//注销字符设备
		cdev_del(&(mydtsled._cdev));

		//取消设备节点
		device_destroy(mydtsled._class, mydtsled.devid);
		class_destroy(mydtsled._class);

		printk("my dts led driver exit over\n");
}

module_init(dtsled_init);
module_exit(dtsled_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("liangji");

```
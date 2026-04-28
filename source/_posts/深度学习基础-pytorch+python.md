---
title: 深度学习基础-pytorch+python
date: 2026-04-28 14:21
categories:
  - 学习笔记
  - 大模型算法
tags:
  - "#深度学习"
  - "#python"
  - "#pytorch"
---
# python概念扫盲
基础的python语法，这里就不讲了，python本身底层是用c++来实现的，所以全部都是面向对象变成，里面所有的库，都是实现的类。

python的所有变量 = auto指针
指针创建在栈区，指向堆区的内存。实际的对象内存，在堆区里面。

# pytorch

## **==pytorch特性==**：

![[../images/Pasted image 20260428211057.png]]

比较重要的就是：
1. 动态计算图的理解-> 自动微分的实现
2. torch.tensor(), 张量，和numpy库里面的数组定义类似。

## ==**自动求导机制**==

我们模型的Loss函数，需要对w, b求导，其自动求导是依赖计算图的。 当我们建立好了计算图

```C
w → * → y_pred → - → (差) → **2 → loss
    ↑                 ↑
    x               y_true
    
    w = torch.tensor(2.0, requires_grad=True)
    loss.backward()
```

我们通过标记变量为需要求导，相当于把这个对象的标志位，置1，这样当你调用loss.backward()的时候，他就可以根据这个计算链表图，找到对应的变量，求Loss()关于这个变量的偏微分，也就是偏导数。所有的偏导数的动态数组，就是梯度


## **==pytorch的作用==**
我们使用pytorch，本质上，是为了快速的
- 搭建网络模型
- 处理数据
- 训练/评估
- 推理
本质上都是在干这4件事情。所以需要学会用哪些库来实现我们想要的功能。


## **==pytorch库架构图==**
pytorch是一个大的库，里面有不同功能模块子库
![[../images/Pasted image 20260428211528.png]]


## 自动微分
pytorch里最重要的就是依靠动态计算图，来进行自动微分的计算了。

### 梯度
一元函数，因变量关于自变量求导，叫做导数。
			y = f(x)  =>  ∂f/∂x（导数）
多元函数，因变量关于自变量们求导，叫做梯度。
			y = f(x1, x2, x3,....., xn) =>
			{∂f/∂x1, ∂f/∂x2, ∂f/∂x3, ...... , ∂f/∂xn} （叫做y的梯度）
所以<mark style="background:rgba(163, 67, 31, 0.2)">梯度本身，就是这个多元函数（标量），关于各个自变量的导数</mark>。

![[../images/Pasted image 20260428212737.png]]
### torch库自动计算梯度

上面我们定义好了梯度的计算公式，下面就是torch库，来帮我们计算梯度

我们不需要自己定义求梯度的公式。在构建前向传播的损失函数的时候。torch利用动态计算图，来表达出计算的公式。然后利用**链式求导**法则，来进行求导。
![[../images/4d9fa9e1a77e75d9eeee8d3ff9e162ad.jpg]]

可以看到，通过链式法则，就可以把求梯度的过程，和计算图的每个环节联系上。

通过一次<mark style="background:rgba(163, 67, 31, 0.2)">loss.backward()</mark>, 就可以计算一次loss(x1, x2, x3, ..., xn)的梯度了（同时路上所有中间变量的梯度也都求出来了。）

![[../images/ce9e727371321e54859b9ff0f2112171.jpg]]

> 注意：**n元函数**loss，输入是n元向量，**loss的梯度**，也是一个**n元向量**，是关于所有自变量的向量
> 因此，梯度向量的每个元素，都应该存放在n元输入向量的每个元素对象的**内存**里面。
> 所以输入元素<mark style="background:rgba(240, 200, 0, 0.2)">x1.grad</mark>， <mark style="background:rgba(240, 200, 0, 0.2)">x2.grad,</mark> ....,<mark style="background:rgba(240, 200, 0, 0.2)"> xn.grad</mark>. 这个成员变量，专门用来存放梯度元素分量



```Python
x = torch.randn(2,2, requires_grad=True)

print(x)

y = x + 2
z = y * y * 3
print(z)
out = z.mean()
print(out)

out.backward()
print(x.grad)
```

通过标记x这个变量的内部标志位 <mark style="background:#affad1">requires_grad</mark>=True, 之后，整个计算图只要包含x这个变量，全部会被标记这个标志位。

![[../images/5c6b7683240dd461a33b50d78be89db2.jpg]]

之后out.backward(), 触发torch的求导过程，并把out(x), 关于各个自变量，中间环节的导数（梯度分类），全部存放在对于的对象内存里面。

**<mark style="background:#ff4d4f">梯度本身也是一个关于(x1, x2,x3, ....., xn)的n元函数</mark>**。

每次计算的梯度都不一样，当然不一样了，**梯度也是一个函数**（关于x的函数）
![[../images/Pasted image 20260428215003.png]]

### python的with 语句

python里面，with语句，通常用来申请某类资源，然后里面实现在占用这个资源时要做的事情，跳出这个过程之后，会**自动释放这个资源**

### torch.no_grad()
用torch.no_grad(), 可以暂时关闭自动求导的标志位传到, 相当于关中断一样。
```Python
import torch

# 定义一个需要梯度的张量
x = torch.tensor([1.0, 2.0], requires_grad=True)

# 正常操作：会追踪梯度
y1 = x * 2
print(y1.requires_grad)  # 输出 True，会被加入计算图

# 用 torch.no_grad()：块内操作不追踪梯度
with torch.no_grad():
    y2 = x * 2
    print(y2.requires_grad)  # 输出 False，不加入计算图

# 块外恢复正常
y3 = x * 2
print(y3.requires_grad)  # 输出 True，恢复追踪
```
![[../images/Pasted image 20260428215400.png]]



---


# 深度学习的组成
## 组成
我们的torch深度学习，主要做一下几件事：
1. 数据
2. 模型
3. 衡量模型质量（定义损失函数）
4. 训练
	1. 前向传播
	2. 计算损失（得到这次的模型性能）
	3. 反向传播（计算参数更新值）
	4. 参数更新（优化器来具体更新参数）
5. 评估/推理

## 网络层/架构分类
- FNN（前馈神经网络）
- CNN（卷积神经网络）
- RNN（循环神经网络）
- Transformer （注意力机制）

## 一些小零件
- 各层之间的激活函数
- 各种损失函数
- 各种优化器

## 一些技巧
- dropout 随机丢失
- 权重衰退（正则化）
- BatchNorm 批量归一化


# torch 数据

这一节，来讲一下，torch库，是如何处理模型所需要的数据的

torch库里面专门用来处理数据的库是：
- `torch.utils.data.Dataset` torch库的**数据集类**
- `torch.utils.data.DataLoader` torch库的**数据集迭代器类**（帮助获取数据的类）
> 既然都是类，那么要用，肯定要创建各自的对象，才能实际发挥作用。

### 创建自定义数据集

创建自定义的数据集，需要自己实现一个自定义数据集类（集成Dataset基类），然后为迭代器提供两个必要的方法。用来告诉迭代器如何访问你的自定义数据集。
```python
import numpy as np
import torch
from torch.utils.data import Dataset, DataLoader

# 定义 自定义数据集类，继承Dataset基类
class MyDataset(Dataset):
	# 类的构造函数下半段， 获取我的数据集内容
    def __init__(self, X_data, Y_data):
        self.X_data = X_data
        self.Y_data = Y_data

	# 实现内置__len__方法，用来返回数据集的数据长度
    def __len__(self):
        return len(self.X_data)

	# 实现内置__getitem__方法，用来返回一条张量的数据样本
    def __getitem__(self, idx):
        x = torch.tensor(self.X_data[idx], dtype = torch.float32)
        y = torch.tensor(self.Y_data[idx], dtype = torch.float32)
        return x, y

# 这是我们自定义的数据X（输入），Y（标签）
X_data = np.arange(8).reshape(4,2) #先用numpy创建一个4x2的 0-7的数组
Y_data = [1,0,1,0]

# 创建出我们自己的数据集对象dataset
dataset = MyDataset(X_data, Y_data)

# 创建一个数据集迭代器，用来替我们自由的随机选择数据集。
""" 迭代器设置：指定数据集对象， batch_size批数（分成batch_size批），shuffle表示随机选取"""
dataloader = DataLoader(dataset, batch_size=2, shuffle=True)


for epoch in range(1):
    for batch_idx, (inputs, labels) in enumerate(dataloader):
        print("batch index = ", batch_idx)
        print("(inputs, labels) = ", (inputs, labels))
```
![[../images/aeb02221b8034f0046e6deb51189b886.jpg]]

```bash
batch index =  0
(inputs, labels) =  (tensor([[0., 1.],
        [6., 7.]]), tensor([1., 0.]))
batch index =  1
(inputs, labels) =  (tensor([[2., 3.],
        [4., 5.]]), tensor([0., 1.]))
```

```bash
batch index =  0
(inputs, labels) =  (tensor([[2., 3.],
        [6., 7.]]), tensor([0., 0.]))
batch index =  1
(inputs, labels) =  (tensor([[0., 1.],
        [4., 5.]]), tensor([1., 1.]))
```

可以看到，连续两次运行后，enumerate( dataloader), 枚举迭代器让它一次返回一个迭代单位
- 第x/2批数据样本
- 随机返回抽取

所以可以看到，每次返回的是2x2的，也就是**随机两个样本**组成的**张量**，也就是**一个batch**，**一个批次**

> 从这里就可以看出，深度学习的训练，对数据的使用，是以批为单位的。一批才计算一次损失，更新一次模型参数。



### 预定义数据集 + 数据预处理
torch里面还内置了一些比较知名的数据集。比如手写数字图片MNIST数据集。

同时，我们针对数据，肯定也希望有一些管线的预处理，来实现数据增强。比如图片的翻转，裁剪，数据范围的归一化等等。

我们这里使用的MNIST，手写图片，是属于CV领域的，所以是定义在torchvision模块库里面的。
- `torchvision.transforms` (数据处理库)
	- `transforms.ToTensor()` 
		- openCV的图片格式是(**高度**x**宽度**x**通道**)，里面**每个元素**的范围是**0-255**
		- .ToTensor()转换维度格式化（**通道**x**高度**x**宽度**），元素取值范围/255（也就是0-1）![[../images/Pasted image 20260428224503.png]]
		- 这样将opencv的图片格式转成 卷积能用的张量。
	- `transforms.Normalize(mean, std)` 调整每个像素的值的范围从（0-1）到（-1-1），这样方便收敛，因为以0为中心
		- ![[../images/Pasted image 20260428224650.png]]
		- ![[../images/Pasted image 20260428224711.png]]
		- ![[../images/Pasted image 20260428224727.png]]
- `torchvision.datasets` (**官方提供**的“素材库”和“工具箱”)
	- 是一个内置数据集的库，内置了CV领域的经典公开数据集。
	- ![[../images/Pasted image 20260428224913.png]]
	


```Python
import  torch
import torchvision.transforms as transforms
import torchvision.datasets as datasets

# 这里我们预定义一个数据处理流（一组数据处理函数，用来实现一系列的数据处理）
transform = transforms.Compose([
    transforms.ToTensor(), #转成tensor张量格式
    transforms.Normalize(mean=[0.5], std=[0.5]) #归一化，核心作用是将图像的像素值分布调整到一个特定的范围（通常是 0 均值附近），从而加速模型的收敛
])

"""开始加载经典MNIST手写数据集
dataset.MNIST()库函数提供下载，读取方式
	- root="./data"  指定数据集的存储目录，下载后其他项目也能指定使用
	- train=True     区分训练集60000个样本/测试集10000个样本。
	- transform=transform    指定每个数据样本（一张图片）的加工流水线，处理成能输入CNN的张量tensor
	- download=True   自动下载开关（打开后，会自动检查root下是否有数据，有就直接加载。）
"""
# 加载了两个数据集
train_dataset = datasets.MNIST(root="./data", train=True, transform=transform, download=True)

test_dataset = datasets.MNIST(root="./data", train=False, transform=transform, download=True)


"""
开始创建两个数据集的迭代器。64个批，训练集随机采样，测试集不随机。
"""
train_dataloader = torch.utils.data.DataLoader(dataset=train_dataset, batch_size = 64, shuffle=True)
test_dataloader = torch.utils.data.DataLoader(dataset=test_dataset, batch_size=64, shuffle=False)
```



## 例子
举一个RNN的数据输入。

想要1000个样本，每个样本的序列长度为10， 输入维度input_size = 5， 输出维度为2（**每个样本一个输出标签**）

参数解析：
- 一个样本（序列段）
	- seq_len（序列段长度，有多少个时间步）
	- input_size (输入特征维度)
- 样本数量 1000
- **批batch**， 这个和**迭代器**绑定。

torch的随机张量：
- `torch.randn`(形状) 标准正态分布
- `torch.rand`(形状) [0, 1),均匀分布
- `torch.randint()`， 生成指定范围内的随机整数

`torch.utils.data.TensorDataset` 从**tensor张量**直接创建数据集，**属于Dataset的一个子类**。


```python
import torch
from torch.utils.data import DataLoader, TensorDataset

num_samples = 1000
seq_len = 10
input_size = 5
output_size = 2


X = torch.randn(num_samples, seq_len, input_size) # 定义num_samples个样本。元素服从标准正态分布（大部分集中于0）
Y = torch.randint(0, output_size, size=(num_samples,)) # 0表示随机数最小值，output_size 随机数最大值.[0,2)之间的整数，也就是0/1, size=指定尺寸，一维1000个。一个样本，对应一个标签值。一共1000个样本的标签

dataset = TensorDataset(X,Y)
"""
把这1000个样本，随机切割成32个批
"""
train_loader = DataLoader(dataset, batch_size = 32, shuffle=True)
```

所以数据的逻辑是：
1. 元素
	1. （一个时间步）
	2. 图片的一个通道
2. **样本**（多个元素）
	1. 多个时间步
	2. 3个通道的完整一张图片。（**通道**x 高度 x 宽度）（很像3个时间步）
3. **批batch**（多个样本）
	1. 多个序列块
	2. 多张图片




# torch 模型

# torch 损失函数
# torch 训练
# torch 评估
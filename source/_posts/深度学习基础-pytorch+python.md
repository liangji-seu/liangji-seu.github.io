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
1. **数据**
2. **模型**
3. 衡量模型质量（定义**损失函数**）
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
- softmax层 [[#softmax运算]]


## 一些技巧
- dropout 随机丢失
- 权重衰退（正则化）[[#权重衰退（正则化）]]
- BatchNorm 批量归一化


# 理论角度理解深度学习

## 三大件
首先这一节，我从数学理论的角度来理解，深度学习的过程。简单来说，深度学习主要的三大件：
- **数据(x,y')**
- **模型（参数（a,b））**
- **损失函数（平均损失函数Loss）**

本质上，我们定义/训练模型，依赖的是这样的架构：
![[../images/b601338da71337a1647f935b69f273b0.jpg]]

我们现在假设一个最简单的函数模型（即线性回归模型）：
![[../images/f6e2ee0930f6de81ec519a777d857295.jpg|286]]

![[../images/8b52c7545a89cd7649c21260576c1885.jpg|566]]

**<mark style="background:#ff4d4f">模型</mark>**：
	y = ax + b
所以**<mark style="background:#fff88f">模型参数为（a, b）</mark>**

**<mark style="background:#ff4d4f">数据</mark>**：
	我这里一共准备了8个样本：<mark style="background:#fff88f"> 一个样本 = 一个输入+一个标签</mark>
所以dataset就是这8个样本组成的张量
dataloader是针对这个dataset的迭代器，设定一共分成batch_size批：
- full_batch：batch_size = 1
	- 训练稳定，但是内存占用大
- mini_batch: batch_size = 4
	- 训练速度快，内存占用小（后面分析）

**<mark style="background:#ff4d4f">损失函数：</mark>loss

这里就先使用最简单的**平方误差函数**
- **单个样本的损失loss** 
- ![[../images/Pasted image 20260429133123.png]]
![[../images/9343d0b924a576a527488d32dd699dc1.jpg|364]]

但是我们实际训练的时候，是不可能用单个样本的loss损失来衡量模型当前的质量的（万一这个样本本身不太好，对吧）

**<mark style="background:#ff4d4f">平均损失函数</mark>Loss
所以我们选择一个batch，一个批的样本，来衡量模型的质量。 **为了度量模型在整个数据集上的质量，我们需计算在训练集个样本上的损失均值（也等价于求和）**
![[../images/Pasted image 20260429133508.png|587]]
![[../images/c7657f258b925ab32163912d16eec2f2.jpg]]

**所以我们最终会使用这个平均损失函数Loss，来作为衡量模型质量的标准。**




## 优化模型
我们获得了数据集，定义了模型，然后设置了Loss损失函数，来衡量模型的好坏。

最初，输入输入到模型（经过模型参数运算），得到输出，但是这个和真值标签是有差距的。

所以我们**训练模型的目的**，就是为了，**获得一个最佳的模型参数，让这个模型的损失函数最小**。

所以，**训练**本质上是围绕着**损失函数**来进行的。

为什么损失函数能作为训练的依赖呢，因为损失函数，主要由两块组成：
- 模型参数
- 数据（输入+标签）

![[../images/b601338da71337a1647f935b69f273b0.jpg]]

可以看到，Loss的组成里面，**损失函数本身只是一个组合模型参数和数据的框架**。绿色里面是我们的模型参数+数据集。

其中红色是模型参数，蓝色是我们的数据集。

当给定**数据集**后（即给定<mark style="background:#fff88f">输入x1, x2, ....., xn, 标签y1', y2', ...., yn'</mark>）数据集就作为Loss(a,b)这个函数的系数，然后我们当前模型的参数(a1,b1)，只是这个Loss(a,b)曲线上的一个点。

我们的**目的，是为了找一个(a2,b2), 当下一次再次输入这个数据集的时候**（所以Loss(a,b)的系数没有变），**Loss的值能够变小**。

这就用到了<mark style="background:#affad1">梯度下降</mark>

![[../images/84cecf9c1676010fcaa5833f16feef31.jpg]]

上面举了一个full-batch的例子，当只有一个batch的时候，Loss的图像本身是不会变的。因为系数不变。如果mini-batch，有多个batch，会变化，但是训练的更快了。

**为什么我们使用mini-batch？**
因为full-batch, 相当于一个batch里面包括了所有的样本，全部输入完了才更新模型参数。
这会导致Loss里面的n项（n个样本）太大，内存不停的占用。导致爆内存。


![[../images/f5859d7b24a45d37039d78a200783b81.jpg|322]]


所以，这就解释了，Loss损失函数，模型参数model，数据集dataset, 这三者是一个整体，要一起讨论的。


### 举例证明
下面来看一下我们训练的过程
![[../images/8486afa0181091e1ab61a55c248c0792.jpg]]




### Loss函数求w,b的梯度
batch_size
- = 一个batch批，里面有多少个样本
- = Loss(w,b) = 1/2n * ∑((wx1+b-y1')2+(wx2+b-y2')2+...+(wxn+b-yn')2) 里面有多少项

所以当batch_size > 1的时候。
**Loss(w,b)关于(w,b)求出来的梯度，本质上是平均梯度。已经除了batch_size了**。
![[../images/Pasted image 20260429155539.png|84]]

![[../images/6beffac0fe10deff660fef04ff09d8ef.jpg|513]]


### 多层FNN时链式法则，反向传播更新梯度的过程

^e096f0

假设现在有一个双层的全连接网络，第一层一般用激活函数。下面给出证明过程

一般我们习惯:全连接层的：
1. 输入：x
2. 权重矩阵W，偏置向量b
3. 输出（非最后一层叫预激活）： z
4. 激活函数sigma

![[../images/d312243badf6ba8ea3978a515f88c8fa.jpg|593]]
![[../images/ddbec40e2d05273036326d6decafd12e.jpg|584]]

所以总结下来：**每一层参数的梯度**，仅和 
1. **反向传过来的上游误差**：就是**后面所有层 + 损失，对当前层输入的导数**
2. **当前层激活函数的局部导数** 
3. **当前层线性部分（\(z=Wx+b\)）对自身参数的局部导数**

有关。<mark style="background:#fff88f">所以，每一层的参数的梯度，仅和自身层及后层有关</mark>。



## 优化参数
我们举得例子，就是最简单的y =ax + b, 就是最简单的一维输入，一维输出的简单**线性回归模型**

包括我们后面多维输入构成的FNN全连接层，都是这个训练逻辑，这样就很好理解了。

那么，扩展到一般的线性回归模型： y=wx + b, 其中w，b均为张量。

我们**模型的参数就是（w,b）**, 我们训练的目的，就是**更新这个（w,b）**, 让**Loss损失函数min**



<mark style="background:#fff88f">那么具体更新参数呢？</mark>
前面只讲了，Loss对w,b求微分，得到关于（w,b）的平均梯度。我**只知道方向要往左/右变化**，**那么变化多少呢？**


这个就是<mark style="background:#ff4d4f">优化器</mark>**要干的事情了

他决定了如何更新模型的参数，减去一半？还是减去多少？

下面展示一个最简单的优化器：
![[../images/Pasted image 20260429140002.png|454]]
具体可以写成
![[../images/Pasted image 20260429140405.png|490]]
![[../images/Pasted image 20260429140445.png|186]]
![[../images/Pasted image 20260429140457.png|86]]


注意，这里的平均梯度，就是我们自动求导计算出来的了。我们优化器仅有两个参数：
- 模型参数（w,b）
	- 平均梯度已经存放在参数的对象里面了。
- 学习率（lr）
![[../images/Pasted image 20260429155658.png|240]]
这里的批量大小，学习率，就是我们的超参数
> **batch_size**, 就是表示的**一个batch里面有多少个样本**。


**<mark style="background:#ff4d4f">梯度下降得到什么？</mark>**
我们一个batch，能够得到batch_size个分类的Loss损失函数，然后Loss关于w,b求导。得到的是

我们不需要具体关心如何更新参数，直接选用**torch库里面的优化器**就行了。



## 总结

至此我们从理论层面上讲解推导了
- 数据
- 模型+参数
- 损失函数
	- 优化器
的作用。

---

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

这里主要记录一下，各个主流模型的定义，以及，torch库里面集成的库，用于快速构建模型

## 线性回归单元

线性回归单元，就是我们之前说的<mark style="background:#fff88f">y =wx + b</mark> (w, x 均为n维向量，b维标量) 

![[../images/406172634195b33b63e554bef3dd1840.jpg|566]]
所以**一个线性回归单元**，就有**一个输出**，对应**一个w权重向量**（n维），以及**一个b偏置标量**。

一般把网络横过来传导观看
![[../images/Pasted image 20260429150823.png|112]]


## _全连接层_
上一节的线性回归单元，**一个线性回归单元**，对应：
1. n维输入
2. 1维输出
3. 一个n维的w权重矩阵
4. 一个1维的b偏置标量

所以，当我们把他组合起来后，就形成了我们的全连接层

![[../images/a1508a1ba46373bdde3eef56c46a7e6e.jpg]]


所以当**具有多层时**，也就具有了从**n维输入-> m维输出**的**全连接层**

所以定义一个全连接层，仅需要确认：
- 输入特征维数
- 输出特征维数


----

下面对**两种用途的全连接层**，做一个讨论

### 回归
以上的一个全连接层构成的<font color="#ff0000">FNN前馈神经网络</font>。这个模型输出的都是<font color="#ff0000">回归</font>，也就是**预测一个值**，比如价格，场次，天数（int, float这些）

这里，我们主要关注**<mark style="background:#fff88f">每个输出维度的值</mark>**。



#### torch库定义层+初始化参数

**torch库**可以方便的帮我们提供一个全连接的对象，以及初始化权重矩阵，偏置矩阵的方法
- `.weight.data` 用来访问权重矩阵**W**
- `.bias.data` 用来访问偏置向量**b**

```python
from torch import nn

"""定义一个输入维数为2， 输出维数为1的全连接层"""
fc1 = nn.Linear(2,1)

"""权重矩阵W.normal_正太分布，期望为0， 方差为0.01的随机初始化"""
fc1.weight.data.normal_(0, 0.01)
"""偏置向量b.fill_全部0填充"""
fc1.bias.data.fill_(0)
```


#### torch 构造model对象
```python

"""
from torch import nn
	nn就是torch里面的神经网络库文件
torch.nn库， 提供了各种构造model对象的方法和类定义
用全连接层组成一个网络"""
model=nn.Sequential(fc1)
```


#### torch 创建损失函数对象
```python

"""
torch.nn库，提供了各种损失函数的类定义
"""
loss=nn.MSELoss() #就是均方误差：Mean Squared Error, MSE
```
![[../images/Pasted image 20260429153432.png|202]]

#### torch 优化器对象
```python
"""
torch.optim库，提供了各种优化器的类定义
"""

optim = torch.optim.SGD(model.parameters(), lr=0.01)
```
可以看到，我们每次用Loss来自动求导后，梯度分量全部存放在W，b这些模型参数对象的.grad属性里面。所以，优化器仅需要知道模型参数对象即可。
![[../images/Pasted image 20260429153921.png|545]]

> 右边的平均梯度，就是我们反向传播自动求导的梯度，已经存放在参数对象里面了。


#### 训练过程
```python
model.train() #设置model对象，能够修改模型参数
for epoch in range(3):
	for X,y in data_iter:
		l = loss(net(X), y) # 使用损失函数对象的仿函数（预测值，标签值），固定好Loss损失函数的系数
		optim.zero_grad() # 让优化器来清除模型参数对象中的梯度值
		l.backward() # Loss(w,b)计算平均梯度，写入模型参数对象中
		optim.step() # 利用学习率 + 平均梯度，更新模型参数。
	
	# 该epoch训练完成，输入测试集，计算出当前的Loss(w,b)损失,正常情况下，每轮训练后，损失是会下降的。
	l = loss(model(features), labels)
	print("epoch %d, loss %4f" % (epoch, l))
	
	
	
"""
epoch 1, loss 0.000248
epoch 2, loss 0.000103
epoch 3, loss 0.000103
"""
```



### 分类（softmax回归）
但是，有时候，我们不关心具体的值，我们只关心是0/1，也就是bool。也就是我们希望输出是一哪一个？是不是？

这个时候，我们关注的是：<mark style="background:#fff88f">输出哪个维度的位置</mark>， 或者<mark style="background:#fff88f">单个输出维度的二值性</mark>

这两种关注角度都可以实现我们的分类需求：
- 输出3个维度（猫，狗，人）进行分类
- 输出一个维度（输入1， 有人；输出0，没人）

#### 分类问题中 标签的处理
因为是分类问题了，所以期望输出，要么关注输出的维度的位置，要么关注输出维度的二值性。

所以数据集中的标签，要做对应的one-hot编码，才能表示位置。
![[../images/Pasted image 20260429161417.png|616]]


#### 网络架构
为了估计所有可能的类别的条件概率。我们肯定需要一个至少单层的模型，有多个输出，**每个类别对应一个输出**。

所以**结构仍然是一个全连接层**。
- 输入维度4
- 输出维度3（分类3类）
- 权重矩阵（W）
- 偏置向量（b）
![[../images/Pasted image 20260429162514.png|310]]
![[../images/Pasted image 20260429162617.png|129]]


所以softmax回归，本质上，并不是网络结构的变化，而是对输出内容的理解发生了变化，也就是数据集的标签发生了变化。

#### softmax运算

现在我们的模型的每一个输出，都能回归出一个值，范围是随机一个数字, 因为每个输出的标签不是0，就是1.

这就会导致，三个输出回归出来的值可能是这样{0.7，0.4， 0.9}

光看这个值，看不出这个回归出来的每个类别的打分，有什么意义
- （不是概率，因为和不为1）
- （每个输出，也可能回归出负数）

所以，**要将每个输出，改造成概率**。要做到：
- 每个类别，输出非负
- 总和为1

所以，对输出，做一个**softmax处理**，**全部去e的幂次方，然后取比例权重**。
![[../images/Pasted image 20260429163349.png|329]]

然后选择最大的概率的那个，就是我们识别出来的分类。

![[../images/e0610a65f2c46ef7fa66e1d0d4b58987.jpg|425]]
#### 交叉熵损失函数
前面在讲全连接层回归的时候，我们使用的是**均方误差损失函数**。

但是在这种分类问题中，我们一般不适用均方误差函数。因为我们设置损失函数，本质上就是希望，能去衡量出模型的优劣，具体说就是，能够反应预测值与标签值的差距大小嘛。

而我们的标签值是独热编码（1，0，0）这种。而我们的预测值，是softmax函数处理之后的每个分类的概率（0.7，0.2，0.1）这种。通过观察可以发现。

我们通过使用交叉熵损失函数，定义如下：
![[../images/Pasted image 20260430155259.png|242]]
这个是单个样本的损失，可以看到，yj是标签，yj' 是预测的值，q是类别的数量。

所以，当我们**输入一个样本之后**，这个<font color="#ff0000">交叉熵损失函数</font>，就可以很好的衡量，这个**预测的值准不准**。
![[../images/bc5f08e1c597558a63eeca363043e869.jpg|379]]


使用**交叉熵损失函数**，反向传播的时候，和多层回归最大的不同，就是，多了一个softmax环节嘛。

那么同样利用链式法则，把softmax()函数当成一个激活环节，把前面的输入作为预激活输出。这样**只要知道Loss对预激活输出的梯度**，这样就可以和前面的多层反向传播对上了[[#^e096f0]]

所以我们将<mark style="background:#fff88f">y = softmax(o）</mark>代入**loss**，然后求导即可。

![[../images/Pasted image 20260430190334.png|418]]


以上就解释了单个样本的损失，当一个batch有多个样本的时候，我们通常就是所有样本的损失加起来，求平均，得到平均损失。

![[../images/Pasted image 20260430191253.png|518]]

#### torch实现softmax回归

> 如果我们要从零开始实现，也很简单，就是自己实现前向传播的公式就行了，torch构建出的计算图，就是为了实现数学公式，比较麻烦的是，要自己计算，记录，传播。


```python
import torch
import torch.nn as nn
from d21 import torch as d21


"""数据集"""
# 一批数据集是256个样本
batch_size = 256
# 准备好数据集的迭代器
train_iter, test_iter = d21.load_data_fashion_mnist(batch_size)


"""模型"""
# nn.Flatten()展平层，是把一张单通道图片样本（1x28x28）(通道x高度x宽度)压平
# 就一层FNN
net = nn.Sequential(nn.Flatten(), nn.Linear(784,10))

# 初始化模型参数
def init_weights(m):
	if type(m) == nn.Linear:
		nn.init.normal_(m.weight, std=0.01)
		
net.apply(init_weights)


"""损失函数对象
pytorch里面，softmax()函数，通常不放在模型里面。而是集成在交叉熵损失函数里面。

reduction='mean', 表示返回一个标量：所有样本的损失的平均值，求出来的就是平均梯度了。
reduction='sum', 表示返回一个标量：所有样本的损失的和
reduction='none', 返回每个样本的损失构成的张量

所以你可能还需要手动求平均，
"""
loss = nn.CrossEntropyLoss(reduction='none')



"""创建优化器对象
优化器对象，需要平均梯度
"""
trainer = torch.optim.SGD(net.parameters(), lr=0.1)



"""训练"""
num_epochs=10
d21.train_ch3(net, train_iter, test_iter, loss, num_epochs, trainer)

```
![[../images/Pasted image 20260430193558.png|246]]


有几点需要注意：
- pytorch里面，**`softmax` 通常不放在模型里面**，而是集成在 **`nn.CrossEntropyLoss`** 损失函数中直接计算。
	- 原因：如果你先在模型里算 `softmax`，得到的概率 $\hat{y}_j$ 可能会因为非常小而被计算机四舍五入成 **0**（下溢）
	- 当损失函数接着去计算 $\log(\hat{y}_j)$ 时，$\log(0)$ 会变成 **$-\infty$
	- 从而使模型容易跑崩。


- pytorch里面，创建**损失函数对象**，loss=nn.MSE()，然后使用的时候，是传入loss(预测值，标签值)，**为什么不需要知道模型参数**？
	- 当你执行 `预测值 = model(输入)` 时，PyTorch 会在后台悄悄建立一张**计算图**
	- 这个 `预测值` 张量内部包含了一个指向生成它的操作（比如线性层、激活函数）的指针，而这些操作又连接着模型的 **权重（weight）** 和 **偏置（bias）**



## FNN 前馈

前面我们从最简单的线性回归单元->全连接层->单层/多层全连接回归模型->softmax回归

前面重心放在理解，数据，模型，损失函数，梯度下降，softmax。

下面，我们来具体的研究模型这件事，首先第一个就是FNN，**多个全连接层组成的神经网络**，也叫**多层感知机MLP**
### 多层感知机MLP

前面我们的一层全连接层， `z = wx + b`, 本质上都是**线性的映射**(<mark style="background:#fff88f">仿射变换</mark>)

但是，我们很难使用一层全连接的线性映射，来表示特征x-> 标签y的映射。

所以，我们需要使用**多层全连接层**，也就是加入<mark style="background:#fff88f">隐藏层h1,h2,</mark>...


我们可以通过在网络中**加入一个或多个隐藏层来克服线性模型的限制**， 使其能**处理更普遍的函数关系**类型。 要做到这一点，最简单的方法是**将许多全连接层堆叠在一起**。 每一层都输出到上面的层，直到生成最后的输出


假设**L层 全连接层**，我们把**前面的L-1层，看作表示**，**最后一层看作线性预测器**。这种架构通常称为_**多层感知机**_（multilayer perceptron），通常缩写为_**MLP_**

![[../images/Pasted image 20260430203406.png|199]]

如上图所示，输入4个维度，输出3个维度，中间隐藏层的单元5个维度。这个MLP的层数为2

然而，这种层层堆叠的MLP，它的参数开销很高。所以在不改变输入，输出大小的情况下，对模型的参数和有效性之间要衡量一下。


### 激活函数

前面我们提到的MLP的，他的各层全连接层，是首位相接的，但是，这会有一个问题：
<mark style="background:#b1ffff">线性函数带入线性函数，还是线性</mark>，这回导致维数下降。

所以，为了发挥多层架构的潜力，我们还需要一个关键的连接因素：
<mark style="background:#fff88f">在仿射变换之后，对每个隐藏单元，应用非线性的激活函数</mark>， **激活函数的输出**，被称为**活性值**

有了激活函数，就不可能再将我们的多层感知机退化成线性模型
![[../images/Pasted image 20260430204132.png|211]]

全连接层输出（预激活值）`z = wx + b`
隐藏层单元（活性值）`h=σ（z）`
最后一层的线性预测器（输出）`o =wh + b`

这样之后，模型才能充分发挥各层的潜力。

#### ReLU函数

**ReLU()函数** ， 也叫**修正线性单元**
![[../images/Pasted image 20260430204614.png|171]]
![[../images/Pasted image 20260430204640.png|295]]

ReLU(x)
当x < 0, 导数为0， 当x > 0, 导数为1， x=0处的导数为0

<mark style="background:#fff88f">ReLU函数的好处</mark>是：
- **求导表现特别好**（反向传播计算梯度的时候）
	- 要么让参数消失，要么让参数通过
- **减轻了梯度消失问题**


ReLU函数变体：
- 参数化ReLU， pReLU
	- ![[../images/Pasted image 20260430205013.png|232]]



#### sigmoid函数

sigmoid函数，将输入变换为区间（0，1）上的输出。

![[../images/Pasted image 20260430205414.png|250]]

![[../images/Pasted image 20260430205420.png|295]]

可以看到，sigmoid函数，是一个平滑，可导的阈值单元的近似。

当我们想要将输出看成是二元分类问题的概率时，就可以来用了。不过隐藏层用的较少
> 可以看到，sigmoid函数，本质上就是想把任意x的取值，往0/1上去近似映射。

> RNN里面，利用sigmoid单元来控制时序信息流的架构。


sigmoid函数，求导之后，可以看到，x=0处，导数最大到0.25
![[../images/Pasted image 20260430205939.png|267]]





#### tanh函数

tanh函数，和sigmoid函数类似，不过他映射的范围不是（0，1），而是（-1，1）

![[../images/Pasted image 20260430205829.png]]
![[../images/Pasted image 20260430205836.png|322]]

这个tanh函数求导后，x=0处取导数最大值1
![[../images/Pasted image 20260430210025.png|243]]




### torch实现MLP

下面用torch库来实现多层感知机，先来定义一下模型，并初始化模型参数‘

pytorch支持**自动挡** 创建模型
```python
import torch
from torch import nn

"""
d2l是 动手学深度学习的 辅助库，就是个教学工具包
"""
from d21 import torch as d21


"""模型"""
net = nn.Sequential(nn.Flatten(), # 多加一个这个是为了读取图片
					nn.Linear(784,256),
					nn.ReLU(),
					nn.Linear(256,10))

def init_weights(m):
	if type(m) == nn.Linear:
		nn.init_normal_(m.weight, std=0.01)
		
# net.apply 里面定义一个针对层的巡检规则，如果是线性层，就初始化参数为正态分布
net.apply(init_weights)

```

也支持**手动挡** 创建模型
```python
class MyModel(nn.Module):
	def __init__(self):
		super().__init__()
		self.fc = nn.Linear(784, 256)
		
		# 直接初始化
		nn.init.normal_(self.fc.weight, std=0.01)
		nn.init.constant_(self.fc.bias, 0)
		
	def forward(self, x):
		# ...

```


以上使用`nn.init.normal_(self.fc.weight, std = 0.01)` 是手动挡实现层的参数初始化。

也可以使用**自动初始化**，**通过根据层的输入输出神经元数量**，来自动调整初始化范围, 这样就**不用自己指定标准差了**
- **Xavier 初始化**（适用于 Sigmoid/Tanh）：`nn.init.xavier_normal_(m.weight)`
- **Kaiming 初始化**（适用于 ReLU）：`nn.init.kaiming_normal_(m.weight)`


定义好了模型，下面开始获取数据，定义损失函数，优化器，然后训练

```python
batch_size, lr, num_epochs = 256, 0.1, 10
loss = nn.CrossEntropyLoss(reduction='none')
trainer = torch.optim.SGD(net.parameters(), lr=lr)

train_iter, test_iter = d2l.load_data_fashion_mnist(batch_size)
d2l.train_ch3(net, train_iter, test_iter, loss, num_epochs, trainer)
```


### 模型选择，欠拟合，过拟合

我们希望模型，能够真正发现一种泛化模式，而不是简单的记住数据。所以希望有泛化能力。


> 损失，是针对单个样本来说的；误差，是针对整个数据集的宏观表现，比如RMSE

<mark style="background:#affad1">误差分类</mark>：
- **训练误差**：模型在训练集上的loss损失
- **泛化误差**：模型应用在从原始样本分布中抽取的无限多数据样本时，误差的期望。我们在测试集上算出的误差，本质上是对泛化误差的一种估计


<mark style="background:#affad1">几个影响模型泛化的因素</mark>：
1. 可调整**参数的数量**。当可调整参数的数量（有时称为_自由度_）很大时，模型往往更容易过拟合。
2. **参数采用的值**。当权重的取值范围较大时，模型可能更容易过拟合。
3. **训练样本的数量**。即使模型很简单，也很容易过拟合只包含一两个样本的数据集。而过拟合一个有数百万个样本的数据集则需要一个极其灵活的模型。


<mark style="background:#affad1">把数据集分成3块</mark>：
- 训练集：来训练模型（课后作业）
- 验证集：用来选择模型（模拟考）
- 测试集：用来得出最终选择的模型的性能（高考）


<mark style="background:#affad1">K折交叉验证</mark>
当训练数据稀缺时，把训练数据分成K个子集。然后**执行K次训练和验证**：**每次在K-1个自己上训练，并在剩余一个子集上验证**。最后结果取平均来估计训练误差和验证误差



<mark style="background:#affad1">模型泛化性能</mark>
![[../images/Pasted image 20260430220121.png|307]]
**过拟合**：训练集上效果好，但是测试集效果不好
- 解决办法：
	- <mark style="background:#fff88f">正则化</mark>
	- 增加数据量
**欠拟合**：训练集效果不好，测试集效果也不好
- 解决办法：
	- 增加模型复杂度
	- 输入更多维度的数据
	- 增加训练轮次
	- 减少正则化


### 权重衰退（正则化）


## CNN 卷积
## RNN 循环卷积







# torch 损失函数
# torch 训练
# torch 评估
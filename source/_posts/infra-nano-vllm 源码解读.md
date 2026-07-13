---
title: infra nano-vllm 源码解读
categories: [学习笔记, 大模型算法]
tags: [vLLM, AI Infra]
---


本小节，主要来通过nano-vllm的源码解读，来了解推理系统vllm的整个架构设计，推理优化的点，并最终实现手写nano-vllm。


# 项目架构
这里先分析一下整个nano-vllm的项目架构

`nano-vllm` 是一个教学级别的轻量化 vLLM**推理引擎**实现

整体框架图如下：
![](../images/Pasted%20image%2020260516183919.png)![](../images/Pasted%20image%2020260516184129.png)

所以，总共包含4个部分：
- API层，提供用户接口，比如对话等
- 引擎层：提供调度，内存管理
- 模型层：提供算子+模型定义
- 工具层

## api层
这一层主要就是面向用户的接口封装：

用户只需 `LLM(model_path, ...)` + `llm.generate(prompts, sampling_params)` 两行即可完成推理
```bash

├── config.py                 # ⚙️ 配置管理
├── llm.py                   #   用户接口入口
└── sampling_params.py       #   采样参数定义
```




## 引擎层
这是vllm的核心
```bash
├── engine/                    #   推理引擎核心
│   ├── llm_engine.py         #   └── 总协调器，驱动整个推理流程
│   ├── scheduler.py          #   └── 智能调度器，决定执行顺序
│   ├── block_manager.py      #   └── KV缓存内存管理 (PagedAttention核心)
│   ├── model_runner.py       #   └── 单GPU上的模型执行器
│   └── sequence.py           #   └── 请求序列的数据结构
```

## 模型算子层
这一层主要提供推理框架

```text
├── layers/                    # ⚙️ 神经网络层实现
│   ├── attention.py          #   └── FlashAttention + KV缓存管理
│   ├── sampler.py            #   └── 从logits采样生成token
│   ├── linear.py             #   └── 支持张量并行的线性层
│   ├── layernorm.py          #   └── RMS LayerNorm
│   ├── rotary_embedding.py   #   └── 旋转位置编码 (RoPE)
│   ├── activation.py         #   └── 激活函数 (SiLU)
│   └── embed_head.py         #   └── 词嵌入和语言模型头
├── models/                    #  ️ 具体模型架构
│   └── qwen3.py              #   └── Qwen3模型完整实现
```

注意，这里我们的nano-vllm，并没有完全脱离pytorch，而是在torch的基础上，做了定制和优化。

![](../images/Pasted%20image%2020260516185301.png)

各层的实现不同
![](../images/Pasted%20image%2020260516185311.png)

相当于就是对大模型的各个主要组件（算子），为了解决他们的性能问题，而进行了重构

![](../images/Pasted%20image%2020260516185412.png)
主要有：
- FlashAttention, 解决注意力计算的O(n2)的显存问题
- FFN，解决张量并行问题（TP）
- Triton KVCache kernel, 解决高效写入KV Cache的问题
- 融合算子

所以本质上，nano-vllm是重写的模型推理涉及的6个特定nn库里面的层：

```
PyTorch 提供的                   nano-vllm 复写的
───────────────                 ─────────────────
nn.Linear          ──→   自定义 Linear（加 TP 权重切分）
nn.Embedding       ──→   自定义 Embedding（加 Vocab Parallel）
nn.LayerNorm       ──→   自定义 RMSNorm（加 residual fused）
nn.MultiheadAttention ─→ 自定义 Attention（FlashAttention + KV Cache）
无                  ──→   Sampler（Gumbel-max 采样）
无                  ──→   RotaryEmbedding（RoPE 位置编码）
```

![](../images/Pasted%20image%2020260516185921.png)

## 工具层
```text
├── utils/                     #   工具模块
│   ├── context.py            #   └── 全局上下文状态管理
│   └── loader.py             #   └── 模型权重加载器
```


#  数据处理流程
```text
用户输入 → Tokenizer → Sequence → Scheduler → ModelRunner → Model → Sampler → 输出

详细展开：
prompts     token_ids    Sequence     scheduled    input_ids    logits   token_ids    decoded_text
  ↓            ↓           ↓           seqs          ↓           ↓          ↓            ↓
"Hello"  →  [123,45]  →  Seq#1    →  [Seq#1]   →  tensor   →  tensor  →    67      →  " world"
"Hi"     →  [89,12]   →  Seq#2    →  [Seq#2]   →  [...]    →  [...]   →    23      →  " there"
```

---

# python语法补充
![379](../images/Pasted%20image%2020260517134106.png)

----



## 类型注解

简单来说，这是在告诉 Python（以及阅读代码的人）：**“这个变量应该是某种特定的类型”。**

Python 本身是动态类型语言（变量可以随时改变类型），但类型注解能让代码更易读、减少 Bug，并且让 IDE（如 VS Code/PyCharm）提供更精准的代码补全

```python
model : str
```
- **语法：** `变量名: 类型`
- **理解：** 声明 `model` 变量应该是一个**字符串（string）**。这只是个标注，不会强制阻止你给它赋值数字，但静态检查工具（如 MyPy）会报错。


```python
max_tokens: int = 64
```
- **语法：** `变量名: 类型 = 默认值`
- **理解：** 声明 `max_tokens` 是**整数（integer）**，并且它的初始值是 `64`。

```python
prompts: list[str] | list[list[int]]
```
- **语法：** `A | B` (Python 3.10+ 的新写法)
- **理解：** `|` 符号读作 **“或者”**。
    - 它可以是一个字符串列表：`["hello", "world"]`
    - **或者**是一个嵌套的整数列表：`[[1, 2], [3, 4]]`

```python
hf_config: AutoConfig | None
```
- **语法：** `类型 | None`
- **理解：** 表示这个变量**要么**是一个 `AutoConfig` 对象，**要么**是 `None`（空）。

```python
segs: list[Sequence]
```
- **语法：** `容器类型[内部元素类型]`
- **理解：** 这是一个**列表**，但列表里的每一个元素都必须符合 `Sequence`（序列）协议（比如列表、元组或字符串）。


## python一切皆对象

- 整数 `1` 是对象
- 字符串 `"hello"` 是对象
- 列表 `[]` 是对象
- 函数 `def func():` 是对象
- **类 `MyClass` 是 **`type` 类的实例**。

所以，定义一个class Book,他有很多属性

```python
class Book:
	xxx
	
Book.xxx 这里面有
	__annotations__, 是一个字典（哈希表），里面存放的是类/方法里面的所有类型注解
	author: str, 这种属于类的类型注解
	__base__,    该类的父类（类型，默认是object类<class 'object'>）
		Book 类，**直接父类（继承的类）是 `object`**，所以 `Book.__base__` 是 `object`
	__bases__,   该类的所有父类集合（元组）
	__basicsize__, 类对象的内存占用字节数
	__call__,    方法, 类对象的仿函数
	__class__,    
		Book 类，是 `type` 这个元类的实例（对象）**，所以 `Book.__class__` 是 `type`       __delattr__, 方法, 删除对象属性时会调用的方法（比如 `del obj.title`）
	__dict__,  字典
		类的命名空间，存所有类属性、方法（包括你写的 `title`/`author`，以及自动生成的特殊方法）
	
```
![476](../images/Pasted%20image%2020260517112701.png)

所以，一个类，默认有三个方法：
- __init__
- call
- delattr

**当然这不是全部，一个类实例，有很多个方法**
![414](../images/Pasted%20image%2020260517112943.png)
![465](../images/Pasted%20image%2020260517113006.png)

**因为 Python 的 `object` 类默认提供了这些方法的基础实现。**

![256](../images/Pasted%20image%2020260517113108.png)


### 常用的类实例的方法
**`__repr__`**：重写它，让 `print(obj)` 输出好看的信息，而不是 `<Book object at 0x...>`。

**`__eq__` / `__hash__`**：如果想让对象可以用 == 比较，相当于重载

**`__getattr__` / `__setattr__`**：需要自定义属性访问逻辑时（比如做代理、动态属性）

**`__call__`**：想让对象可以像函数一样被调用时（比如 `obj()`）







---




## dataclass装饰器

**<mark style="background:#affad1">装饰器</mark>**
就是一个自动插件，你写好一个基础的类，加上这个帽子，就可以在后台自动为你的基础类添加很多功能。

```python
@dataclass(slots = True)
class mybase:
	
```

所以装饰器的作用，就是帮你默认改造上面**类实例的一些默认方法**

### dataclass改造的方法

<mark style="background:#affad1">dataclass</mark>
`dataclass` 是 Python 3.7 引入的一个模块，专门用来创建**只负责保存数据**的类。

改造了哪些方法呢？

1. **__init__方法**

自动识别你的类型注解，然后写入你的init来帮你构造初始化函数

![246](../images/Pasted%20image%2020260517113537.png)


2. **__repr__方法

**格式化打印方法**， 没有写的话，打印对象，默认会打印地址，相当于重载了<<



3. **__eq__**
重载==


4. <mark style="background:#fff88f">如果开启了order=True参数</mark>![](../images/Pasted%20image%2020260517113958.png)
5. `frozen=True` → 让对象不可修改![](../images/Pasted%20image%2020260517114049.png)
6. `slots=True`![](../images/Pasted%20image%2020260517114236.png)
正常，我们是通过__dict__字典，来查看所有的成员变量的，也可以动态增减成员属性。但是占内存，速度慢

<mark style="background:#fff88f">而开启了slots之后，就等于锁死了属性，不能动态增减属性，但是内存占用少了，访问速度更快，但是没有__dict__了。</mark>

![300](../images/Pasted%20image%2020260517114445.png)![363](../images/Pasted%20image%2020260517114509.png)



---

## 属性装饰器

`@property` 是一个装饰器，能把类里的**方法伪装成属性**，让你可以像访问普通变量一样调用它，但底层执行的是函数逻辑。

### 三种基本用法


1. **只读属性**

某个值是计算出来的，不想让用户直接修改
![379](../images/Pasted%20image%2020260517115122.png)

这样可以实现一个只读属性


2. **属性写校验**

我们在修改某个属性时，想要先校验，因为直接修改属性肯定无法校验，所以需要用
@[属性].setter

**来设置这个属性的写入方法**

注意：`@name.setter` 是 `property` 的语法糖，它必须跟在 `@property` 装饰的 `name` 方法后面才能用。所以必须依赖@property才行



3. **可删除属性**

`@xxx.deleter`，不常用
场景：删除属性时需要做清理工作。



### 语法糖

语法糖（Syntactic Sugar），就是「让代码写起来更甜、更舒服，但功能上没有任何变化的语法」。

它本质上是语言给你提供的「便捷写法」，底层会自动帮你转换成等价的、更繁琐的代码，让你少写重复、难看的代码。
![480](../images/Pasted%20image%2020260517120306.png)

---


## 协议（Protocol）

```python
# sequence.py
class Sequence:
    def __len__(self):           # 实现后可以用 len(seq)
        return self.num_tokens

    def __getitem__(self, key):  # 实现后可以用 seq[3] 取值
        return self.token_ids[key]

    def __getstate__(self):      # 控制 pickle 序列化行为
        ...

    def __setstate__(self, state):  # 控制 pickle 反序列化行为
        ...
```


### Python 数据模型（Data Model）（魔术方法/双下方法）

这一块属于python 协议 编程的核心：**只要你在类里实现了特定的魔术方法，你的对象就可以表现得像内置类型（如列表、字典、数字）一样**。


<mark style="background:#affad1">容器与序列协议 (Container/Sequence Protocol)</mark>

类里面实现的__len__, __getitem__ 这些方法，能够把我自己的类伪装成一个列表/元组

- **`__len__(self)`**:
    - **触发方式：** 调用 `len(obj)`。
    - **作用：** 返回对象的长度。

- **`__getitem__(self, key)`**: **数组下标访问**
    - **触发方式：** 使用索引取值 `obj[key]`。
    - **作用：** 定义如何获取数据。支持 `key` 为整数（索引）或 `slice` 对象（切片 `obj[1:3]`）。


```python
	# 注意这个方法只能返回整形int
    def __len__(self):
        return 10
        
    def __getitem__(self, key):
        return "i find key value"


book = Book_new("test","liangji", 1000)
print(len(book))
print(book[1])
```



<mark style="background:#affad1">生命周期与初始化 (Lifecycle)</mark>

- **`__init__(self, ...)`**: 初始化对象。
- **`__new__(self, ...)`**: 真正创建实例的方法（在 `__init__` 之前执行，常用于单例模式）。
- **`__del__(self)`**: 析构方法，当对象被垃圾回收时触发


<mark style="background:#affad1">序列化协议 (Serialization)</mark>

- **`__getstate__(self)`**:
    - **作用：** 当你尝试“打包”（序列化）一个对象存入磁盘或在网络传输时，这个方法决定哪些数据被保存。
    - **场景：** 如果类里有一个巨大的临时缓存或无法序列化的文件句柄，你可以通过这个方法把它们排除在外。
        
- **`__setstate__(self, state)`**:
    - **作用：** “拆包”（反序列化）时，如何根据保存的数据重建对象。

```python
import pickle

class MyClass:
    def __init__(self, name, file_handle):
        self.name = name
        self.file_handle = file_handle

    def __getstate__(self):
        state = self.__dict__.copy()
        del state['file_handle']
        return state
    
    def __setstate__(self, state):
        self.__dict__.update(state)
        self.file_handle = open(f"{self.name}.txt", "w")

if __name__ == "__main__":
    obj = MyClass("demo", open("demo.txt", "w"))

    serialized_data = pickle.dumps(obj)
    print("ok")

    restored_obj = pickle.loads(serialized_data)
    print("ok")

    print(f"name: {restored_obj.name}")
    print(f"file_handle 是否重建: {restored_obj.file_handle is not None}")

    restored_obj.file_handle.close()
```

![](../images/Pasted%20image%2020260517140210.png)

其实说白了，就是特地指定哪些能打包序列化，哪些不用打包序列化


<mark style="background:#affad1">对象表示 (Object Representation)</mark>

决定对象在不同环境下如何显示。

- **`__str__`**: `print(obj)` 时显示的对用户友好的字符串。
- **`__repr__`**: 开发调试时显示的字符串（应尽量能通过 `eval(repr(obj))` 还原对象）。

```python
class Person:
    def __init__(self, name, age):
        self.name = name
        self.age = age

    # 给用户看的友好信息
    def __str__(self):
        return f"Person对象：名字是 {self.name}，年龄是 {self.age}"

    # 给开发者调试用的，最好能通过eval还原对象
    def __repr__(self):
        return f"Person('{self.name}', {self.age})"


# 测试
if __name__ == "__main__":
    p = Person("小明", 18)

    print("=== 直接print(obj) 会调用 __str__ ===")
    print(p)  # 输出：Person对象：名字是 小明，年龄是 18

    print("\n=== 交互环境/调试/repr() 会调用 __repr__ ===")
    print(repr(p))  # 输出：Person('小明', 18)

    print("\n=== eval(repr(obj)) 可以还原对象 ===")
    p2 = eval(repr(p))
    print(p2.name, p2.age)  # 输出：小明 18
```

![](../images/Pasted%20image%2020260517140646.png)


## 枚举类

```python
from enum import Enum, auto

class status(Enum):
    STATUS_A = auto()  # 自动分配1
    STATUS_B = auto()  # 自动分配2
    STATUS_C = auto()  # 自动分配3

current_status = status.STATUS_A
print(status.STATUS_A)
```

![599](../images/Pasted%20image%2020260517141036.png)

Enum是枚举类的基类，auto是一个函数估计，提供自动计数，防止重复



## 另外的装饰器

**装饰器的本质是一个“包装器”，在不修改原函数内部代码的前提下，为函数增加额外的功能。**

### pytorch装饰器
在sampler.py， model_runner.py这种速度要求高的文件里面，有以下两种装饰器

#### @torch.compile (内核编译优化)

- **语法点：** 这是 PyTorch 2.0+ 的核心特性。
- **背后的原理：** 默认情况下，Python 是“一行一行”执行代码的（解释型）。这个装饰器会把 Python 函数转换成高度优化的**中间表示 (IR)**，然后针对 GPU 生成专门的内核代码（Triton 内核）。
- **效果：** 极大地减少 CPU 启动开销（Overhead），提高 GPU 的吞吐量。它让你的 Python 代码跑起来接近 C++ 的速度。



#### @torch.inference_mode() (上下文管理)
- **语法点：** 这是一个**带括号**的装饰器（实际上是一个装饰器工厂）。
- **背后的原理：** 它告诉 PyTorch：“我现在的操作只是为了推理（预测），不是为了训练。”
- **效果：**
    - **关闭梯度计算**（不记录反向传播所需的中间变量）。
    - **减少显存消耗**。
    - **性能更快**（比旧的 `with torch.no_grad():` 甚至还要更快一些）。



### functools工具类装饰器

#### @lru_cache(maxsize=1) (最近最少使用缓存)

- **语法点：** `lru_cache` 来自标准库 `functools`。
- **背后的原理：** 它给函数增加了一个“备忘录”。当你第一次用参数 `A` 调用 `get_rope` 时，它计算结果并存起来；第二次用同样的参数调用时，它直接从内存里拿结果，不再执行函数内部逻辑。
- **场景：** 在大模型中，`get_rope`（获取旋转位置嵌入）通常涉及复杂的三角函数计算。因为模型的旋转位置编码在运行中通常是固定的，所以用 `maxsize=1` 缓存住最近一次的结果，可以省去每一层都重复计算的开销。



## 装饰器的基本知识

要掌握这一块语法，你需要理解以下三个层级：

| **层级**  | **表现形式**               | **核心作用**                                    |
| ------- | ---------------------- | ------------------------------------------- |
| **基础层** | `def decorator(func):` | 理解装饰器本质是一个接收函数并返回函数的高阶函数。                   |
| **进阶层** | `@decorator(args)`     | 理解带参数的装饰器（如 `lru_cache(1)`），它先执行函数生成真正的装饰器。 |
| **工程层** | `@torch.compile` 等     | 掌握在特定框架中，如何利用装饰器**无侵入**地实现**性能优化**。         |



## 基础数据结构

### 双端队列deque

**就是双向链表**，数据可以从两头进，也可以从两头出。

因为是双向链表，所以，增，删首尾节点的时间复杂度是O（1），对比list，增加删除最后一个元素是O（1），但是增删第一个元素是O（n）



1. **添加元素（push）**
	1. .append(x): 尾部插入
	2. .appendleft(x):队首插入（高优先级立刻处理）
2. **弹出元素（pop）**、
	1. pop(): 从队尾取出一个并删除
	2. popleft(): 从队首取出一个并删除（调度器常用，获取下一个待处理的任务）
3. **批量操作(Extend)**
	1. extend(iterable): 在右侧批量添加
	2. extendleft(iterable): 在左侧逐个批量添加（最终方向相反）
4. **特殊功能（限制长度）**
	1. d = deque(maxlen=10)
		1. 满了之后，右边加一个，左边会被挤掉一个，用于处理**滑动窗口**或者**最近日志记录**

![](../images/Pasted%20image%2020260517142819.png)


deque的初始化，
```python
from collections import deque

dq = deque([1,2,3])
```
元素可以是任意类型，只要是可迭代对象，就能进行初始化

<mark style="background:#affad1">判断一个对象是否是可迭代的</mark>
```python
from collections.abc import Iterable 

print(isinstance([1,2,3], Iterable)) # True 
print(isinstance("abc", Iterable)) # True 
print(isinstance(123, Iterable)) # False
```

#### isinstance 类型检查
其中`isinstance` 是 Python **最常用、最重要**的内置函数之一，专门用来**判断一个对象 是不是 某种类型**。

```python
isinstance(要检查的对象, 类型)
```
返回结果：**True / False**


```python
# 判断 100 是不是 int 类型 
print(isinstance(100, int)) # True 

# 判断 "abc" 是不是 str 类型 
print(isinstance("abc", str)) # True 

# 判断 [1,2] 是不是 list 类型 
print(isinstance([1,2], list)) # True
```



### itertools.count类

`itertools.count()`, 为了给每一个**新生成的对象**（比如一条 Sequence/请求）分配一个**全局唯一的 ID**

它是 Python 内置标准库中的一个**无限迭代器**。

- **形象理解**：它就像一个永不停歇的计数器。你不需要告诉它什么时候停止，只要你找它要（调用 `next()`），它就会给你下一个数字。
- **默认行为**：如果不传参数，它从 `0` 开始，步长为 `1`。即：`0, 1, 2, 3...`

```python
from itertools import count

# 1. 创建计数器对象
counter = count(start=10, step=2)  # 也可以自定义起点和步长

# 2. 获取下一个值
print(next(counter)) # 10
print(next(counter)) # 12
print(next(counter)) # 14
print(next(counter)) # 16
```


### 列表推导式

`outputs = [outputs[seq_id] for seq_id in sorted(outputs.keys())]`

- **外层 `[]`**：表示最终结果是一个列表。
- **`outputs[seq_id]`**：这是**结果表达式**（你想存进列表里的东西）。
- **`for seq_id in sorted(outputs.keys())`**：这是**迭代逻辑**。它先获取字典所有的键，排序，然后逐个取出。

### 字典推导式
`config_kwargs = {k: v for k, v in kwargs.items() if k in config_fields}`

其中：`items()` 是**字典**（dict）的内置方法，**把字典里的所有「键值对」一次性取出来**。

> item() 这个是单数，他的作用是把只有一个元素的数组/列表，转换成一个值


### 集合推导式
就是返回的是set集合
`my_set = {x for x in [1, 2, 2, 3, 4, 4, 5] if x > 2}`



### enumerate
`enumerate` 是 Python 里一个**超常用、超好用**的内置函数，专门用来「遍历序列时，**同时拿到索引和元素**」

`enumerate` 就是给你要遍历的东西，**自动加上序号**，让你不用自己写 `i = 0; i += 1` 来计数。




### 常用数据结构对应表
1. **list 列表** = C++ `vector` 动态数组
2. **tuple 元组** = 只读不可变数组
3. **dict 字典** = 哈希表 `unordered_map`
4. **deque 双向队列** = 双向链表
5. **set 集合** = 哈希集合 `unordered_set`
    - 自动去重、判断成员超快
```
    s = {1,2,3}
```
6. **frozenset 不可变集合**
    - 不能增删，可当字典 key
7. **heapq 小顶堆** = 优先队列 `priority_queue`
    - 用来做 TopK、排序、任务优先级
8. **collections.defaultdict**
    - 带默认值字典，避免键不存在报错
9. **collections.OrderedDict**
    - 有序字典（3.7+dict 本身也有序）
10. **collections.Counter**
    - 计数统计神器，统计列表 / 字符串元素频次
11. **collections.namedtuple**
    - 命名元组，轻量级结构体
12. **array.array**
    - 纯同类型紧凑数组，比 list 省内存
13. **bisect 有序数组**
    - 维持列表有序，二分查找插入

#### 最简用途速记

- 存有序可改数据 → **list**
- 固定不变数据 → **tuple**
- 键值查找 → **dict**
- 头尾快速增删 → **deque**
- 去重、判存在 → **set**
- 排序优先取最值 → **heapq**
- 统计次数 → **Counter**
- 轻量结构体 → **namedtuple**



## 序列化pickle

**pickle 序列化**

```python
# model_runner.py
import pickle
data = pickle.dumps([method_name, *args])   # 对象 → 字节
method_name, *args = pickle.loads(data)      # 字节 → 对象
```

通常不仅仅是为了“保存到文件”，更多是为了“**跨进程通信**”。

- **序列化 (`dumps`)**：把内存中复杂的对象（比如列表、字典、甚至你自定义的类实例）“拍扁”成一串**字节流**（Binary）。  
- **反序列化 (`loads`)**：把这串字节流重新“吹气”膨胀，恢复成内存中一模一样的对象。

<mark style="background:#fff88f">1. 一般用在进程间通信上：IPC</mark>
大模型推理通常是多卡的。主进程（Master）负责分配任务，工作进程（Worker/GPU）负责计算
- 主进程把要执行的 `method_name` 和 `args` 用 `pickle.dumps` 变成字节，通过网络或管道（Pipe）发给 GPU 进程。
    
- GPU 进程收到后用 `pickle.loads` 还原，然后执行对应的函数

<mark style="background:#fff88f">2. 分布式对象传输</mark>
分布式训练或推理（Ray 框架或 Torch Distributed），对象需要在不同的物理机器之间传输。由于网线里**只能传二进制数据**，`pickle` 就充当了“打包员”

<mark style="background:#fff88f">3. 保存模型状态/检查点 (Checkpoint)</mark>
当你训练了一个模型，或者计算出了一些复杂的特征向量（Embeddings），你可以把它们 `pickle.dump` 到磁盘上。下次启动程序，直接 `load` 回来，不需要重新计算



<mark style="background:#affad1">pickle序列化的api</mark>
- `dumps` → 转字节（内存）
- `loads` → 从字节恢复
- `dump` → 存文件
- `load` → 读文件

```python
import pickle


data = {"name":"liangji", "age":18}
byte_data = pickle.dumps(data)
with open("data.pkl", "wb") as f:
    pickle.dump(data, f)


restore_data = pickle.loads(byte_data)
print(restore_data)

with open("data.pkl", 'rb') as f:
    loaded_data = pickle.load(f)

print(loaded_data)
```
![320](../images/Pasted%20image%2020260517153505.png)














#### 星号解包
| 符号   | 名字  | 作用                          |
| :--- | :-- | :-------------------------- |
| `*`  | 单星号 | 解包**位置参数**（列表 / 元组 / 可迭代对象） |
| `**` | 双星号 | 解包**关键字参数**（字典）             |
> 列表，元组/可迭代对象 + * 是拆分成多个对象
![514](../images/Pasted%20image%2020260517151011.png)、


**双星号解包，<mark style="background:#fff88f">关键字参数《-》字典的类型转换</mark>

> 字典 + ** 拆分成关键字


![](../images/Pasted%20image%2020260517151304.png)
```python
def func(*args, **kwargs):
    print(args) #(1, 2, 3)
    print(kwargs) #{'name': 'liangji', 'age': 18}


func(1,2,3, name="liangji",age=18)


```


## @classmethon 和 @staticmethod

|装饰器|自动传入的参数|能访问的内容|典型用途|
|:--|:--|:--|:--|
|`@classmethod`|`cls`（类本身）|类的属性、其他类方法|创建实例、工厂方法、修改类属性|
|`@staticmethod`|无|类和实例都不能直接访问|与类相关但不需要类信息的工具函数|
```python
class Person:
    species = "人类"  # 类属性

    def __init__(self, name):
        self.name = name

    # 1. 类方法：带 cls 参数
    @classmethod
    def create_from_dict(cls, data):
        # cls 就是 Person 这个类本身
        return cls(data["name"])  # 用类创建实例

    # 2. 静态方法：不带任何特殊参数
    @staticmethod
    def is_adult(age):
        # 纯工具函数，和 Person 类本身无关
        return age >= 18


# 测试
if __name__ == "__main__":
    # 用类方法创建实例
    p1 = Person.create_from_dict({"name": "小明"})
    print(p1.name)  # 小明

    # 用静态方法判断年龄
    print(Person.is_adult(20))  # True
```

**什么时候用 `@classmethod`？**

- 你需要在方法里**创建这个类的实例**（比如工厂模式）
- 你需要修改 / 访问**类属性**（比如统计创建了多少个实例）
- 你需要调用类的其他方法

 **什么时候用 `@staticmethod`？**

- 方法逻辑和类本身**完全无关**，只是 “名义上属于这个类”
- 不需要访问类属性，也不需要访问实例属性


## 断言 assert
“设卡检查”

`assert` 是一种调试辅助工具。它的逻辑非常简单粗暴：
- **如果条件为 `True`**：程序继续跑，像什么都没发生一样。
- **如果条件为 `False`**：程序立即“原地爆炸”（抛出 `AssertionError` 异常），并停止运行。

|**语法**|**含义**|
|---|---|
|**`assert <条件>`**|仅检查条件。|
|**`assert <条件>, <错误消息>`**|条件失败时，打印出你写的字符串，方便排查。|
|**性能提示**|如果在启动 Python 时使用了 `-O`（优化模式），断言会被**全部忽略**。|

在 `model_runner.py` 这种高性能代码中，区分这两种报错很重要：
- **`if...raise...`**：用于处理**预期内**的错误（比如用户输入了一个不存在的文件名）。即使发布了，也要保留。
- **`assert`**：用于捕捉**程序内部的逻辑错误**（开发者认为“这绝对不可能发生”的情况）。它主要在开发和测试阶段起作用。




# 整体推理架构梳理

```text
┌──────────────────────────────────────────────┐
│ nano-vllm                                    │  ← 你写的
│ 调度器 / BlockManager / 模型结构               │
├──────────────────────────────────────────────┤
│ PyTorch (torch.*)                             │  ← Python 深度学习框架
│ F.linear / nn.Module / tensor 操作            │
│ torch.cuda.CUDAGraph / dist.all_reduce         │
├──────────────────────────────────────────────┤
│ ATen + Torch Inductor                         │  ← PyTorch 的 C++ 后端
│ PyTorch 内部算子实现 + codegen                 │
├──────────────┬───────────────────────────────┤
│ FlashAttention  │ Triton                      │  ← 自定义 CUDA kernel(算子)
│ (预编译的 CUDA)  │ (DSL -> CUDA kernel)        │
├──────────────┴───────────────────────────────┤
│ CUDA Runtime API                              │  ← 你问的"cuda运行时库"
│ cudaMalloc / cudaMemcpy / cudaGraphLaunch     │
│ cublas / cudnn / nccl                         │
├──────────────────────────────────────────────┤
│ CUDA Driver API                               │  ← 驱动层
│ cuCtxCreate / cuModuleLoad / cuLaunchKernel   │
├──────────────────────────────────────────────┤
│ GPU (硬件)                                     │
└──────────────────────────────────────────────┘

```

![](../images/Pasted%20image%2020260518193310.png)

---

- 前缀缓存prefix cache
- **chunked prefill** (scheduler)
	- 仅支持等待队列中第一个seq的chunked
- CUDA Graph
- FlashAttention
- **continuous batching**
	- ![443](../images/Pasted%20image%2020260518211421.png)
- **张量并行**
- **pagedattention**
	- block_table作为页表，写入位置作为slot, blockmanager作为操作系统，kvcache是具体的物理内存，所以底层具体写入物理内存，用的是FlashAttention, 而页表管理则是靠blockmanager

# 分模块解析
## sequence

```cpp
//一个序列，prompt提示，请求
/*
所以，一个sequence对象，本质上，代表着一个session对话的完整过程。
*/
class sequence{
private:
	int block_size = 256; //一块物理内存（一页）容纳256个token
	//TODO: counter, 全局计数器

public:
	/*整体序列的信息*/
	int seq_id; //该prompt的唯一id
	SequenceStatus status; //该条prompt的状态
	
	/*具体token*/
	int token_ids[]; //具体的token ID 的数组
	int last_token; //最后一个token的ID
	
	/*数量信息*/
	int num_tokens; //当前的token数量
	int num_prompt_tokens; //提示词部分的token数量
	int num_cached_tokens; //已经计算KVcache的token
	int num_scheduled_tokens; //本轮step准备处理的token数（prompt）
	
	/*计算过程信息*/
	bool is_prefill; //是否已经预填充
	Block block_table[]; //block列表，存放计算过程中的KVcache
	
	/*模型回归结果的约束*/
	int temperature; //指定采样程度
	int max_tokens; //指定序列的最大输出长度
	int ignore_eos; //指定是否忽略结束符填充




}
```


## blockmanager

block里面存放序列的tokens，主要用于计算前缀cache
```cpp
//定义一个block内存页，存放KVcache
class Block{
	int block_id; //block的唯一标识符
	int ref_count; //引用这个block的sequence的数量，用于前缀缓存prefill cache
	int hash; //该block的快速校验身份
	int token_ids[]; //实际存储的token ID们，占用的内存。
	
	
	void update(); //更新这个block的内容
	void reset(); //清空这个block的内存

}
```

BlockManager用于管理空闲Block内存的分配与回收
```cpp
负责管理所有的block的申请与回收
class BlockManager{
	/*全局信息*/
	int block_size; //每个block容纳多少token数
	Block blocks[]; //一口气申请num_blocks个block个内存。
	dict hash_to_block_id; //创建通过hash值快速找到block的字典查询方法
	
	/*两条链表*/
	Block* free_block_ids; //空闲block双向队列(链表)
	Block* used_block_ids; //占用block集合
	
	
	
	
	//构造函数
	BlockManager(){
		//
	}
	
	int _allocate_block();//分配一个空闲block
	void _deallocate_block();//回收一个block
	
	int can_allocate(sequence); //判断是否能分配block给sequence
	void allocate(sequence);//给一个sequence分配block
}
```





## scheduler
```cpp

//调度器，负责提供下一个token
class Scheduler{
	int max_num_seqs; //每个step最多处理多少序列
	int max_num_batched_tokens; //每个step处理最多多少token
	int eos; //终止符token ID 
	int block_size; //KVcache的块大小
	Sequence* waiting; //等待任务队列
	Sequence* running; //运行任务队列
	
	
	void add(Sequence); //增加一个任务
	
	(Sequence*, bool) schedule();//调度工作
	
	void preempt(Sequence);//紧急淘汰运行中的任务到等待队列
	void postprocess(Sequence*)//后处理，把模型的输出token加入对应的任务。
	
	
	
}
```


## model_runner


```cpp
//负责执行模型推理的前向传播
class Model_runner{
	void config;//指定的该模型的运行配置
	int block_size;//KVcache的每个页的大小=256
	
	bool enforce_eager;//是否开启CUDA Graph
	int world_size; //张量并行的并行通道数=GPU数量
	int rank; //当前GPU编号
	SIGNAL event; //多进程同步信号
	
	self.model; //用算子组成的模型，已经加载好了权重
	Samper samper;//采样器，负责选择具体的预测token
	

	void capture_cudagraph();//截取完整的CUDAkernel序列，固化为可以重放的graph，省略每次kernel launch的开销。
	void allocate_kv_cache();//显存分配，根据剩余显存，动态计算能存放多少个block,并把显存分给对应的model的各层
	int run_model();//运行一次模型推理，得到预测的token
	int run(); //实际完成整个链路，预填充，run_model, 采样

}
```


## LLMEngine

```cpp
class LLMEngine(){
	ps[]; //张量并行的工作进程列表
	event[]; //每个子进程的event，用于协调TP的同步
	moder_runner; //定义一个rank0 显卡的moder_runner，主进程中持有
	tokenizer; //分词器，text - token_id 的转换
	scheduler; //调度器，

}
```

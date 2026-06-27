
# 环境安装
gcc, g++
nvcc编译器

armadillo数学库
## cmake

cmake帮你写Makefile, 然后你用make进行编译
```text
CMakeLists.txt
        ↓
cmake ..
        ↓
生成 Makefile / CMakeCache.txt / CMakeFiles
        ↓
make 或 cmake --build .
        ↓
调用 g++ 编译 test.cpp
        ↓
生成可执行文件 test
```

![510](../images/Pasted%20image%2020260602162512.png)

### cmake的使用
- **第一阶段（构建编译文件）**
```bash
cmake ..
```
![282](../images/Pasted%20image%2020260602162604.png)![255](../images/Pasted%20image%2020260602162634.png)



- **第二阶段(编译)**
![131](../images/Pasted%20image%2020260602162707.png)![334](../images/Pasted%20image%2020260602162738.png)


### CMakeLists.txt
```txt
# 表示这个项目最低需要的CMake的版本
cmake_minimum_required(VERSION 3.10)

# 指定项目名字
project(test_cpp)

# 使用C++17标准， 相当于在Makefile里面添加 -std=c++17
set(CMAKE_CXX_STANDARD 17)

# 用test.cpp 生成一个可执行文件test
add_executable(test test.cpp)
```

最后生成的Makefile约等于：`/usr/bin/g++ -std=c++17 -o test test.cpp`
![193](../images/Pasted%20image%2020260602163104.png)![209](../images/Pasted%20image%2020260602163115.png)![223](../images/Pasted%20image%2020260602163138.png)
![234](../images/Pasted%20image%2020260602163152.png)![320](../images/Pasted%20image%2020260602163212.png)


### cmake真正的好处
![276](../images/Pasted%20image%2020260602163306.png)![365](../images/Pasted%20image%2020260602163315.png)

![428](../images/Pasted%20image%2020260602163334.png)




`CMakeLists.txt`：

```
cmake_minimum_required(VERSION 3.10)

project(test_cpp LANGUAGES CXX)

add_executable(test
				main.cpp    
				src/add.cpp)

target_include_directories(test PRIVATE   
					${PROJECT_SOURCE_DIR}/include)

target_compile_features(test PRIVATE 
					cxx_std_17)
```
这里：
```
add_executable(test ...)
```
**创建一个目标**，叫 `test`。


```
target_include_directories(test PRIVATE ...)
```
给 `test` 这个目标**添加头文件搜索路径**。


```
target_compile_features(test PRIVATE cxx_std_17)
```
让 `test` 用 **C++17 编译**。

这就是现代 CMake 的核心思想：

```
不要全局乱 set尽量围绕 target 配置
```

也就是围绕：

```
add_executable()
add_library()
target_include_directories()
target_link_libraries()
target_compile_options()
target_compile_features()
```

这些来写。

### cmake的指令参数
```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug

# -S .
# 指定当前目录为源码目录

# -B build
# 指定构建目录

# -DCMAKE_BUILD_TYPE=Debug
# -D 给CMake定义一个变量
# CMAKE_BUILD_TYPE CMake的内置变量，控制编译模式
# Debug 编译为调试模式
	# 保留**调试符号**（gdb / VS 调试可用）
	# 不开启优化（`-O0`）
	# 方便断点、查崩溃、看变量
# 对应还有：
	#`Release`（发布优化）、
	# `RelWithDebInfo`（带调试的发布）、
	# `MinSizeRel`（最小体积）
```


## gdb使用
gdb是调试工具，需要按照调试模式来编译程序
```bash
# 构建
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug

# 编译
cmake --build build
```
重点是我们指定按照Debug模式来编译程序

之后我们就可以用gdb来进行调试了

```bash 
gdb ./build/bin/test
```


1. 打断点
	1. main
		1. `bread main` 
		2. `b main`
	2. 行号
		1. `break test.cpp:6`
		2. `b test.cpp:6`
2. 开始运行程序
	1. `run`
	2. `r`
3. 执行
	1. 单步执行（不进入函数内部）
		1. `next`
		2. `n`
	2. 单步执行（进入函数内部）
		1. `step`
		2. `s`
	3. 执行到下一个断点
		1. `continue`
		2. `c`
4. 查看当前停在哪里
	1. `where`
5. 查看函数调用栈
	1. `bt`  = backtrace
6. 查看当前源码附近
	1. `list`
	2. `l`
7. 打印变量
	1. 直接打印变量值
		1. `p i`    `p name`   `p this->count`
	2. 格式化打印
		1. `p/x 变量` 16进制打印
		2. `p/d 变量` 10进制打印
		3. ...
	3. 打印复杂类型
		1. 数组/连续内存
			1. `p *arr@10` 打印arr数组的前10个元素
		2. 结构体/类
			1. `p 结构体变量`
		3. 漂亮打印(缩进打印结构体)
			1. `set print pretty on`  `p user`
	4. 打印全局变量
		1. `p 变量名`
		2. `p ::count` 避免和局部变量重名
	5. 打印指针指向内容
		1. `p *ptr`
	6. 连续自动打印(每次停下都显示)
		1. `display 变量`
		2. 取消自动打印
			1. `undisplay`
	7. 查看内存
		1. `x/格式 地址`
			1. `x/10xw ptr`  打印10个32位（word），按16进制(x)
			2. `x/20cb ptr` 打印20个字节（8位），按照char解析
	8. 查看所有局部变量
		1. `info locals`  一次性打印当前函数所有变量

![222](../images/Pasted%20image%2020260602170336.png)

8. 查看各种界面
	1. `layout src` 源码界面
		1. ![322](../images/Pasted%20image%2020260602170553.png)
	2. `layout asm` 汇编界面
		1. ![388](../images/Pasted%20image%2020260602170707.png)
	3. `layout regs` 寄存器界面
		1. ![402](../images/Pasted%20image%2020260602170757.png)



# c++20的特性
## 命名空间
我的理解，就是相当于形象的理解成模块归属的机制就行。

## 关键字

1. explicit
静止编译器做隐式类型转换，强迫调用者显式写出构造动作，避免编译器帮你自动做类型转换。

2. override
`void* allocate(size_t byte_size) const override;`
用来告诉编译器，我在重写基类虚函数，帮我检查，如果这个不是基类的虚函数，就变成新函数。override的作用是把错误提前到编译阶段。

这个里面的const，是表示常函数，这个函数内部，不会修改这个对象内存的任何成员变量。

3. mutable
这个是const的后门，如果const修饰了成员函数，那么内部就不能改变变量，但是有一个例外，就是如果这个成员函数被标记了mutable。那么即便在常函数里面也能修改。

## 容器
1. map
STL标准库里面的有序键值对容器，`#include<map>`



## 语法

1. static_cast<type*>xxx
c++风格的强制类型转换， 比（）直接转换更安全。
（）转换等于：
- `static_cast` — 相关类型间的转换（只做编译期可检查的转换）
- `reinterpret_cast` — 不相关指针类型间的暴力转换
- `const_cast` — 悄悄去掉 const




## 智能指针
1. **shared_ptr**, c11引入的智能指针之一，功能：**引用计数自动管理内存，没人用了就自动delete**。
![521](../images/Pasted%20image%2020260627084716.png)


创建方法：
```
auto p1 = std::make_shared<Buffer>(128, allocator);

std::make_shared<typename T>(...）

= new Buffer(128, allocator)


```

## cuda相关

1. 异步拷贝，流
`cudaMemcpyAsync` 的"异步"是指：**函数调用本身立即返回给 CPU，不等待拷贝实际完成**。对比 `cudaMemcpy`（同步），CPU 会卡在那行直到拷贝结束。


至于流内的顺序：同一个流上，任务**依然按挂上去的顺序执行**，后面的任务仍要等前面的异步拷贝完成。异步只是说 CPU 调用那一刻不等。

所以你这个文件里用 `cudaMemcpyAsync` 的好处是，CPU 可以快速跑完这段 `memcpy` 函数，去干别的事（比如准备下一层的输入）。

cudaDeviceSynchronize, 是cpu阻塞等待GPU所有流的任务完成。只要GPU还在干活，就不返回。

- **异步** = CPU 不等 GPU 任务完成就继续往下执行。
- **`cudaDeviceSynchronize`** = CPU 死等 GPU 上全部任务干完。





---



# 项目一：cuda自制大模型推理框架
## 1. base/基础组件层

这边主要三个部分：
- base
	- 这个模块主要定义整个推理框架的一些基本类
		- 设备类型（枚举）
		- 数据类型（枚举）
		- 模型类型（枚举）
		- 属性类
		- 状态类
- buffer
	- 这个模块对不同设备的内存空间做了一层抽象封装
	- 抽象存储空间
- alloc
	- 这个模块是对**内存分配管理器**的封装

## 2. op/算子层
## 3. tensor/张量层
## 4. model/模型组装层

















# 项目汇总
## 项目一：Mini CUDA LLaMA Inference Engine

目标：

```
从零实现一个支持 LLaMA/Qwen 小模型单机推理的 CUDA 推理框架
```

模块：

```
1. 工程基础
   - CMake
   - gdb / cuda-gdb
   - CUDA error check
   - Nsight Compute profiling

2. 基础框架
   - Tensor
   - DeviceBuffer
   - MemoryManager
   - Operator
   - Runtime
   - ModelConfig

3. 权重加载
   - mmap
   - 权重 shape 管理
   - CPU/GPU 权重加载
   - 算子与权重绑定

4. CUDA 算子
   - RMSNorm
   - RoPE
   - MatMul
   - Softmax
   - Attention
   - MLP
   - Sampling

5. LLaMA 推理
   - Tokenizer
   - Prefill
   - Decode
   - KV Cache
   - Generate Loop

6. 性能优化
   - 向量化访存
   - shared memory 优化
   - warp reduce
   - kernel fusion
   - 显存复用
   - Nsight 分析报告
```


---

## 项目二：Mini-vLLM / nano-vLLM Optimization

目标：

```
基于 nano-vLLM 实现高吞吐推理调度和 KV Cache 管理优化
```

模块：

```
1. vLLM 基础机制
   - PagedAttention
   - Block Manager
   - KV Cache Block
   - Sequence / Request / Batch

2. 调度系统
   - waiting queue
   - running queue
   - prefill / decode 分离
   - continuous batching
   - chunked prefill

3. Cache 优化
   - prefix cache
   - block reuse
   - cache eviction
   - cache hit rate 统计

4. 性能评测
   - TTFT
   - TPOT
   - Throughput
   - KV Cache 使用率
   - 显存占用
```



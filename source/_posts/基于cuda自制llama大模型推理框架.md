
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

### 项目里的CMake构建速查

一个项目从 `CMakeLists.txt` 到可执行文件，大概是这条线：

```text
include() / find_package()
        ↓
收集源文件
        ↓
add_executable() / add_library()
        ↓
target_include_directories()
target_link_directories()
target_link_libraries()
```

根 `CMakeLists.txt` 通常先做这些事：

```cmake
cmake_minimum_required(VERSION 3.16)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_CUDA_COMPILER "/usr/local/cuda/bin/nvcc")
project(llama_infer CXX CUDA)
include(cmake/cuda.cmake)
```

重点：

- `CMAKE_EXPORT_COMPILE_COMMANDS ON`：生成 `compile_commands.json`，方便 IDE 跳转和补全。
- `project(llama_infer CXX CUDA)`：启用 C++ 和 CUDA 两套语言支持。
- `include(cmake/cuda.cmake)`：执行 CUDA 探测脚本，比如检查 toolkit、GPU 架构。

几个容易混的点：

- `include(xxx.cmake)`：执行 CMake 脚本，类似 bash 的 `source`，不是 C++ 的 `#include`。
- `find_package(GTest REQUIRED)`：找的是库安装时附带的 CMake 描述文件，不是直接找 `.so/.a`。
- `GTest::gtest`：CMake target，里面已经打包了头文件路径、库路径和依赖。
- `PROJECT_SOURCE_DIR`：顶层 `CMakeLists.txt` 所在目录。
- `REQUIRED`：找不到就直接报错停止。
- `add_library(llama SHARED ...)`：`llama` 是 CMake 目标名，不是最终文件名。`SHARED` 表示生成动态库，Linux 下 CMake 会自动加 `lib` 前缀和 `.so` 后缀，所以产物是 `libllama.so`。

顺序上，`target_include_directories / target_link_directories / target_link_libraries` 必须写在 `add_executable/add_library` 之后，因为它们要绑定到已经创建好的 target。

如果有子目录：

```cmake
add_library(llama SHARED ...)
add_subdirectory(test)
add_subdirectory(demo)
```

`test/demo` 如果要链接 `llama`，就应该放在 `add_library(llama ...)` 之后。

条件编译常用来控制模型支持：

```cmake
option(QWEN2_SUPPORT OFF)
if (QWEN2_SUPPORT)
    add_definitions(-DQWEN2_SUPPORT)
endif()
```

命令行开启：

```bash
cmake .. -DQWEN2_SUPPORT=ON
```

用途：不同模型依赖不同，按需打开，避免强制安装暂时不用的库。

第三方库安装后通常长这样：

```text
/usr/include/gtest/          # 头文件
/usr/lib/libgtest.a          # 库本体
/usr/lib/cmake/GTest/        # find_package 要找的描述文件
```

常用命令：

```bash
mkdir -p build && cd build
cmake ..
make -j$(nproc)
make llama
make test_llm
./test_llm --gtest_filter=test_buffer.*
```

`make test_llm` 时，如果 `test_llm` 写了：

```cmake
target_link_libraries(test_llm llama)
```

CMake 会自动先编 `llama`，再编 `test_llm`，不用手动分两步。

常见目标：

| 目标 | 产物 |
|---|---|
| `llama` | `lib/libllama.so` |
| `test_llm` | `build/test/test_llm` |
| `llama_infer` | `build/demo/llama_infer` |

查看有哪些目标：

```bash
make help
grep -rn "add_executable\|add_library" CMakeLists.txt test/ demo/
```

### 库链接怎么判断

核心原则：

> **只要代码用了某个库的头文件，一般就要把对应库写进 `target_link_libraries`。**

```cmake
target_link_libraries(llama
    sentencepiece
    glog::glog
    gtest
    gtest_main
    pthread
    cudart
    armadillo
)
```

可以<mark style="background:#fff88f">粗略分三类</mark>：

| 类型        | 例子                                                  | 是否需要手动链接 |
| --------- | --------------------------------------------------- | -------- |
| 编译器默认库    | `libstdc++`、`libc`、`libm`、`libgcc`                  | 通常不用     |
| 系统库但不默认链接 | `pthread`、`dl`、`rt`                                 | **需要**   |
| 第三方库      | `glog`、`gtest`、`sentencepiece`、`cudart`、`armadillo` | **需要**   |

`glog::glog` 这种带 `::` 的名字，一般是 CMake target，里面已经带了头文件路径、库路径和依赖。

`sentencepiece`、`cudart` 这种裸库名，等价于让链接器去找：

```text
libsentencepiece.so / libsentencepiece.a
libcudart.so / libcudart.a
```

一句话记忆：

```text
include 解决“编译时能不能看到声明”
target_link_libraries 解决“链接时能不能找到实现”
```

# GTest单元测试速查

基本写法：

```cpp
TEST(test_buffer, allocate) {
    Buffer buffer(32, alloc);
    ASSERT_NE(buffer.ptr(), nullptr);
}
```

`TEST(suite, name)` 会自动生成测试类，并注册到 gtest 的全局用例列表。`RUN_ALL_TESTS()` 会统一执行这些测试。

<mark style="background:#d6e4ff">suite 通常写模块名，name 写测试场景</mark>，比如 `test_buffer.allocate`。

常用断言：

| 断言 | 含义 |
|---|---|
| `ASSERT_EQ(a, b)` | `a == b` |
| `ASSERT_NE(a, b)` | `a != b` |
| `ASSERT_TRUE(cond)` | 条件为真 |
| `ASSERT_FALSE(cond)` | 条件为假 |
| `ASSERT_STREQ(a, b)` | C 字符串相等 |

<mark style="background:#ffd6e7">`ASSERT_` 失败后立刻终止当前用例，`EXPECT_` 失败后记录错误但继续执行。</mark>

运行命令：

```bash
make test_llm -j$(nproc)

./build/test/test_llm
./build/test/test_llm --gtest_list_tests
./build/test/test_llm --gtest_filter=test_buffer.*
./build/test/test_llm --gtest_filter=test_buffer.allocate
./build/test/test_llm --gtest_filter=*allocate*
```

输出里重点看：

```text
[ RUN      ] test_buffer.allocate
[       OK ] test_buffer.allocate
[  PASSED  ] 1 test.
```

如果失败，会打印断言所在文件行号、期望值和实际值。

CMake 集成：

```cmake
find_package(GTest REQUIRED)
target_link_libraries(test_llm GTest::gtest)
```

`test_llm` 本质是一个测试可执行文件，里面链接了 `libllama.so`、gtest、glog 等依赖。


# gdb使用
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


# CMake

前面已经知道，cmake是帮助你编写Makefile的，我们可以利用CMake的方法，来自动生成整个项目的Makefile




1. `include(../cmake/cuda.cmake)`
CMakeLists里面的include，是针对同样的cmake来的，这不是引用库，而是**把 `cuda.cmake` 里的代码原样贴过来执行**

`.cmake` 后缀只是约定，表明"这是个 CMake 脚本"，不是 `.so` 或 `.a` 库文件。

> 这个.cmake说明书的作用：检查cuda工具链是否存在，探测显卡架构，把执行结果，保存到变量里面，后面的代码直接引用![](../images/Pasted%20image%2020260627172704.png)


2. `find_package(GTest REQUIRED)`

第三方库编译成.so后，安装到系统中(/usr/lib/archxxx/)，
顺带会装上.cmake描述文件(可以理解为说明书 /usr/lib/archxxx/cmake)

find_package靠.cmake找到库的物理位置
![](../images/Pasted%20image%2020260627171929.png)
![](../images/Pasted%20image%2020260627171941.png)
找到库之后，会把检查结果记录到一些变量里面，就是后面的：
- ${glog_INCLUDE_DIR}
- ${GTest_INCLUDE_DIR}

所以流程就是：`find_package` 探测库的位置 → 设置变量 → `target_include_directories` 用这些变量告诉编译器。


3. set(link_ext_lib glog::glog GTest::gtest)
![](../images/Pasted%20image%2020260627172026.png)
![](../images/Pasted%20image%2020260627172039.png)

4. aux_source_directory(目录 变量名)
![](../images/Pasted%20image%2020260627172234.png)


![](../images/Pasted%20image%2020260627172402.png)


5. add_executable(名字 源文件列表)
![](../images/Pasted%20image%2020260627172833.png)
> 注意，这个add_executable还没有正式开始编译，只是注册目标，告诉CMake，要编译什么。
> 
> 真正开始构建，是你执行 cmake --build . --target test_llm
> 或者make test_llm

![](../images/Pasted%20image%2020260627173056.png)

6. target_link_libraries(目标 链接库)
这个的作用，就是g++里面的-l, 可以链接的库有：
- 动态库（.so）（看到.so就只记引用，运行到这一块的时候，才加载）
- 静态库（.a）(链接器看到.a就把代码拷贝到可执行文件中)


> 这里纠正一个认识：
> 给你一个库，so/a, 里面肯定是各种方法的实现，但是这个方法叫什么，你肯定在写代码的时候，就需要知道，所以库文件.so/.a， 还需要配合头文件，这样你才知道方法叫什么。


7. target_include_directories(目标 PUBLIC 目录)
指定头文件的目录

8. target_link_directories(目标 PUBLIC 目录)
![697](../images/Pasted%20image%2020260627174513.png)

**总结**

用CMakeLists，来利用cmake构建一个项目的make，流程是：
![](../images/Pasted%20image%2020260627174925.png)

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

2. `构造函数 xxx(const xxx& a) = delete`

显式删除某个函数，让编译器禁止调用它。常用于禁止拷贝：

```cpp
class NoCopyable {
protected:
    NoCopyable() = default;
    ~NoCopyable() = default;

    NoCopyable(const NoCopyable&) = delete;
    NoCopyable& operator=(const NoCopyable&) = delete;
};
```

子类继承 `NoCopyable` 后，普通构造不会受影响：

```cpp
Buffer buf(128, alloc);   // 正常构造
```

但拷贝构造和拷贝赋值会被编译器拒绝：

```cpp
Buffer buf2(buf);     // 触发拷贝构造，编译报错
Buffer buf3 = buf;    // 也是拷贝构造，编译报错
buf2 = buf;           // 触发拷贝赋值，编译报错
```

<mark style="background:#ffd6e7">`= delete` 是编译期拦截，不是运行时报错。</mark>

在 `Buffer` 这种管理大块内存的类里，禁止拷贝可以避免两个对象指向同一块 `ptr_`，析构时发生 double free。

3. `enum` 和 `enum class`

普通 `enum`：

```cpp
enum StatusCode : uint8_t {
    kSuccess = 0,
    kPathNotValid = 2
};
```

枚举值可以直接使用，也容易隐式转成 `int`：

```cpp
int code = kSuccess;
```

`enum class`：

```cpp
enum class DeviceType : uint8_t {
    kDeviceCPU = 1,
    kDeviceCUDA = 2
};
```

使用时必须带作用域：

```cpp
DeviceType type = DeviceType::kDeviceCUDA;
```

<mark style="background:#d6e4ff">`enum class` 更类型安全：不会隐式转成 `int`，不同枚举类型之间也不能随便比较。</mark>

`: uint8_t` 表示指定底层存储类型，能减少内存占用。默认优先用 `enum class`，只有需要和 `int` 高频交互时再考虑普通 `enum`。




4. 右值引用和 `std::move`

左值引用 `T&`，就是引用一个正常变量，有名字，能取地址。

右值引用 `T&&`，可以理解成引用一个临时对象，或者一个后面基本不用的对象。

<mark style="background:#d6e4ff">右值引用的核心作用：告诉编译器，这个对象里面的资源可以被转移走。</mark>

`std::move` 这个名字有点迷惑，它本身不搬数据，也不申请内存，只是做了一次类型转换：

```cpp
std::move(x) = static_cast<T&&>(x)
```

<mark style="background:#fff88f">std::move 的本质：把一个左值，强行标记成“可以被移动的右值”。</mark>

比如 `Tensor` 构造函数里面：

```cpp
Tensor::Tensor(base::DataType data_type, std::vector<int32_t> dims, ...)
    : dims_(std::move(dims)) {}
```

这里的 `dims` 是形参，本身是一个局部变量，所以它其实是左值。

但是构造函数结束之后，`dims` 就没用了，所以这里用 `std::move(dims)`，让成员变量 `dims_` 直接接管它内部的堆内存。

```text
拷贝 vector：重新申请内存，然后一个一个复制元素，O(n)
移动 vector：直接转移 begin/end/cap 三个指针，O(1)
```

所以这个写法：

```cpp
Tensor(..., std::vector<int32_t> dims)
    : dims_(std::move(dims)) {}
```

可以理解成：

```text
调用者传左值：先拷贝到形参 dims，再移动到成员变量 dims_
调用者传右值：直接移动到形参 dims，再移动到成员变量 dims_
```

<mark style="background:#ffd6e7">注意：被 std::move 之后的对象还能析构，但是不要再依赖它原来的内容。</mark>

几个容易混的点：
- `dims_(std::move(dims))`：这是移动构造，在初始化列表里完成。
- `dims_ = std::move(dims)`：这是移动赋值，成员变量已经存在了。
- `return t;` 返回局部对象时，一般不用写 `std::move(t)`，编译器会做返回值优化或者自动移动。

## 智能指针
1. **shared_ptr**, c11引入的智能指针之一，功能：**引用计数自动管理内存，没人用了就自动delete**。
![521](../images/Pasted%20image%2020260627084716.png)


创建方法：
```
auto p1 = std::make_shared<Buffer>(128, allocator);

std::make_shared<类名>(构造函数的参数）
= new 类名（构造函数参数）
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

### Buffer层，DeviceAlloctor层，RALL动态管理设计

我的原话问题：

> 对了，我记得老师说，buffer类这里面有用智能指针+RALL，智能指针我看就一个shared_ptr, 用来对内存进行引用计数，自动进行释放回收。是吗？
>
> 那RALL呢？

> shared_ptr 本身就是 RAII 的经典实现，这算什么？共享指针本质上就是一个带一个引用计数机制的特殊指针，我看buffer里面，主要就是用来指定DeviceAllocator类型的指针，是用来表示设备操作类对象的指针的。
>
> buffer类里面，包含的是一块内存的抽象信息（内存大小，内存指针，内存设备，是否是buffer类管理的内存，管理这块内存的DeviceAllocator类对象。）
>
> 而一个指向的具体的设备操作类对象，allocator_，（处理的设备类型，就这一个成员属性）
>
> 所以我们的用共享指针shared_ptr所实现的RALL思想，是什么意思？是指的buffer类包含的对DeviceAllocator类的动态包括关系吗？

> 所以buffer类对象，只是内存块的抽象表示层，中间还有一层DeviceAllocator类的分配层，是吗？

这里可以理解成三层：

```text
Buffer           # 内存块抽象：大小、指针、设备类型、是否外部内存
    ↓ 委托
DeviceAllocator  # 分配策略：CPU malloc/free 或 CUDA cudaMalloc/cudaFree
    ↓ 调用
OS / CUDA        # 真正执行物理内存分配
```

<mark style="background:#d6e4ff">Buffer 不直接关心底层是 CPU 还是 GPU，它只保存内存块信息，并把申请/释放委托给 allocator_。</mark>

Buffer类 里的核心成员大概是：

```cpp
size_t byte_size_;
void* ptr_;
bool use_external_;
DeviceType device_type_;
std::shared_ptr<DeviceAllocator> allocator_;
```

- `byte_size_ + ptr_`：表示这块内存本身。
- `device_type_`：标记内存在 CPU 还是 GPU。
- `use_external_`：如果是外部传进来的指针，Buffer 不负责释放。
- `allocator_`：指向具体分配器对象，负责实际的 `allocate/release/memcpy`。


**RALL编程思想** = 
**Resource Acquisition Is Initialization。**
核心思想就一条：**把资源的生命周期绑到对象的生命周期上**——<mark style="background:#fff88f">对象构造时获取资源，对象析构时释放资源</mark>。编译器保证析构一定会跑，所以资源永远不会忘了释放。


<mark style="background:#fff88f">RAII 的核心：资源在构造时获取，在析构时释放。</mark>


在这里有两层 RAII：

1. `Buffer` 自己管理 `ptr_` 指向的内存块：构造时申请，析构时释放。
	1. **buffer层，每个buffer类对象，管理ptr_，是通过构造函数，析构函数，来实现RALL的**
2. `shared_ptr<DeviceAllocator>` 管理分配器对象：多个 Buffer 共享同一个 allocator，最后一个引用消失时自动销毁。
	1. **DeviceAllocator层，是通过共享指针来动态管理分配器对象，实现RALL的**

```cpp
auto alloc = CPUDeviceAllocatorFactory::get_instance();
Buffer buf1(32, alloc);
Buffer buf2(64, alloc);
```

这里 `buf1`、`buf2` 都保存了一份 `shared_ptr`，共同指向同一个 `DeviceAllocator`。引用计数归零时，分配器对象才会自动释放。

<mark style="background:#ffd6e7">注意：shared_ptr 管的是 allocator 对象的生命周期；Buffer 析构释放的是 ptr_ 指向的那块数据内存。这两个资源不要混在一起。</mark>
![](../images/Pasted%20image%2020260628142343.png)

### Cuda流层，kernel模块的RAII封装

base 层里还有一个 `kernel` 模块，对 CUDA stream 做了一层轻量封装：

```cpp
namespace kernel {
struct CudaConfig {
    cudaStream_t stream = nullptr;

    ~CudaConfig() {
        if (stream) {
            cudaStreamDestroy(stream);
        }
    }
};
}
```

这里的 `CudaConfig` 本质上是 <mark style="background:#d6e4ff">CUDA 流的 RAII 包装器</mark>。

- `stream` 保存一条 CUDA 流。
- kernel 函数通过 `config->stream` 拿到指定流，在这条流上启动 GPU 算子。
- `CudaConfig` 析构时自动调用 `cudaStreamDestroy(stream)`，不用外部手动销毁。

<mark style="background:#fff88f">RAII 思想：谁持有资源，谁在析构时负责释放。</mark>

和 `Buffer` 类似：

```text
Buffer     管 ptr_ 指向的内存块
CudaConfig 管 cudaStream_t 指向的 CUDA 流
```

区别只是资源类型不同，一个是内存，一个是 CUDA 执行流。

![](../images/Pasted%20image%2020260628144842.png)

## 2. op/算子层
## 3. tensor/张量层
这一层就是在buffer层的基础上，定义tensor层，上下层之间也是共享指针来动态绑定来实现RALL

![](../images/Pasted%20image%2020260630145735.png)

这边主要仔细看了一下构造函数，张量转移函数。

**构造函数**


**张量转移函数**
![](../images/Pasted%20image%2020260630155727.png)

这里来解释一下，
- 先判断当前tensor的设备类型，必须是cpu内存
- 之后
	- 获取内存大小
	- 工厂函数获取GPU的内存分配器（实际干活的人）
		- 工厂函数获取gpu内存分配器
		- >![](../images/Pasted%20image%2020260630160056.png)
		- 可以看到，工厂函数类对象，维护者一个静态的真实的gpu内存分配器指针，instance这个共享内存指针，永远指向一个gpu内存分配器。
		- 之后所有申请gpu内存分配器，就是用auto cu_alloc来指向这个gpu内存分配器的对象，增加了引用计数。这也是RALL的思想。
	- 分配器开辟gpu内存
	- 分配器拷贝内存
	- 绑定该内存




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

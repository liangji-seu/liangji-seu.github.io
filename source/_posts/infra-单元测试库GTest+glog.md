---
title: infra 单元测试库GTest+glog
categories: [学习笔记, 大模型算法]
tags: [GTest, glog, AI Infra]
---



这个文档主要用于记录学习如何使用GTest + glog来对我们一个系统里面各个模块的各个层类进行单元测试，现在发现如果手搓整个项目的话，不进行单元测试，比较麻烦。

- GTest:
	- 第三方库，用于测试程序，进行单元测试
- glog
	- 第三方库，用于打印调试信息log+断言检查CHECK
# GTest
这是一个第三方库。
## 整个项目说明
目前，我是基于kuipa的项目来学习的，所以，我先介绍一下，整个项目的CMakeLists来了解一下整个项目架构

kuipa项目结构如下
```bash
(base) liangji@ubun:~/AI_INFRA/projects/teacher/KuiperLLama$ l -l
total 60
drwxrwxr-x 5 liangji liangji 4096 Jun 28 11:29 build/      #构建目录，我们需要在这个目录来构建makefile编译

drwxrwxr-x 2 liangji liangji 4096 Jun 27 17:13 cmake/            #一些工具小脚本，检测cuda
-rw-rw-r-- 1 liangji liangji 3521 Jun 28 11:11 CMakeLists.txt    #整个项目的顶层构建脚本

drwxrwxr-x 4 liangji liangji 4096 Jun  1 23:56 kuiper/           #推理框架引擎层，最终编译出一个引擎.so
drwxrwxr-x 2 liangji liangji 4096 Jun 29 00:54 lib/              #存放引擎.so

drwxrwxr-x 2 liangji liangji 4096 Jun  2 00:05 models/           #存放外部模型权重文件，架构文件

drwxrwxr-x 2 liangji liangji 4096 Jun  2 00:09 demo/             #主编译目标源文件，调用框架层，实现demo

drwxrwxr-x 7 liangji liangji 4096 Jun  1 23:56 test/             #副编译目标源文件，框架层的单元测试


# 下面都是无关紧要的
drwxrwxr-x 2 liangji liangji 4096 Jun  1 23:56 hf_infer/
drwxrwxr-x 2 liangji liangji 4096 Jun  1 23:56 imgs/
drwxrwxr-x 2 liangji liangji 4096 Jun  1 23:56 tmp/
drwxrwxr-x 3 liangji liangji 4096 Jun  1 23:56 tools/
-rw-rw-r-- 1 liangji liangji 2766 Jun  1 23:56 dockerfile
-rw-rw-r-- 1 liangji liangji 5060 Jun  1 23:56 readme.md

```

我们的推理框架的主要代码在kuiper/下，顶层的CMakeLists将这个kuiper/下编译成推理框架llamalib.so

之后我们具体编译出可执行目标的是
- demo
	- 用来编译出真正可以运行的大模型推理的可执行程序
- test
	- 用来编译出**针对单元测试**的可执行程序

我们的GTest, glog，主要是针对test/而言的，

在test/下的CMakeLists里面，
```bash
include(../cmake/cuda.cmake)
find_package(GTest REQUIRED)
find_package(glog REQUIRED)


set(link_ext_lib glog::glog GTest::gtest)
aux_source_directory(../test DIR_TEST)


aux_source_directory(../test/test_cu DIR_TEST_CU)
aux_source_directory(../test/test_op DIR_TEST_OP)
aux_source_directory(../test/test_model DIR_TEST_MODEL)
aux_source_directory(../test/test_tensor DIR_TEST_TENSOR)
aux_source_directory(../test/optimized DIR_TEST_OPTIMIZED)

  
add_executable(test_llm ${DIR_TEST} ${DIR_TEST_CU} ${DIR_TEST_OP} ${DIR_TEST_OPTIMIZED} ${DIR_TEST_TENSOR} ${DIR_TEST_MODEL})


#set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -g -G")
target_link_libraries(test_llm ${link_ext_lib})
  
  

# 指定头文件：两个库的头文件 + 我们主程序的头文件
target_include_directories(test_llm PUBLIC ${glog_INCLUDE_DIR})
target_include_directories(test_llm PUBLIC ${GTest_INCLUDE_DIR})
target_include_directories(test_llm PUBLIC ../kuiper/include)
 
  

target_link_directories(test_llm PUBLIC ${PROJECT_SOURCE_DIR}/lib)
if (LLAMA3_SUPPORT OR QWEN2_SUPPORT OR QWEN3_SUPPORT)
    message(STATUS "LINK LLAMA3 SUPPORT")
    find_package(absl REQUIRED)
    find_package(re2 REQUIRED)
    find_package(nlohmann_json REQUIRED)
    target_link_libraries(llama absl::base re2::re2 nlohmann_json::nlohmann_json)
endif ()

target_link_libraries(test_llm llama)


set_target_properties(test_llm PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
set_target_properties(test_llm PROPERTIES CUDA_SEPARABLE_COMPILATION ON)
```

可以看到，我们的编译目标是test_llm ， 然后链接了GTest, glog这两个第三方库。

所以这个test_llm就是我们的单元测试的主程序。

单元测试的框架如下，主程序的main, 写在了test_main.cpp里面
![157](images/Pasted%20image%2020260703131733.png)


## 主程序
下面看一下单元测试test_llm这个可执行文件的主程序main
```c
#include <glog/logging.h>
#include <gtest/gtest.h>

//./test_llm --gtest_filter=test_buffer.*

int main(int argc, char* argv[]) {
//初始化 GTest 框架。 解析命令行参数（比如 `--gtest_filter`），去掉 GTest 认识的参数，把剩下的留给用户
  testing::InitGoogleTest(&argc, argv);
  
//初始化 glog。 参数 `"Kuiper"` 是程序名，会出现在日志输出里。glog 初始化后才能用 `LOG(INFO)` 等宏。
  google::InitGoogleLogging("Kuiper");
  
//设置日志文件输出目录。 glog 默认只输出到 stderr，设了这个就会同时写文件到 `./log/` 目录下
  FLAGS_log_dir = "./log/";
  
//日志同时输出到 stderr。 即使写了日志文件，也同时在终端打印
  FLAGS_alsologtostderr = true;

  //先打印一条日志
  LOG(INFO) << "Start Test...\n";
  
//启动所有测试。 这会找到所有 `TEST()` 宏注册的测试用例，逐个运行，返回 0 表示全部通过，非 0 表示有失败。
  return RUN_ALL_TESTS();
}
```

运行后日志为：
```txt

(base) liangji@ubun:~/AI_INFRA/projects/teacher/KuiperLLama/build/test$ ./test_llm --gtest_filter=test_buffer.*

I20260703 13:25:19.062956 138410764066816 test_main.cpp:10]      Start Test...
Note: Google Test filter = test_buffer.*
[==========] Running 7 tests from 1 test suite.
[----------] Global test environment set-up.
[----------] 7 tests from test_buffer
[ RUN      ] test_buffer.use_external1
[       OK ] test_buffer.use_external1 (156 ms)
```


## 测试单元

主程序的最后一句
`return RUN_ALL_TESTS();`

调用RUN_ALL_TESTS(), 这个就是GTest里面的函数，跳转到第三方库去执行所有注册了TEST()宏的测试用例

因为是宏函数，所以也不需要提前创建申请。GTest那边调用所有TEST宏函数

而我们注册的TEST(组名，用例名)，由于组名，用例名不同，刚好不冲突



>#include <gtest/gtest.h> 
>所以，每个测试组，只要include这个头文件，就能注册TEST宏函数了？ 我记得宏函数不得#define TEST()这样来定义宏函数吗？他这个怎么这样就能实现注册？****

![](images/Pasted%20image%2020260703133215.png)


**那么每个注册的TEST测试单元，要如何来判断该用例是否通过？**


不是靠 TEST 函数的返回值（它返回 `void`），而是靠**断言宏在失败时往测试结果对象里写记录**。


```c
// 全局的当前测试结果对象
static TestResult* current_test_result;

// ASSERT_EQ 简化版
#define ASSERT_EQ(a, b)                                                      \
  if ((a) != (b)) {                                                          \
    current_test_result->AddFailure("Expected " #a " == " #b);               \
    return;  // 立即终止当前测试                                             \
  }

```

![594](images/Pasted%20image%2020260703133530.png)

### 测试结果判断
分两大类：

#### ASSERT_失败立即终止当前测试

| 断言                      | 含义           |
| ----------------------- | ------------ |
| `ASSERT_TRUE(cond)`     | cond 为 true  |
| `ASSERT_FALSE(cond)`    | cond 为 false |
| `ASSERT_EQ(a, b)`       | a == b       |
| `ASSERT_NE(a, b)`       | a != b       |
| `ASSERT_LT(a, b)`       | a < b        |
| `ASSERT_LE(a, b)`       | a <= b       |
| `ASSERT_GT(a, b)`       | a > b        |
| `ASSERT_GE(a, b)`       | a >= b       |
| `ASSERT_STREQ(s1, s2)`  | 两个 C 字符串相等   |
| `ASSERT_FLOAT_EQ(a, b)` | 浮点数近似相等      |
|                         |              |
#### EXPECT_ 失败继续执行

`EXPECT_TRUE`、`EXPECT_EQ`、`EXPECT_NE`……和上面一一对应，只是失败后不 `return`，继续往下跑。

**选择原则**

- 一个测试里只需要检查一件事 → `ASSERT_*`
- 一个测试里需要检查多个独立条件，想看所有失败项 → `EXPECT_*`

项目中只用 `ASSERT_*`，因为每个测试都很短，一个断言失败后面的预期也没意义了。


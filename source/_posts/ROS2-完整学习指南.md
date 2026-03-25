---
title: ROS2 完整学习指南
date: 2026-03-25 17:57:53
categories: [学习笔记, 嵌入式, ROS] 
tags: [ros, cpp]
---
# 🚀 ROS2 完整学习指南

## 目录
1. [整体流程](#整体流程)
2. [详细讲解](#详细讲解)
3. [核心概念速查](#核心概念速查)
4. [日常使用命令](#日常使用命令)
5. [常见问题解答](#常见问题解答)

---

## 整体流程

```
【第0步】安装ROS2
    ↓
【第1步】创建工作空间 (workspace)
    ↓
【第2步】克隆源码到工作空间
    ↓
【第3步】安装依赖 (rosdep)
    ↓
【第4步】编译项目 (colcon build)
    ↓
【第5步】设置环境变量 (source setup.bash)
    ↓
【第6步】启动节点 (ros2 launch / ros2 run)
    ↓
【第7步】与节点交互 (ros2 service call / ros2 topic echo)
```

---

## 详细讲解

### 【第0步】安装 ROS2

```bash
# 从官方网站或鱼香ROS安装
# 这会安装到 /opt/ros/humble (或其他版本)
```

**安装后，ROS2给你提供了什么？**
- 编译工具：`colcon`
- 运行工具：`ros2` 命令行
- 基础库：`rclcpp`, `rclpy` 等
- 系统工具：`rosdep` (软件包管理器)

---

### 【第1步】创建工作空间 (Workspace)

```bash
mkdir -p ~/xsens_ws/src
cd ~/xsens_ws
```

**什么是工作空间？**

```
~/xsens_ws/                    ← 工作空间根目录
├── src/                       ← 源码目录（你的项目放这里）
│   └── xsens_mtw_driver_ros2-main/
│       ├── xsens_mtw_driver/
│       ├── interfaces/
│       └── ...
│
├── build/                     ← 构建目录（编译过程产生，可以删除）
│   ├── xsens_mtw_driver/
│   └── ...
│
├── install/                   ← 安装目录（可执行文件、库等）
│   ├── xsens_mtw_driver/
│   ├── setup.bash            ← ⭐ 最重要的文件
│   └── ...
│
└── log/                       ← 日志目录
```

**为什么要创建工作空间？**
- 隔离项目：不同项目用不同的工作空间
- 方便管理：编译、安装、运行都在这个目录下
- 环境隔离：一个工作空间的环境不会污染另一个

---

### 【第2步】克隆源码

```bash
cd ~/xsens_ws/src
git clone <仓库地址>
```

**现在你的目录结构是：**
```
~/xsens_ws/src/
└── xsens_mtw_driver_ros2-main/
    ├── xsens_mtw_driver/
    ├── interfaces/
    ├── README.md
    └── CMakeLists.txt
```

---

### 【第3步】安装依赖 (rosdep)

```bash
cd ~/xsens_ws

# 初始化rosdep（只需第一次）
sudo rosdep init

# 更新rosdep数据库
rosdep update

# 安装所有依赖
rosdep install --from-paths src --ignore-src -r -y
```

**这些命令做什么？**

| 命令 | 作用 |
|------|------|
| `rosdep init` | 初始化rosdep系统 |
| `rosdep update` | 从网络更新依赖包列表 |
| `rosdep install` | 自动安装所有依赖 |

**具体来说：**

`rosdep install` 会：
1. 读取所有 `package.xml` 文件
2. 找出声明的依赖（`<depend>`, `<build_depend>` 等）
3. 用系统包管理器（apt）安装这些依赖

```xml
<!-- xsens_mtw_driver/package.xml -->
<package>
  <name>xsens_mtw_driver</name>

  <build_depend>rclcpp</build_depend>      ← rosdep会安装这些
  <build_depend>tf2_ros</build_depend>
  <build_depend>geometry_msgs</build_depend>
  <exec_depend>rclcpp</exec_depend>
</package>
```

**如果没有 `rosdep install`：**
- 编译时会报错：`找不到 rclcpp/rclcpp.hpp`
- 因为依赖的库没装

---

### 【第4步】编译项目 (colcon build)

```bash
cd ~/xsens_ws
colcon build --symlink-install
```

**`colcon` 是什么？**

ROS2的编译工具，取代了ROS1的 `catkin_make`。

**编译流程：**

```
CMakeLists.txt (构建配置)
    ↓
colcon 读取
    ↓
    ├─ 找到所有package
    ├─ 按依赖顺序编译
    │  (interfaces先编译，因为其他包依赖它)
    ├─ 对每个package运行cmake
    └─ 生成可执行文件、库等
    ↓
build/ 目录
    ├─ xsens_mtw_driver/build文件
    ├─ interfaces/build文件
    └─ ...
    ↓
install/ 目录
    ├─ lib/xsens_mtw_driver/xsens_mtw_manager (可执行文件)
    ├─ lib/libxsensdeviceapi.so (库文件)
    ├─ setup.bash (环境脚本)
    └─ ...
```

**`--symlink-install` 是什么？**

```bash
正常编译：
install/ 中是复制的文件，修改代码需要重新编译

--symlink-install：
install/ 中是符号链接，指向 build/ 中的文件
修改Python代码后，不需要重新编译，直接生效

但对于C++代码，还是需要重新编译
```

**编译后，install 目录里有什么？**

```
install/
├── bin/                        (可执行文件)
├── lib/                        (库文件，包括.so)
│   ├── libxsensdeviceapi.so   ⭐
│   ├── libxstypes.so          ⭐
│   └── xsens_mtw_driver/
│       ├── xsens_mtw_manager
│       └── xsens_mtw_visualization
├── share/                      (数据文件)
│   └── xsens_mtw_driver/
│       ├── launch/
│       │   ├── xsens_mtw_manager.launch.py
│       │   └── xsens_mtw_visualization.launch.py
│       └── config/
│           └── params.yaml
└── setup.bash                  ⭐ 最重要！
```

---

### 【第5步】设置环境变量 (source setup.bash)

```bash
source ~/xsens_ws/install/setup.bash
```

**这一步很关键！做什么的？**

打开 `setup.bash` 看看：

```bash
$ cat install/setup.bash

#!/bin/bash
# 设置 CMAKE_PREFIX_PATH
export CMAKE_PREFIX_PATH="/opt/ros/humble:~/xsens_ws/install:$CMAKE_PREFIX_PATH"

# 设置 PYTHONPATH
export PYTHONPATH="~/xsens_ws/install/lib/python3.10/site-packages:$PYTHONPATH"

# 设置 LD_LIBRARY_PATH (重要！)
export LD_LIBRARY_PATH="~/xsens_ws/install/lib:$LD_LIBRARY_PATH"

# 设置 PATH
export PATH="~/xsens_ws/install/bin:$PATH"

# 其他环境变量...
```

**关键的4个环境变量：**

| 变量 | 作用 |
|------|------|
| **LD_LIBRARY_PATH** | 告诉OS在哪里找.so库文件 |
| **PATH** | 告诉OS在哪里找可执行文件 |
| **PYTHONPATH** | 告诉Python在哪里找模块 |
| **CMAKE_PREFIX_PATH** | 告诉CMake在哪里找包 |

**如果不 `source setup.bash`：**

```bash
$ ros2 run xsens_mtw_driver xsens_mtw_manager
Command 'xsens_mtw_manager' not found
# 或者
error while loading shared libraries: libxsensdeviceapi.so:
  cannot open shared object file
```

---

### 【第6步】启动节点

#### 方式1：用 launch 脚本（推荐）

```bash
ros2 launch xsens_mtw_driver xsens_mtw_manager.launch.py
```

**Launch 脚本做什么？**

```python
# xsens_mtw_manager.launch.py

def generate_launch_description():
    # 1. 找到params.yaml文件
    ros_config_params = get_package_share_path(...) / 'config/params.yaml'

    # 2. 创建一个节点配置
    node = Node(
        package='xsens_mtw_driver',
        executable='xsens_mtw_manager',
        parameters=[ros_config_params],  # 加载参数文件
    )

    # 3. 返回启动描述
    return LaunchDescription([node])
```

**Launch 脚本的好处：**
- ✅ 一条命令启动多个节点
- ✅ 自动加载参数文件
- ✅ 可以编程控制启动流程
- ✅ 可以设置重定向、命名空间等

---

#### 方式2：直接运行（不推荐）

```bash
ros2 run xsens_mtw_driver xsens_mtw_manager
```

**区别：**
- ❌ 没有参数加载
- ❌ 需要手动指定所有参数
- ✅ 键盘输入可以工作

---

### 【第7步】与节点交互

#### ① 查看节点信息

```bash
# 列出所有正在运行的节点
ros2 node list

# 输出
/xsens_mtw_manager
/xsens_mtw_visualization
```

---

#### ② 查看话题（Topic）

```bash
# 列出所有话题
ros2 topic list

# 输出
/xsens_imu_data
/tf
/xsens_sync
/rosout

# 查看某个话题的数据
ros2 topic echo /xsens_imu_data

# 输出
imu_data:
- header:
    seq: 42
    stamp:
      sec: 1234567890
      nsec: 123456789
  orientation:
    w: 0.707
    x: 0.0
    y: 0.0
    z: 0.707
---
```

---

#### ③ 调用服务（Service）⭐

```bash
# 列出所有服务
ros2 service list

# 输出
/xsens_mtw_manager/get_ready
/xsens_mtw_manager/start_recording
/xsens_mtw_manager/stop_recording
/xsens_mtw_manager/imu_reset

# 查看服务的参数格式
ros2 service type /xsens_mtw_manager/get_ready
# 输出：xsens_srvs/srv/Trigger

# 调用服务
ros2 service call /xsens_mtw_manager/get_ready xsens_srvs/srv/Trigger "{}"

# 输出
requester: making request: Trigger_Request()

response:
  success: true
  message: "Ready!"
```

**`ros2 service call` 的工作流程：**
1. 根据服务名找到对应的节点
2. 根据服务类型 (`xsens_srvs/srv/Trigger`) 知道参数格式
3. 发送请求给节点
4. 等待节点返回响应

---

## 核心概念速查

| 概念 | 是什么 | 例子 |
|------|--------|------|
| **工作空间** | 项目的根目录 | ~/xsens_ws/ |
| **package** | ROS中的一个项目单位 | xsens_mtw_driver |
| **节点** | 独立运行的程序 | xsens_mtw_manager |
| **话题** | 节点间的单向通信 | /xsens_imu_data |
| **服务** | 节点间的请求-响应通信 | /xsens_mtw_manager/get_ready |
| **参数** | 配置信息 | ros2_rate: 100 |
| **rosdep** | 依赖安装工具 | `rosdep install` |
| **colcon** | 编译工具 | `colcon build` |
| **launch** | 启动脚本 | xsens_mtw_manager.launch.py |

---

## 日常使用命令

### 编译和安装阶段
```bash
# 只需做一次，或修改代码后
cd ~/xsens_ws
colcon build --symlink-install
source install/setup.bash
```

### 运行阶段
```bash
# 需要每次终端都做（或在 ~/.bashrc 中添加）
source ~/xsens_ws/install/setup.bash

# 启动manager
ros2 launch xsens_mtw_driver xsens_mtw_manager.launch.py

# 【另一个终端】
source ~/xsens_ws/install/setup.bash

# 启动visualization
ros2 launch xsens_mtw_driver xsens_mtw_visualization.launch.py

# 【第三个终端】
source ~/xsens_ws/install/setup.bash

# 调用服务
ros2 service call /xsens_mtw_manager/get_ready xsens_srvs/srv/Trigger "{}"

# 查看数据
ros2 topic echo /xsens_imu_data
```

### 信息查询命令
```bash
# 列出所有节点
ros2 node list

# 查看某个节点的信息
ros2 node info /xsens_mtw_manager

# 列出所有话题
ros2 topic list

# 查看某个话题的详细信息
ros2 topic info /xsens_imu_data

# 实时查看话题数据
ros2 topic echo /xsens_imu_data

# 列出所有服务
ros2 service list

# 查看服务类型
ros2 service type /xsens_mtw_manager/get_ready

# 列出所有参数
ros2 param list

# 获取某个参数值
ros2 param get /xsens_mtw_manager ros2_rate

# 设置参数值
ros2 param set /xsens_mtw_manager ros2_rate 50
```

---

## 常见问题解答

### Q1: 为什么每个终端都要 `source setup.bash`？

**A:** 每个Bash shell都是独立的环境。`source setup.bash` 只对当前shell有效。新开一个终端时，环境变量被重置，需要重新 `source`。

**解决办法：** 把 `source` 命令加到 `~/.bashrc`：
```bash
echo "source ~/xsens_ws/install/setup.bash" >> ~/.bashrc
```
这样每次打开终端都自动加载。

---

### Q2: `colcon build` 报错找不到依赖，怎么办？

**A:** 确保执行了 `rosdep install`：
```bash
rosdep install --from-paths src --ignore-src -r -y
```

如果还是报错，可能需要：
1. 检查 `package.xml` 中是否正确声明了依赖
2. 确保 `rosdep update` 已经执行
3. 某些依赖可能需要手动安装

---

### Q3: 修改了代码需要重新编译吗？

**A:**
- **C++代码：** 必须 `colcon build`
- **Python代码：** 用 `--symlink-install` 的话，修改后直接生效
- **YAML配置：** 修改后直接生效（运行时加载）
- **Launch文件：** 修改后直接生效

---

### Q4: 怎么知道哪个节点提供了哪些服务？

**A:**
```bash
ros2 service list                    # 列出所有服务

ros2 service type /service_name       # 查看服务类型

ros2 service find xsens_srvs/srv/Trigger  # 查找某类型的服务

ros2 node info /xsens_mtw_manager    # 查看节点提供的所有服务
```

---

### Q5: 怎么给运行中的节点改参数？

**A:** 两种方法：

**方法1：编辑配置文件后重启节点**
```bash
# 修改 xsens_mtw_driver/config/params.yaml
ros2_rate: 50  # 改成50Hz

# 重启
colcon build
source install/setup.bash
ros2 launch xsens_mtw_driver xsens_mtw_manager.launch.py
```

**方法2：运行时修改**
```bash
ros2 param set /xsens_mtw_manager ros2_rate 50
```

---

### Q6: 怎么在多个工作空间之间切换？

**A:** 每个工作空间都有自己的 `setup.bash`，只需 `source` 不同的文件即可：

```bash
# 切换到ws1
source ~/ws1/install/setup.bash

# 切换到ws2
source ~/ws2/install/setup.bash

# 查看当前环境
echo $ROS_PACKAGE_PATH
```

**注意：** 不要同时 `source` 多个工作空间，会导致环境变量冲突。

---

### Q7: 怎么调试ROS2节点？

**A:**
```bash
# 查看节点日志
ros2 run xsens_mtw_driver xsens_mtw_manager --ros-args --log-level DEBUG

# 使用 rqt_console 查看日志
rqt_console

# 使用 rosbag 录制数据
ros2 bag record /xsens_imu_data

# 播放录制的数据
ros2 bag play <bag_file>
```

---

### Q8: build 和 install 目录可以删除吗？

**A:**
- **可以删除：** `build/` 和 `install/` 可以随时删除
- **需要重新编译：** 删除后需要再次 `colcon build`
- **环境失效：** 删除 `install/` 后需要重新 `source setup.bash`

通常当编译出现问题时，可以尝试：
```bash
rm -rf build/ install/ log/
colcon build --symlink-install
```

---

## 完整的工作流总结

```
┌─────────────────────────────────────────────────────────────┐
│                    【你的计算机】                            │
└─────────────────────────────────────────────────────────────┘

1️⃣ 安装 ROS2
   /opt/ros/humble/
   ├── bin/          (colcon, ros2等命令)
   ├── lib/          (ROS2的库文件)
   └── share/        (配置、消息定义等)

2️⃣ 创建工作空间
   ~/xsens_ws/
   ├── src/          (你的源码)
   └── install/      (编译后的可执行文件和库)

3️⃣ 克隆项目
   src/xsens_mtw_driver_ros2-main/
   ├── CMakeLists.txt
   ├── package.xml
   └── 源代码...

4️⃣ 安装依赖 (rosdep install)
   下载: rclcpp, tf2_ros, geometry_msgs 等

5️⃣ 编译 (colcon build)
   编译C++代码生成可执行文件
   复制/链接文件到 install/

6️⃣ 设置环境 (source setup.bash)
   告诉OS在哪里找库和可执行文件
   设置 LD_LIBRARY_PATH, PATH 等

7️⃣ 启动节点 (ros2 launch)
   运行 xsens_mtw_manager 节点
   节点开始发布话题、提供服务

8️⃣ 交互 (ros2 service call)
   调用节点提供的服务
   订阅节点发布的话题
```

---

## 深入学习资源

### 官方文档
- [ROS2官方文档](https://docs.ros.org/en/humble/)
- [ROS2 Tutorials](https://docs.ros.org/en/humble/Tutorials.html)
- [ROS2 Concepts](https://docs.ros.org/en/humble/Concepts.html)

### 本地命令帮助
```bash
# 查看所有ros2子命令
ros2 --help

# 查看某个命令的帮助
ros2 run --help
ros2 launch --help
ros2 service --help
```

---

## 关键要点总结

✅ **理解工作空间的目录结构**
- src/: 源码
- build/: 编译产物
- install/: 安装产物

✅ **掌握编译流程**
- rosdep install: 安装依赖
- colcon build: 编译代码
- source setup.bash: 设置环境

✅ **了解ROS2的通信方式**
- 话题 (Topic): 单向流式数据
- 服务 (Service): 请求-响应式通信
- 参数 (Parameter): 配置信息

✅ **学会与节点交互**
- ros2 run: 运行节点
- ros2 launch: 用脚本启动
- ros2 service call: 调用服务
- ros2 topic echo: 查看数据

✅ **熟悉常用命令**
- ros2 node list
- ros2 topic list
- ros2 service list
- ros2 param list

---

**现在你已经掌握了ROS2的基本概念和使用方法，可以开始深入学习和开发了！** 🚀

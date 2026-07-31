


# 概念扫描

<mark style="background:#d3f8b6">1. 离线推理/在线推理</mark>
- 离线推理：
	- 直接把prompt写在python程序里面启动
- 在线推理：
	- 做成server，接受客户端的访问

<mark style="background:#d3f8b6">2. 安装vllm, 查看版本</mark>
![172](../images/Pasted%20image%2020260728192125.png)
![](../images/Pasted%20image%2020260728192137.png)


<mark style="background:#d3f8b6">3. 服务器双进程架构</mark>
- 进程0：**LLMEngine**
	- 专注于server功能提供
- 进程1：**EngineCore**
	- 专注于模型推理
```txt

                 用户输入
                    |
                    |
                    v
        +-------------------------+
        |        Process 0         |
        |       LLMEngine          |
        |                          |
        |  1. 接收 prompts          |
        |  2. tokenizer 分词        |
        |  3. 创建请求 Request      |
        |                          |
        |  EngineCoreClient         |
        +------------+-------------+
                     |
                     |
              ZeroMQ (ZMQ)
              IPC通信通道
                     |
                     |
                     v
        +------------+-------------+
        |        Process 1         |
        |      EngineCore          |
        |                          |
        |  输入队列 Input Queue     |
        |            |             |
        |            v             |
        |       Scheduler          |
        |            |             |
        |            v             |
        |     调度 GPU 推理         |
        |                          |
        |  ModelRunner              |
        |      |                   |
        |      v                   |
        |     CUDA                  |
        |      |                   |
        |      v                   |
        |   LLM Model              |
        |                          |
        +------------+-------------+
                     |
                     |
              输出队列 Output Queue
                     |
                     |
              ZeroMQ (ZMQ)
                     |
                     |
                     v
        +------------+-------------+
        |        Process 0         |
        |                          |
        |  接收推理结果             |
        |  返回用户                 |
        +------------+-------------+
                     |
                     |
                     v
                生成文本

```
![](../images/Pasted%20image%2020260728192930.png)


![](../images/Pasted%20image%2020260728193031.png)


<mark style="background:#d3f8b6">3. RPC，远程过程调用</mark>
对函数的调用，实际是调用的远程的方法（利用ZMQ等进程间通信实现），但是对上层是无感的，实际上就是把远程服务包装成函数，来实现无感的远程计算

![632](../images/Pasted%20image%2020260728193926.png)


4. vllm的版本
![](../images/Pasted%20image%2020260728200401.png)


![464](../images/Pasted%20image%2020260728200351.png)![](../images/Pasted%20image%2020260728200457.png)



<mark style="background:#d3f8b6">4. 协程，async</mark>
可以简单理解为asyncio这个库带来的一个后台执行任务的机制。
![552](../images/Pasted%20image%2020260728212634.png)



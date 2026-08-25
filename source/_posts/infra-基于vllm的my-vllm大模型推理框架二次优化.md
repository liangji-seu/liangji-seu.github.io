

本项目主要基于对vllm的源码的理解，来实现一个AsyncLLM + EngineCore的 my-vllm项目


# 概念扫盲

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


# vllm和cuda自制推理框架的区别

我们原来cuda自制推理框架，实现的是最底层的架构。专注于，张量，算子的实现。专注于底层的：
- 内存分配器层
- buffer层
- tensor层
- op层
- model层
- 最后简单的离线固定demo层。


而vllm则侧重于针对demo层，把这个推理框架彻底做成一个可以部署使用的服务，而不再是一个简单的demo。

所以demo继续细分成：
- LLMEngine/AsyncLLM
	- 用来实现调度，作为服务的前端，来实现一个server
- EngineCore
	- 就是demo的核心实现，generate()方法，实现一个token的输出

![](../images/img_v3_02145_56ca00f8-f4e0-44e2-8a71-9ea86be18e5g.jpg)

# ZeroMQ（ZMQ）

这是一个python的库，用来进行进程间通信的。在这里，我们将先熟悉LLMEngine/AsyncLLM 和 EngineCore之间的通信技术

我们先来了解一下，网络传输模型层级
![](../images/Pasted%20image%2020260801132451.png)
![492](../images/Pasted%20image%2020260801132555.png)


<mark style="background:#ff4d4f">那socket是什么呢？</mark>

本质上，socket就是一个内核的文件描述符，是通过特定的方式（系统调用）创建出来的内核的内存区域的文件描述符。

![](../images/Pasted%20image%2020260801132711.png)

![](../images/Pasted%20image%2020260801132918.png)

而在zmq中，他为了支持N对N的高性能消息通信，对socket的tcp的这种点对点的逻辑，进行了改造，自己内部实现了一个更加抽象的socket
![594](../images/Pasted%20image%2020260801133029.png)

![](../images/Pasted%20image%2020260801133104.png)

## 同步REQ/REP通信模式

**下面实现一个最简单的zmq的server + client**
![259](../images/Pasted%20image%2020260801134001.png)![253](../images/Pasted%20image%2020260801134016.png)

![](../images/Pasted%20image%2020260801133948.png)

<mark style="background:#ff4d4f">这种模式要求通信双方严格遵循**一问一答**的交互流程——客户端必须先发送请求并等待回复，不能连续发送两次请求，否则会引发异常</mark>


**一个端口只能被一个server进程 bind**，服务器 bind 端口，相当于**我在 5555 号开门营业**：

尽管多个客户端可以同时连接到该服务端，ZeroMQ 会在传输层缓存它们的请求，但<mark style="background:#fff88f">服务端仍以串行方式逐个处理这些请求</mark>。另外，<mark style="background:#fff88f">服务端无法主动向客户端发起连接</mark>，因此这种模式<mark style="background:#ff4d4f">不符合</mark>我们在 vLLM 中的通信需求


## DEALER/ROUTER通信模式

前面的req-rep通信模式的弊端：
- 同步阻塞
- 串行通信

这个都不符合我们vllm的需求：
- 异步通信
- 并发通信

![](../images/Pasted%20image%2020260801135330.png)
> 注意，这里的DEALER套接字实现的异步，是说的send之后，不需要阻塞recv了，可以非阻塞方式recv

所以ROUTER，DEALER都是套接字，可以理解为内核的一块内存区域，类对象，多对多异步双向通信


启动一个server线程，三个client线程
![365](../images/Pasted%20image%2020260801154433.png)



![475](../images/Pasted%20image%2020260801154445.png)


可以看到这边都是可以正常接收的，但是这里有一个问题，就是，我们的服务器，设置了一个ROUTER的socket套接字，这个套接字代表的端口，是用来处理某一类事务的：
- **A ROUTER 套接字**：
	- 接收推理请求
- **B ROUTER 套接字**：
	- 接收控制命令
- **C ROUTER 套接字**：
	- 订阅配置更新

显然，我们这里定义的一个frontend套接字，是为了推理请求的。然后针对这个frontend，来阻塞接收，用recv_multipart()，这个套接字，会有多个client来进行访问。


<mark style="background:#ff4d4f">这里纠正一个理解</mark>：
![](../images/Pasted%20image%2020260803164317.png)
这个其实就是一个一对多的发送机制，不需要遵循应答限制了，直接用就ok




![517](../images/Pasted%20image%2020260801154531.png)



但是这里有一个问题，当我们的server线程要提供多个功能的时候，每个功能都有一个ROUTER的套接字，这个时候，显然不可能在主循环里面，挨个阻塞，这肯定不行。

这个时候，就需要**poll机制，来实现批量ROUTER监听**。同时，poll机制还提供超时返回的功能。

> 我这里还有一个疑问，这里的poll实现的多路监听，本质上是针对server线程的多个ROUTER的套接字，这个每个ROUTER套接字都对应一个端口，代表一个server的接口服务，对吧，但是每个ROUTER是接收多个client的连接的，但是每个端口里面这部还是串行响应client的请求吗？


![](../images/Pasted%20image%2020260801155746.png)


![](../images/Pasted%20image%2020260801155807.png)

![402](../images/Pasted%20image%2020260801155819.png)

![436](../images/Pasted%20image%2020260801155828.png)



所以，最终应该是poll + 线程池，来实现一个**多路监听，并行处理**的server
```python
import threading
import sys
import time
import zmq
import argparse
import uuid
from concurrent.futures import ThreadPoolExecutor




def server_poll_with_workers():
    context = zmq.Context.instance()
    frontend = context.socket(zmq.ROUTER) #多对一并行接收的套接字
    frontend.bind("tcp://localhost:6666")

    print("server start: 6666")

    # 定义模拟推理处理数据的过程
    def process_inference(data):
        time.sleep(0.5)
        return {
            "status": "success",
            "result": f"服务器收到消息:{data['query']}",
            "timestamp": time.time(),
        }

    poller = zmq.Poller()
    poller.register(frontend, zmq.POLLIN)

    executor = ThreadPoolExecutor(max_workers=4) #4个线程的线程池
    lock = threading.Lock()

    # 线程池的workers的工作函数
    def handle_request(identity, request):
        result = process_inference(request)

        # 构造回复response json
        response = {
            "msg_id": request['msg_id'],
            "reply": result,
            "from_engine": "server-0",
        }
        with lock:
            # 走端口返回，因为是4个worker来访问frontend这个套接字，所以需要加锁
            frontend.send_multipart([identity, zmq.utils.jsonapi.dumps(response)])


    try:
        while 1:
            socks = dict(poller.poll(1000))
            multipart = []
            if frontend in socks:
                multipart = frontend.recv_multipart()
                if not multipart:
                    continue

                identity = multipart[0]
                message = multipart[-1]

                request = zmq.utils.jsonapi.loads(message)
                print(f"server recv: {identity.decode()} request:{request['msg_id']}")

                # 现在改成向线程池提交异步任务，4个worker并行处理
                executor.submit(handle_request, identity, request)

                ''' 原来的串行处理
                result = process_inference(request)

                # 构造回复response json
                response = {
                    "msg_id": request['msg_id'],
                    "reply": result,
                    "from_engine": "server-0",
                }
                frontend.send_multipart([identity, zmq.utils.jsonapi.dumps(response)])
                '''
    except KeyboardInterrupt:
        print("server close")

    finally:
        frontend.close()





def server_poll():
    context = zmq.Context.instance()
    frontend = context.socket(zmq.ROUTER) #多对一并行接收的套接字
    frontend.bind("tcp://localhost:6666")

    print("server start: 6666")

    # 定义模拟推理处理数据的过程
    def process_inference(data):
        time.sleep(0.5)
        return {
            "status": "success",
            "result": f"服务器收到消息:{data['query']}",
            "timestamp": time.time(),
        }

    poller = zmq.Poller()
    poller.register(frontend, zmq.POLLIN)


    try:
        while 1:
            socks = dict(poller.poll(1000))
            multipart = []
            if frontend in socks:
                multipart = frontend.recv_multipart()
                if not multipart:
                    continue

                identity = multipart[0]
                message = multipart[-1]

                request = zmq.utils.jsonapi.loads(message)
                print(f"server recv: {identity.decode()} request:{request['msg_id']}")

                result = process_inference(request)

                # 构造回复response json
                response = {
                    "msg_id": request['msg_id'],
                    "reply": result,
                    "from_engine": "server-0",
                }
                frontend.send_multipart([identity, zmq.utils.jsonapi.dumps(response)])

    except KeyboardInterrupt:
        print("server close")

    finally:
        frontend.close()



def server():
    context = zmq.Context.instance()
    frontend = context.socket(zmq.ROUTER) #多对一并行接收的套接字
    frontend.bind("tcp://localhost:6666")

    print("server start: 6666")

    # 定义模拟推理处理数据的过程
    def process_inference(data):
        time.sleep(0.5)
        return {
            "status": "success",
            "result": f"服务器收到消息:{data['query']}",
            "timestamp": time.time(),
        }

    try:
        while 1:
            multipart = frontend.recv_multipart()
            if not multipart:
                continue

            identity = multipart[0]
            message = multipart[-1]

            request = zmq.utils.jsonapi.loads(message)
            print(f"server recv: {identity.decode()} request:{request['msg_id']}")

            result = process_inference(request)

            # 构造回复response json
            response = {
                "msg_id": request['msg_id'],
                "reply": result,
                "from_engine": "server-0",
            }
            frontend.send_multipart([identity, zmq.utils.jsonapi.dumps(response)])

    except KeyboardInterrupt:
        print("server close")

    finally:
        frontend.close()




def client(client_id):
    context = zmq.Context.instance()
    socket = context.socket(zmq.DEALER) # 异步双向套接字

    #id编码成字节流
    identity = f"Client-{client_id}".encode("utf-8")
    socket.setsockopt(zmq.IDENTITY, identity)

    socket.connect("tcp://localhost:6666") #连接6666端口服务
    print(f"client: {client_id} start, 连接到6666server")

    #开始用异步双向socket发送多个请求测试
    for i in range(5):
        request = {
            # UUID = Universally Unique Identifier（通用唯一标识符），类似消息的md5
            "msg_id": str(uuid.uuid4()),
            "query": f"请求{i} 来自 Client-{client_id}",
            "timestamp": time.time(),
        }
        socket.send_json(request)
        print(f"client-{client_id} 发送请求 {request['msg_id']}")
        

    
    # 异步阻塞接收
    for _ in range(5):
        response = socket.recv_json()#非阻塞接收
        print(f"Client-{client_id} 收到响应：{response}")


    socket.close()




if __name__ == "__main__":
    t_start = time.time()

    engine_thread = threading.Thread(target=server_poll_with_workers,daemon=True)
    engine_thread.start()

    time.sleep(1)
    print(f"[{time.time() - t_start:.3f}s] 服务端启动完成")

    client_threads = []
    for i in range(3):
        t = threading.Thread(target = client, args=(i,),daemon=True)
        t.start()
        client_threads.append(t)

    print(f"[{time.time() - t_start:.3f}s] 3 个客户端已启动")

    try:
        for t in client_threads:
            t.join()
        print(f"[{time.time() - t_start:.3f}s] 所有客户端完成")
        time.sleep(2)
    except KeyboardInterrupt:
        print("over")

    t_end = time.time()
    print(f"======================================")
    print(f"  总耗时: {t_end - t_start:.3f}s")
    print(f"======================================")

```

## PUSH/PULL 通信模式
这个通信模式，是无回复的，上面的REQ-REP模式是有回复的。

这个单向传输模式，适合EngineCore把decode的输出，push给LLMEngine，无需前端回复

**PUSH 与 PULL 是 ZeroMQ 所提供的单向数据流通信模式，构成一个无回复、单向的消息管道**

消息从 PUSH 端发送，由 PULL 端接收

**模型每推理出一个 token 就可以通过 PUSH 端发送一次，消费端 AsyncLLM 则持续监听并接收新的数据分块**






# FastAPI, uvicorn
这两个python库，主要学习如何用python构建web服务，来实现真正面对用户的服务器接口，是如何把服务器的接口来和我们的AsyncLLM的客户端的各种行为绑定的

## 基础使用
vllm里面主要掌握这几个部分的使用即可
- **基础app服务**
	- 路径参数，查询参数
	- 指令
		- GET 查询
		- POST 新建
		- PUT 完整更新
		- PATCH 部分更新
	- http的帧协议：
		- ![](../images/Pasted%20image%2020260805110133.png)
		- 我们在curl里面，-H 可以指定修改我们的默认请求头，新增请求头，接受的时候，服务端就用查询参数的命名+ 默认Header(None)即可
		- -X可以指定我们的请求体，也就是结构化的自定义数据，底层会默认转成json-元组的转换
	- 自定义数据
	- 请求头，Cookie
		- 请求头就是Header(None), 这是一个空的最基础的请求头，比如选择user_agent, 还可以新增自己的请求头，cookie=Cookie(None), 这个Cookie也是一个Header的子类，可以帮我们拆分获取更加细致的cookie的内容。
		- cookie就是客户端保存的一些信息，比如上次浏览服务器的一些缓存信息, 这样一并发过来，就可以直接复用之前的信息了。
	- **流式响应**：
		- 这个需要对协程的理解，主要利用的是yield，把协程任务变成了可迭代的对象，之后就可以用async for 来异步迭代访问这个迭代对象，从而实现一个流式的响应（在这里，fastapi的库给我们封装了一个StreamingResponse方法，用来实现async for的异步迭代访问）
- **具有lifespan的app服务**
	- 这个就是具有构造和析构逻辑的app服务，vllm在这个构造和析构里面来构造我们的大模型推理环境，这样就可以直接进行generate()推理了。


## demo

```python
  

'''
基础使用：路径参数，查询参数
'''
from fastapi import FastAPI

app = FastAPI()

# 定义根路径的GET路由
@app.get("/")
async def root():
    return {"message": "hello world"}


@app.get("/items/{item_id}")
async def read_item(item_id: int, q: str | None = None):
    return {"item_id": item_id, "q": q}






'''
post新建，put完整更新指令 + 自定义数据
'''
from pydantic import BaseModel



# 定义请求体的数据模型
class Item(BaseModel):
    name: str
    description: str | None = None
    price: float
    tax: float | None = None


@app.post("/items/")
async def create_item(item: Item):
    return item # 创建一个新的对象

@app.put("/items/{item_id}")
async def update_item(item_id: int, item: Item):
    return {"item_id": item_id, "item_name": item.name}



'''
请求头+ Cookie
'''
from fastapi import Header, Cookie, Request

@app.get("/items/header/")
def test_head(user_agent: str = Header(None), session_token: str = Cookie(None)):
    return {"User-Agent": user_agent, "Session-Token": session_token}

@app.get("/items/header/all")
def all_headers(request: Request):
    return dict(request.headers)  # 返回全部请求头








"""
══════════════════════════════════════════
示例 ①：流式响应（SSE）— vLLM 逐 token 返回的核心
══════════════════════════════════════════
"""
import asyncio
from fastapi.responses import StreamingResponse


@app.post("/chat/stream")
async def chat_stream(prompt: str):
    """模拟 vLLM 的流式输出：逐 token 推给客户端"""

    async def generate():
        tokens = ["你", "好", "，", "我是", "AI", "，", prompt]
        for token in tokens:
            yield f"data: {token}\n\n"  # SSE 格式（Server-Sent Events）
            await asyncio.sleep(0.3)    # 模拟推理耗时
        yield "data: [DONE]\n\n"         # 结束标记



    '''
    可迭代对象：
        能for x in obj 的就是，列表，字符串，文件都是

    yield
        函数里面的return是一次性全给，yield是一次给一个，暂停，等你取走，继续


                def normal():
                    return [1, 2, 3]     # 一次性全给，函数结束

                def gen():
                    yield 1               # 给一个，暂停
                    yield 2               # 再给一个，暂停
                    yield 3               # 再给一个，结束

                # 用它
                for num in gen():         # for 循环逐个取
                    print(num)            # 1 → 2 → 3，每次循环取一个 yield

        内存上利差别大：return 100万个 token 先攒好；yield 每生成一个就立刻给出去，不攒。


    
        
    async for 
            普通for 在取下一个的时候必须阻塞， async for可以停下等待去处理其他请求
            async for, 以及async def generate，都可以看成是协程任务了，这样生成器不会阻塞，主线程迭代for也不会阻塞

    '''

    # 第一个参数必须是能够被迭代的对象。
    # generate()是一个异步生成器，也就是async def + yield
    return StreamingResponse(generate(), media_type="text/event-stream")




"""
══════════════════════════════════════════
示例 ②：lifespan — vLLM 的方式：启动时创建引擎，关闭时清理
══════════════════════════════════════════
"""
from contextlib import asynccontextmanager


# 用 lifespan 替代直接 FastAPI()，vLLM 就是这样做的（api_server.py:173-179）

@asynccontextmanager # 让yield从生成器切换成切分点
async def lifespan(app: FastAPI):


    '''
    启动程序 = async with 的__aenter__，  就是构造函数
    '''

    """模拟 vLLM 的 lifespan：启动建引擎 → 运行 → 关闭清理"""
    print("[lifespan] 启动中... 初始化 AsyncLLM（模拟）")
    await asyncio.sleep(1)
    app.state.engine = {"status": "ready"}    # 挂到 app.state，handler 能取
    print("[lifespan] 引擎就绪，开始对外服务")



    # 切分点
    yield                                      # ← 这里暂停，服务运行中


    '''
    结束程序 = async with 的__aexit__， 就是析构函数
    '''
    print("[lifespan] 关闭中... 清理引擎")
    await asyncio.sleep(0.5)
    print("[lifespan] 已关闭")


# 注意：用了 lifespan 后之前的 app 要改成这样，这里单独建一个演示用

# 这是一个带构造和析构逻辑的一个新的app， lifespan就是指定构造析构函数
app_with_lifespan = FastAPI(lifespan=lifespan)


@app_with_lifespan.get("/engine/status")
async def engine_status(request: Request):
    """handler 通过 app.state 取引擎状态"""
    return request.app.state.engine


# 测试: uvicorn api_server:app_with_lifespan --port 8001
#       curl http://localhost:8001/engine/status
#       按 Ctrl+C 看 lifespan 的 shutdown 日志



```


# python协程
cpu调度的最小单位是线程，所以协程仅仅存在于线程里面，依赖于asyncio这个事件循环库。

可以简单理解为依托于这个线程，实现了一个多任务系统，类似rtos，引入协程任务的概念

> 协程任务和我们的主线程是分离开的，互不影响，就用rtos的概念来理解即可

## 定义一个协程任务task
```python
async def task_A():
	return;

async def task_B():
	# xxx
	await task_A()
	return
	
	
asyncio.run(task_B())

#fastapi里面支持的绑定服务接口
@app.get("/items/")
async def task_C():
	reutrn
```
以上就是一个最简单的协程任务的基础用法
- async 来定义一个协程任务
- await来阻塞等待一个协程任务，并挂起自己这个协程任务
- asyncio.run来启动事件循环（启动所有任务）
- fastapi里面支持把服务器接口和协程任务绑定，这样可以异步调用。


# python的一些语法

## weakref.finalize(方法)
- weakref， python的弱引用库
	- 可以在不增加对象引用的前提下，访问对象
- weakref.finalize, 注册一个对象的清理回调工具
	- 可以用来注册对象被销毁退出时候的钩子函数

## python多进程编程
- spawn
	- 创建一个新的 Python 解释器， 绕开GIL。  
	- 速度比 fork 或者 forkserver 模式慢。  
	- windows | macOS 下的默认模式， unix 也支持。  
	- 并非继承（或者拷贝）父进程的全部资源，而是主动传入进程对象run方法所需的资源，子进程会拷贝一份传递进来的资源
	- <mark style="background:#fff88f">总结来说，就是深拷贝，直接把传入的对象指针的内存进行拷贝</mark>
		- <mark style="background:#fff88f">因此不可以传递：文件对象|文件句柄、线程锁，如果需要，则需要另外创建</mark>
- fork
	- 就是单纯的浅拷贝 + Cow， 子进程修改的时候才会重新申请内存进行深拷贝
- forkserver

fork和spawn都是构建子进程的不同方式，区别在于：

<mark style="background:#fff88f">fork：</mark>**除了必要的启动资源外，其他变量，包，数据等都继承自父进程，并且是copy-on-write的，也就是共享了父进程的一些内存页，因此启动较快，但是由于大部分都用的父进程数据，所以是不安全的进程**

<mark style="background:#fff88f">spawn</mark>：**从头构建一个子进程，父进程的数据等拷贝到子进程空间内，拥有自己的Python解释器，所以需要重新加载一遍父进程的包，因此启动较慢，由于数据都是自己的，安全性较高**

实际使用中可以根据子进程具体做什么来选取用fork还是spawn~


## Python GIL

### GIL工作原理
在Python中，[全局解释器锁](https://zhida.zhihu.com/search?content_id=241506919&content_type=Article&match_order=1&q=%E5%85%A8%E5%B1%80%E8%A7%A3%E9%87%8A%E5%99%A8%E9%94%81&zhida_source=entity)（`Global Interpreter Lock，简称GIL`）

GIL是Python解释器中的一个互斥锁，<mark style="background:#fff88f">它确保在同一时刻只有一个线程能够执行Python字节码</mark>

这意味着在多线程环境下，Python解释器无法同时利用多个CPU核心进行并行执行，因为只有一个线程能够执行Python[字节码指令](https://zhida.zhihu.com/search?content_id=241506919&content_type=Article&match_order=1&q=%E5%AD%97%E8%8A%82%E7%A0%81%E6%8C%87%E4%BB%A4&zhida_source=entity)


当Python解释器运行Python代码时，它会获取GIL，然后执行相应的字节码指令。其他线程想要执行Python字节码时，必须先获取GIL，但只有在当前线程释放GIL后才能获得。因此，只有一个线程能够在任意时刻执行Python字节码，这就是GIL的工作原理

### 多线程的影响
GIL最大的问题就是Python的多线程程序并不能利用多核CPU的优势 （比如一个使用了多个线程的计算密集型程序只会在一个单CPU上面运行）

有一点要强调的是GIL只会影响到那些严重依赖CPU的程序（比如计算型的）。 如果你的程序大部分只会涉及到I/O，比如网络交互，那么使用多线程就很合适， 因为它们大部分时间都在等待


### 多进程的影响
GIL只是影响多线程的并发执行同一段代码

在 Python 中，GIL（全局解释器锁）只影响到了多线程，而不会对多进程产生直接的影响。多进程是通过创建不同的 Python 解释器来实现的，因此每个进程都有自己的独立 GIL，它们之间互不影响



## vllm的系统属性的实现

- `os.environ` 是操作系统环境变量的一个 **dict-like 对象**， **用来保存我们的属性项和具体的内容**
	- 正常我们在添加到这里面的对象后，通过
	- os.environ.get("VLLM_WORKER_MULTIPROC_METHOD")
	- os.getenv("VLLM_WORKER_MULTIPROC_METHOD")
	 - 来读取这个属性

- vLLM 提供了一种**懒读取**的封装：写 `envs.VLLM_WORKER_MULTIPROC_METHOD`，不用手动写 `os.getenv("VLLM_WORKER_MULTIPROC_METHOD")`


## OMP_NUM_THREADS的实现

`OMP_NUM_THREADS` 是 **OpenMP 的标准环境变量**，控制并行区域中的线程数。PyTorch 底层在 CPU 上做矩阵运算时会用到它：

```python
# 跟 vLLM 无关，任何使用 OpenMP 的程序都认这个变量
$ OMP_NUM_THREADS=4 python my_script.py
```

```python
def set_multiprocessing_worker_envs(local_world_size: int = 1):
    _maybe_force_spawn()

    # 两种情况直接跳过，不设置：
    # ① CPU 平台：不需要 GPU worker 的线程管理
    # ② 用户已经手动设好了 $OMP_NUM_THREADS
    if current_platform.is_cpu() or "OMP_NUM_THREADS" in os.environ:
        return

    # 否则，vLLM 自动计算一个合理值并写进 os.environ
    num_threads = startup_omp_num_threads(local_world_size)
    os.environ["OMP_NUM_THREADS"] = str(num_threads)   # ← 主动注入
```


```python
# Python 标准库能做的：
import threading
t = threading.Thread(target=work)    # ← Python 层的线程

# Python 标准库管不了的：
# PyTorch 底层是 C++ 写的，内部有自己的 OpenMP 线程池
a @ b   # ← 矩阵乘法，背后 C++ 开了 N 个 OpenMP 线程并行计算
```

`torch.set_num_threads()` 控制的是**后者**——PyTorch C++ 底层在 CPU 上做运算时会开多少个线程。Python 的 `threading` 模块对此一无所知。

## 网络通信

网络通信4要素
```
tcp://127.0.0.1:29500
 ─┬─   ───┬───  ──┬──
  │       │       └── 端口号 (Port)：找到机器上的哪个服务
  │       └── IP 地址 (Address)：找到网络上的哪台机器
  └── 协议 (Protocol)：用什么方式传数据
```

| 要素         | 是什么                      | 你刚看过的代码                                                 |
| ---------- | ------------------------ | ------------------------------------------------------- |
| **协议**     | TCP / UDP / IPC / inproc | `tcp://`                                                |
| **IP 地址**  | 哪台机器                     | `get_loopback_ip()` → `127.0.0.1`                       |
| **端口号**    | 机器上的哪个程序                 | `get_open_port()` → `29500`                             |
| **Socket** | 操作系统提供的读写接口，把上面三个绑在一起    | `socket.socket()` → `bind()` → `listen()` / `connect()` |

 **跟 vLLM 代码的对应关系**

```python
# ① 拼出地址字符串（URL）
url = get_distributed_init_method(get_loopback_ip(), get_open_port())
#  → "tcp://127.0.0.1:29500"

# ② 把地址字符串传给 PyTorch，PyTorch 内部帮你做 socket bind/connect
torch.distributed.init_process_group(backend="nccl", init_method=url)
#  ↑ 这个函数内部：
#     - Master 进程：socket() → bind("127.0.0.1", 29500) → listen() → accept()
#     - Worker 进程：socket() → connect("127.0.0.1", 29500)
#     - 握手完成后 → 释放 rendezvous socket
```

URL 是**地址字符串**，告诉对方"去哪找我"。Socket 是**操作系统提供的读写工具**，真正用来收发字节。URL 是地图上的坐标，Socket 是敲门的动作。


### 网络协议层级

```
应用层    HTTP, gRPC, Redis Protocol, PyTorch Rendezvous ...
         ─────────────────────────────────────────────────
传输层    TCP, UDP, IPC, inproc
         ─────────────────────────────────────────────────
网络层    IP (127.0.0.1, 192.168.x.x)
```

**传输层**管"数据怎么传过去"——可靠还是不可靠、面向连接还是无连接。  
**应用层**管"传过去的数据什么意思"——是网页请求还是数据库查询。



在 [network_utils.py](vscode-webview://0v6anhu7rvonmrg5eum0t53r31phukqu6outl7a0k1sdqa1epd0b/vllm/utils/network_utils.py) 里你能找到这些：

```python
# ① TCP — 可靠、面向连接、可以跨机器
"tcp://127.0.0.1:29500"        # get_distributed_init_method()
socket.SOCK_STREAM               # TCP socket

# ② UDP — 不可靠、无连接、只管发包不管对方收没收到
socket.SOCK_DGRAM                # test_loopback_bind() 里用的

# ③ IPC — Unix Domain Socket，只能本机通信，不走网络栈，比 TCP 快
"ipc:///tmp/vllm/xxxx"          # get_open_zmq_ipc_path()

# ④ inproc — 同进程内通信，零拷贝，最快
"inproc://xxxx"                 # get_open_zmq_inproc_path()
```

正常ipc, inproc是不属于网络协议的，但是python 的 ZMQ把他兼容进来了

就是 **ZMQ（ZeroMQ）**——一个把各种通信方式统一成同一种 API 的库。

```python
# 不管底层是什么，用法完全一样
zmq_socket.bind("tcp://127.0.0.1:29500")
zmq_socket.bind("ipc:///tmp/vllm/xxxx")
zmq_socket.bind("inproc://xxxx")
#               ↑
#          协议前缀不同，代码一样
```
ZMQ 用一个统一的 `zmq://` 格式把它们包在同一套 API 里。你用 `bind("inproc://foo")` 还是 `bind("tcp://bar")`，代码一模一样，ZMQ 在背后帮你处理底层差异。


可以这样简单理解
- context = zmq.Context()
	- 构造zmq的上下文，其实就是socket发送接受的缓冲区
- socket = context.socket(zmq.PUB)
	- 构造一个套接字socket, 这个套接字，你就理解成是持有这种通信机制的输入输出的缓冲区，代替你来实现网络通信的实例对象，发送接受调用它的方法来。


## 共享内存，zmq.PUB-SUB, 多进程环境继承，编码utf-8

我做了一个实验，可以从代码里面很简单学明白这些概念
```python
import zmq
import multiprocessing
import multiprocessing.shared_memory as sm
import time
import struct

SM_SIZE = 4096



def executor(read_pipe, write_pipe):
    # 创建共享内存
    sm_buf = sm.SharedMemory(create=True, size=SM_SIZE)
    print(f"[executor] create shared-memory name = {sm_buf.name}, size = {SM_SIZE}")

    # 创建ZMQ的PUB套接字，用于网络的发布通信
    context = zmq.Context()# zmq缓冲区
    pub = context.socket(zmq.PUB)
    pub.bind("tcp://127.0.0.1:15555")
    print("[executor] ZMQ PUB bind localhost:15555")

    # 连接信息，发送给子进程
    handle = {
        "sm_name": sm_buf.name,
        "zmq_pub_addr": "tcp://127.0.0.1:15555"
    }

    # 构造子进程，启动
    proc = multiprocessing.Process(target=worker, args=(write_pipe, handle))
    proc.start()


    # 等待子进程启动，注册好共享内存，SUB connect PUB 
    read_pipe.recv() # 等待子进程写入 ready

    time.sleep(0.2)
    print("[executor] 收到子进程ready消息")

    for i in range(3):
        msg = f"req #{i}".encode("utf-8") # 转16进制字符串
        data_len = len(msg)

        # 写入共享内存
        sm_buf.buf[0:4] = struct.pack(">I", data_len) # 定长
        sm_buf.buf[4:4+data_len] = msg
        print(f"[executor] 写入共享内存: {msg.decode()}")

        # 表示发送了两个帧（独立发送的字节块），所以用[]列表来表示
        # PUB/SUB 里第一帧自动被当成话题，用于路由匹配，后续帧是自由数据。
        # b"task" = "task".encode("utf-8"), 且只对纯ascll字符有效
        # "新任务来了".encode(), encode为空，默认转成utf-8
        '''
        unicode 是个 编号表，给世界上每个字符分配一个唯一数字，不涉及怎么存
        'A' → U+0041  (65)
        '你' → U+4F60  (20320)， 所以都是一个数字

        至于这个数字，被对应到什么16进制字节，那就是编码。
        有的编码 2 字节，有的 4 字节，有的变长。所以同一个字在不同平台可能有不同存储方式

        pyzmq 其实能接受字符串，内部会帮你用 UTF-8 编码。你把 .encode() 去掉也能跑。

        那为什么要自己写？两个原因：一是有几十种编码，万一某天你要对接一个 GBK 或 GB2312 的系统，不显式指定会全部乱码。
        二是代码清晰——看到 .encode() 就知道这里发生了编码转换，不用去猜 pyzmq 偷偷做了什么
        '''
        pub.send_multipart([b"task", "新任务来了".encode()]) # 发送两个帧，第一个默认被当成话题

        time.sleep(0.5)


    sm_buf.buf[0:4] = struct.pack(">I", 0)
    pub.send_multipart([b"stop","结束了".encode()]) # 发送结束了的话题
    print("[executor] 发送停止信号")

    proc.join(timeout=3)
    if proc.is_alive():
        proc.terminate()


    # 释放资源
    sm_buf.close()
    sm_buf.unlink()
    pub.close()
    context.term()





def worker(write_pipe, handle):

    # 注册好共享内存
    sm_buf = sm.SharedMemory(name=handle["sm_name"])
    print(f"[worker] 注册好 共享内存 name = {sm_buf.name}")

    # SUB 连接 PUB
    context = zmq.Context()
    sub = context.socket(zmq.SUB)
    sub.connect(handle["zmq_pub_addr"])
    sub.setsockopt_string(zmq.SUBSCRIBE, "task") # 订阅task话题
    sub.setsockopt_string(zmq.SUBSCRIBE, "stop") # 订阅stop话题
    print(f"[worker] ZMQ SUB 连接: {handle['zmq_pub_addr']}")

    write_pipe.send("ready")

    while True:
        topic, body = sub.recv_multipart() # 阻塞等待多帧数据，第一帧作为话题，剩下的是消息内容
        print(f"[worker] ZMQ 收到 topic = {topic.decode()}, body={body.decode()}")

        if topic == b"stop":
            print("[worker] 收到stop 停止")
            break

        '''
        [0]，因为struct.unpack返回的是元组
            struct.unpack(">I", b'\x00\x00\x00\x05')    # → (5,)     ← 元组！
            struct.unpack(">II", b'\x00\x00\x00\x01\x00\x00\x00\x02')  # → (1, 2)

        buf[0:4]是memoryview切片，
        写.tobytes()，是把共享内存里面的数据复制到本地bytes，确保unpack不会被并发干扰
        '''
        data_len = struct.unpack(">I", sm_buf.buf[0:4].tobytes())[0]
        msg = sm_buf.buf[4:4+data_len].tobytes().decode("utf-8") # 从utf-8解码成unicode
        print(f"[worker] 从共享内存读到任务: {msg}")

    sm_buf.close()
    sub.close()
    context.term()
    write_pipe.close()


if __name__ == "__main__":
    # 用spawn创建多进程，不继承资源
    multiprocessing.set_start_method("spawn", True)

    # 创建一个单向的内核缓冲区（管道）
    read_pipe, write_pipe = multiprocessing.Pipe(duplex=False)
    executor(read_pipe, write_pipe)
    #read_pipe.close() # 这个由子进程释放
    write_pipe.close()
```


最终输出为：
```bash
(vllm_study) liangji@liangjideMacBook-Air test5 % python my_zmq_sh.py
[executor] create shared-memory name = psm_a6f60e1b, size = 4096
[executor] ZMQ PUB bind localhost:15555
[worker] 注册好 共享内存 name = psm_a6f60e1b
[worker] ZMQ SUB 连接: tcp://127.0.0.1:15555
[executor] 收到子进程ready消息
[executor] 写入共享内存: req #0
[worker] ZMQ 收到 topic = task, body=新任务来了
[worker] 从共享内存读到任务: req #0
[executor] 写入共享内存: req #1
[worker] ZMQ 收到 topic = task, body=新任务来了
[worker] 从共享内存读到任务: req #1
[executor] 写入共享内存: req #2
[worker] ZMQ 收到 topic = task, body=新任务来了
[worker] 从共享内存读到任务: req #2
[executor] 发送停止信号
[worker] ZMQ 收到 topic = stop, body=结束了
[worker] 收到stop 停止
```



## future包装器

![](../images/Pasted%20image%2020260812210715.png)

vLLM 自己写的，继承的 `Future` 来自 Python 标准库：

```python
from concurrent.futures import Future  # Python 标准库

class FutureWrapper(Future):           # vLLM 自己扩展
```

标准库 `Future` 只管"设结果 + 等结果"。vLLM 加的那层是自定义的 FIFO 有序约束——`result()` 里 drain 队列清掉更老的 future 这一整段。就是自己实现的，不是用的现成库。


> 注意，这里的future机制的理解。这边再自己说一下：
> 
> future机制，是异步RPC，也就是异步远程过程调用的机制，他的作用在于把RPC的发送调用（右侧），得到调用结果（左侧）解耦
> 
> 这样executor 发出RPC 调用给worker,
>  无需等待，直到executor调用future.result()才开始阻塞获取这个RPC的结果。
>  vllm 的 futurewrapper， 在future的基础上 ， `result()` 的阻塞 + FIFO drain 来保证顺序。
>  ![](../images/Pasted%20image%2020260812211546.png)
>  
>  <mark style="background:#fff88f">就是如果我按照 1,2,3的RPC顺序挂出去，然后读取3的结果，就必须要获得1，2的结果，保证了RPC的输出一定是按照RPC发出的顺序</mark>





## python 随机种子

计算机里的「随机数」不是真随机，而是**伪随机**——从一个初始数字出发，用确定性的算法吐出一串看起来随机的序列。这个初始数字就叫 **seed（种子）**。

关键性质：**同一个 seed → 吐出来的随机序列完全一样**。所以 seed 是「可复现」的开关。

`set_random_seed` 是「给所有随机数生成器统一设定起点」的工具函数

因为 vLLM 的代码里会用到好几套随机数来源（Python 的 `random`、numpy、torch、以及 GPU 上的 CUDA 随机），所以要把它们**全部**设成同一个 seed，才能保证「整条推理链是确定性的」


## python 的GC
`gc` 是 Python 标准库的 **garbage collector（垃圾回收）模块**，`gc.collect()` 就是「手动强制立刻跑一次垃圾回收」。

**Python 的内存管理有两套机制**

Python 回收内存不是靠一个统一机制，而是两层：

| 机制                 | 管什么                         | 什么时候触发                  |
| ------------------ | --------------------------- | ----------------------- |
| **引用计数**           | 普通对象，引用数归 0 立即释放            | 自动、即时                   |
| **循环 GC（`gc` 模块）** | **循环引用**的对象（A 指向 B、B 又指向 A） | 周期触发，或手动 `gc.collect()` |
|                    |                             |                         |

关键点：**循环引用**这种对象，因为互相引用、引用计数永远不为 0，靠引用计数根本释放不掉。所以 Python 另外搞了一个「三色标记」的循环检测器，就是 `gc` 模块干的事。

`gc.collect()` = **别等它周期触发了，现在就立刻扫一遍，把所有循环引用的垃圾清掉**。


## NUMA
NUMA(Non-Uniform Memory Access)，即非一致性内存访问，是一种关于多个CPU如何访问内存的架构模型

![572](../images/Pasted%20image%2020260814102436.png)



![](../images/Pasted%20image%2020260814102506.png)


![](../images/Pasted%20image%2020260814102601.png)

### 参数变量

先建立一个核心概念：

- `args`：普通位置参数
	- def add(a, b): 函数，然后调用add(1,2), 这里a=1, b=2就是位置参数
- `kwargs`：关键字参数
	- 调用 add(a = 1, b = 2), 这里的a=1， b=2 就是关键字参数
- `*args`：把多个位置参数打包成 tuple
	- def func(`*args`)
	- func(1,2,3,4), 这个时候`*args` 就是 1，2，3，4 这4个数
	- `*`表示解包，那么args就是打包后的变量，所以args = (1,2,3,4), 所以args[0] = 1
	- 这个的好处是，不需要知道参数的个数，也不用指定名字
	- `*args` 收集的是**没有通过关键字形式传递的位置参数（positional arguments）**
- `**kwargs`：把多个关键字参数打包成 dict
	- def func (`**kwargs`)
	- func(name="qwen", size="7B")
	- 所以kwargs={"name":"qwen", "size": "7B"} 就是字典，所以，kwargs["dtype"] = fp16, 可以直接拿关键字
- `*` 和 `**` 在调用时表示解包



















## hugging face模型中各文件
```bash
(base) liangji@ubun:~/huggingface/Qwen2.5-7B-Instruct-1M$ tree
.
├── config.json
├── generation_config.json
├── LICENSE
├── merges.txt
├── model-00001-of-00004.safetensors
├── model-00002-of-00004.safetensors
├── model-00003-of-00004.safetensors
├── model-00004-of-00004.safetensors
├── model.safetensors.index.json
├── model_structure.txt
├── README.md
├── sparse_attention_config.json
├── tokenizer_config.json
├── tokenizer.json
└── vocab.json
```
### 模型权重
```bash
├── model-00001-of-00004.safetensors
├── model-00002-of-00004.safetensors
├── model-00003-of-00004.safetensors
├── model-00004-of-00004.safetensors
```
模型权重的分片文件，safetensors是一种安全，快速的张量存储格式，是目前HuggingFace推荐的格式，比传统的pytorch的.bin格式更加安全。

```bash
├── model.safetensors.index.json
```
这个是索引文件/地图，当模型权重被分片时，这个文件会告诉HuggingFace的transformers库，每个具体的权重存储在哪一个.safetensors分片文件中。


### 模型配置
```bash
├── config.json
```
这个定义了模型的架构，包含了模型的各种超参数。
- 模型类型：architectures， eg: LlamaForCausalLM
- 隐藏层大小: hidden_size
- 注意力头的数量：num_attention_heads
- 网络层数：num_hidden_layers
- 词表大小：vocab_size

当我们使用`AutoModel.from_pretrained(...)`, 库首先会读取这个config.json, 了解是什么模型结构，然后再去加载权重 。

![465](../images/Pasted%20image%2020260816153505.png)

![603](../images/Pasted%20image%2020260816153520.png)

![476](../images/Pasted%20image%2020260816153533.png)







```bash
configuration.json
```
这个是config.json的旧版，一样的


### 分词器文件
分词器是负责 把 文字 - token id的 双向转换

```bash
tokenizer.json
```
这个是由 HuggingFace 的 tokenizers 库生成的一体化文件，包含了分词器所需的全部信息
- 词表
- 合并规则
- 特殊tokens

```bash
tokenizer_config.json
```
这个文件配置了分词器类的行为，定义了如何使用其他文件，以及一些特殊token的名称，比如
- bos_token （句子开头）
- eos_token( (句子结尾)
- unk_token (未知词)

```bash
vocab.json
```
词汇表文件，就是个json字典，将每个token 映射到唯一的 token id

```bash
merges.txt
```
这个是BPE分词算法的合并规则文件，按照优先级顺序列出了如何将子词合并成更大的token
e r-> er


**文件关系：**

`AutoTokenizer.from_pretrained(...) `会智能地加载这些文件。如果存在 `tokenizer.json`，它会优先使用这个文件，<mark style="background:#fff88f">因为它最快最全</mark>。如果不存在，它会根据 tokenizer_config.json 的指示，组合 vocab.json 和 merges.txt 等文件来构建分词器


### 生成与聊天配置文件
```bash
generation_config.json
```
这个文件为模型的文本生成过程提供了默认参数。当你调用 .generate() 方法时，如果没有指定参数，就会使用这里的配置。常见的参数包括：
- max_length：<mark style="background:#fff88f">生成文本的最大长度</mark>。
- temperature, top_p, top_k：<mark style="background:#fff88f">控制生成文本多样性和创造性的参数</mark>。
- do_sample：<mark style="background:#fff88f">是否使用采样策略</mark>。


```bash
chat_template.json
```
对于聊天模型（Chat Model）来说，这是一个非常重要的文件。它定义了如何将多轮对话（包含系统提示、用户输入、模型回复）格式化为模型能够理解的单个字符串。这通常是一个Jinja2模板，确保了角色和特殊token（如 [INST], </s>）被正确地放置。如果格式不对，聊天模型的效果会大打折扣




### 其他文件
```
README.md
```
作用：这是一个Markdown格式的说明文件，也就是“模型卡片”（Model Card）。它详细介绍了模型的信息，包括：模型描述、用途、限制、如何使用、训练数据、评测结果等。这是用户了解和使用模型的首要入口。



```
.gitattributes
```
作用：这是一个Git的配置文件。它通常与 git-lfs (Large File Storage) 一起使用，告诉Git如何处理大文件。对于像 .safetensors 这样的GB级大文件，这个文件会指示Git只跟踪文件的指针，而不是文件的完整内容，从而让仓库保持轻量。



```
preprocessor_config.json
```
作用：预处理器配置文件。对于纯文本的语言模型，这个文件可能比较简单或不存在。但在多模态模型（如处理图像或音频）中，它会定义数据预处理的步骤，例如图像缩放尺寸、归一化参数等。




## HuggingFace的库
Hugging Face 本身就是一个开源 AI 生态组织/平台，最核心的是提供了一整套模型与推理训练库


![579](../images/Pasted%20image%2020260816153734.png)

![433](../images/Pasted%20image%2020260816153805.png)


![](../images/Pasted%20image%2020260816153821.png)

![334](../images/Pasted%20image%2020260816154110.png)
![](../images/Pasted%20image%2020260816154129.png)


![599](../images/Pasted%20image%2020260816154248.png)



## pytorch的nn.Module, nn.Parameters

- nn.Module
	- 是神经网络模块的基类
	- 它本身不是张量，而是一个「容器/管理器」：负责组织参数、子模块、buffer，管理 `forward`、device、dtype、训练/推理状态、hook 等。你自定义的层都要继承它，才能被 `named_children()`、`state_dict()`、`.to(device)` 这些机制识别
- nn.Parameter
	- 这个是torch.Tensor的子类
	- 它唯一做的事，就是给张量打个「我是参数」的标记。被标记后，`nn.Module` 会特殊对待它



## torch.Tensor.numel()
返回张量里所有元素的个数





# vllm （AsyncLLM前端 + EngineCore后端）
## 0_架构设计
简单来说，我们的这个vllm，分成3个部分
- <mark style="background:#fff88f">api server</mark>
	- <mark style="background:#fff88f">引擎前端（AsyncLLM）</mark>
	- <mark style="background:#fff88f">引擎后端（EngineCore）</mark>

**api server** ，就是uvicorn + fastapi, 负责作为服务，来响应用户的需求。
**引擎前端**，用来接受用户的响应，分词，然后发送给对应的引擎后端
**引擎后端**，用来真正干活，推理

三者各司其职，从而构建真正的<mark style="background:#fff88f">在线推理服务</mark>。
- **在线**：引擎前端
	- 实时处理不同的输入，不是固定的离线输入
- **推理**：引擎后端
	- 推理
- **服务**：api server
	- 包装在线前后端引擎，让用户真正能使用，作为一个http服务器





## 1_vllm 的 api server的启动
从vllm这个整体项目的启动，到api server的服务启动，到引擎前后端的启动过程梳理。

这一节将从整个vllm的项目运行vllm -> vllm serve -> 启动引擎 -> fastapi+uvicorn启动服务器来分析api server的启动。

### api server架构

下面先看一下整体的一个启动步骤

```txt
① main.py:17  main()
    │
    ├─ 23:   import serve模块
    ├─ 27-34: CMD_MODULES 列表（含 serve 模块）
    ├─ 70-80: 创建 argparser + subparsers
    │
    ├─ 82-86: for每个模块 → 调 cmd_init() → 遍历返回的Cmd对象
    │            cmd.subparser_init(subparsers)    注册argparse子命令
    │            set_defaults(dispatch_function=cmd.cmd)   ← 关键: 绑定执行函数
    │
    ├─ 87:   parser.parse_args()  解析命令行
    │        用户敲 "vllm serve" → args.subparser="serve", dispatch_function=ServeSubcommand.cmd
    │
    └─ 92:   args.dispatch_function(args)  ← 直接调绑定的函数
                  │
                  ▼
② serve.py:43  ServeSubcommand.cmd(args)    ← 静态方法，真正的业务入口
    │
    ├─ 54-62:  处理 --headless 分支
    ├─ 64-104: 处理 DP / LB / elastic EP 参数（优化相关，跳过）
    │
    ├─ 115-116: api_server_count < 1 → run_headless(args)
    ├─ 117-118: api_server_count > 1 → run_multi_api_server(args)
    │
    └─ 119-122: 默认（单 API server）→ uvloop.run(run_server(args))
                      │
                      ▼
③ openai/api_server.py:686  async def run_server(args)
    └─ 696: run_server_worker()
         ├─ 707: build_async_engine_client() → AsyncLLM.from_vllm_config()  ← 前端+引擎
         └─ 711: build_and_serve() → serve_http() → uvicorn 监听           ← HTTP

```


### 源码分析


下面来逐步分析api server的启动源码


#### pyproject.toml

首先是vllm/下面的我们的整个vllm项目的一个项目构建文件，类似CMakeLists.txt
`pyproject.toml`

![](../images/Pasted%20image%2020260807100105.png)


可以看到，我们这里指定我们的项目叫vllm, 项目入口是`vllm/entrypoints/cli/main.py`的main()函数。

---

#### vllm源码目录结构
这里先大致预览一下**vllm里面每个目录的相关内容**是什么

| 路径                     | 作用                                           |
| ---------------------- | -------------------------------------------- |
| **entrypoints/**       | 各种"入口"：CLI、OpenAI API、离线推理、MCP服务             |
| **v1/**                | **V1 引擎（主力引擎）**：调度器、执行器、采样、KV cache          |
| **engine/**            | 旧的 V0 引擎接口（兼容层，正在被 V1 替代）                    |
| **model_executor/**    | 模型实现：各架构的前向计算（GPU 侧，超大）                      |
| **config/**            | 配置体系：VllmConfig / EngineArgs 等 dataclass 定义  |
| **distributed/**       | 分布式通信：TP/PP/DP 的 NCCL、进程组管理                  |
| **compilation/**       | torch.compile / dynamo / inductor 相关代码       |
| **outputs.py**         | RequestOutput 等返回给用户的数据类型                    |
| **plugins/**           | 插件机制：entry point 加载                          |
| **inputs/**            | EngineInput 等输入数据类型                          |
| **multimodal/**        | 多模态处理：图片/视频/音频预处理                            |
| **lora/**              | LoRA 适配器管理                                   |
| **tokenizers/**        | tokenizer 加载与封装                              |
| **utils/**             | 通用工具函数                                       |
| **platforms/**         | 硬件平台抽象（CUDA/ROCm/CPU/TPU）                    |
| **kernels/**           | 手写 CUDA kernel 和 PyTorch 自定义算子               |
| **usage/**             | 使用量统计（遥测上报）                                  |
| **logger.py**          | 日志初始化                                        |
| **version.py**         | 版本号                                          |
| **envs.py**            | 所有环境变量常量定义                                   |
| **sampling_params.py** | SamplingParams / PoolingParams 类定义（用户传的采样配置） |

----

#### main.py


下面我们看到main()里面，就是我们执行vllm指令运行的地方，先是注册了一些子命令模块
![541](../images/Pasted%20image%2020260807100845.png)

把工厂函数获取到的各个子命令对象实例，注册到cmds里面，

![](../images/Pasted%20image%2020260807100949.png)

![327](../images/Pasted%20image%2020260807101040.png)


所以我们执行vllm serve，实际上是PC指针运行到`vllm/entrypoints/cli/serve.py`里面

![608](../images/Pasted%20image%2020260807101209.png)


这里的dispatch_function就是在执行具体的各个子命令类对象的绑定的执行函数，也就是子命令类里面的一个静态方法：
![519](../images/Pasted%20image%2020260807101345.png)


---

#### serve.py

下面来分析serve.py具体做了什么，当我们执行了vllm serve后，PC指针跳转到cmd()来执行


有效代码如下：可以看到，主要干了以下几件事情：
- 获取模型地址
- 确认api server的启动数量
- 启动api server
	- -> 我们默认单api server, `run_server()`
![](../images/Pasted%20image%2020260807101925.png)
![](../images/Pasted%20image%2020260807101948.png)

这里的uvloop.run 就是 高性能版本的 asyncio.run, 开启一个协程任务，之后，我们的这个进程的PC指针到这里就结束了


![](../images/Pasted%20image%2020260807102410.png)



![](../images/Pasted%20image%2020260807102447.png)

而我们的run_server则是在`vllm/entrypoints/openai/api_server.py`里面定义，因为我们要启动的是openai接口的api server

---

#### api_server.py
![](../images/Pasted%20image%2020260807102609.png)

这就是我们的第一个协程任务，开始启动api server

我们先申请好api server的地址，端口号，socket，防止被占用。

![](../images/Pasted%20image%2020260807102843.png)

- valid_api_server_args 检查args命令行参数的合法性
- 占用host地址 + 端口号
- 创建好socket套接字
- 定义好退出信号和回调
- 返回 服务器地址，端口号，socket套接字

之后就是`run_server_worker`， 来阻塞等待启动服务器

---

启动服务器 api server (uvicorn)
![](../images/Pasted%20image%2020260807103232.png)

可以看到，这个第二个串行的协程任务里面，又异步协程任务：
- build_async_engine_client
	- 阻塞在build_and_serve

之后我们的第二个协程任务就阻塞在等待shutdown_task的信号（等待服务结束）

因此PC指针主要开始在
- build_async_engine_client
- build_and_serve

---
##### 构造引擎 build_async_engine_client

下面来看一下build_async_engine_client， 是如何来构造我们的引擎前端的。传入参数是命令行的参数 + 客户端的配置， 返回的是我们构造出来的引擎前端engine_client


![](../images/Pasted%20image%2020260807103829.png)

- AsyncEngineArgs.from_cli_args获取我们的引擎参数
- 如果配置了引擎前端的配置
	- 引擎前端进程 总数
	- 当前index

> 这里要说明的是，引擎前端的数量，和我们的api server的服务进程是绑定的，也就是一个api server的服务进程，产生一个引擎前端。
> 
> 这样的好处是，我们就可以实现
> ![](../images/Pasted%20image%2020260805230426.png)
> 一个端口好，服务器有4个服务进程来处理输入，并行化程度增高，所以这里的client_config， 只是在告诉本进程的这个协程任务，你这个进程是第几个服务进程，以及总共多少个协程进程


之后，就是启动一个新的协程这来真正创建引擎前端，并抛出

至于这里为什么是yield engine, 而不是return engine, 原因在于我们创建出来的engine-client的实例，需要一个自动回收释放的逻辑。

看一下build_async_engine_client_from_engine_args的逻辑

![](../images/Pasted%20image%2020260807104835.png)


- vllm_config 是根据配置创造出来的配置实例
- 开始调用我们的vllm/v1/engine/async_llm.py的AsyncLLM的类方法

注意这里用try-finally来构造好一个AsyncLLM的引擎前端实例，然后用yield抛出。这样的好处是暂停这个build_async_engine_client_from_engine_args的后续逻辑，因此，针对这个async_llm的实例对象，协程的finally的自动回收机制，还是可以保留，后续被async with的回收engine_client触发的finally的回收机制

![](../images/Pasted%20image%2020260807105335.png)

```txt
build_and_serve:
  async with build_async_engine_client(args) as engine_client:    ← 入口
    │
    ├─► build_async_engine_client:
    │     async with build_async_engine_client_from_engine_args(...) as engine:
    │       │
    │       ├─► build_async_engine_client_from_engine_args:
    │       │     async_llm = AsyncLLM.from_vllm_config(...)
    │       │     yield async_llm                    ← 暂停点②
    │       │
    │       ├─ 拿到 engine
    │       │   yield engine                         ← 暂停点①
    │       │
    ├─ 拿到 engine_client
    │   ... build_app ... serve_http ...              ← 跑很久
    │   ... 收到 SIGTERM ... serve_http 返回 ...
    │
    │ ← async with 块结束 ─────────────────────────── 退出！
    │       │
    │       ├─ 回到暂停点① 下面（build_async_engine_client）
    │       │   async with 块退出
    │       │     │
    │       │     └─► 回到暂停点② 下面（build_async_engine_client_from_engine_args）
    │       │           finally: async_llm.shutdown()  ← 回收！

```


关键：`serve_http` 一返回，`build_and_serve` 里最外层的 `async with` 块就退出了。退出时 Python 自动逐层"解开"暂停的协程——先唤醒 `build_async_engine_client`（它的 `yield` 下面没有 finally，直接过），它的 `async with` 退出触发内层 `build_async_engine_client_from_engine_args` 的 `finally`，执行 `shutdown()`。

就是你之前学的 `ctrl+c → shutdown_task → serve_http 结束 → async with 逐层退出 → finally 回收 → done`。


###### python的上下文管理器
所以这也算是一个标准的**python上下文管理器**
![](../images/Pasted%20image%2020260807110035.png)


![](../images/Pasted%20image%2020260807110218.png)




##### 构造/启动服务器 build_and_serve

既然上面利用上下文管理器，来创建了我们这个api server进程的engine_client, 也就是async_llm的对象实例，下面就可以开始根据这个对象实例，开始构建我们的这个api  server进程，开始真正干活了

输入:引擎前端实例，主机地址，socket套接字
输出:一个asyncio的task

![](../images/Pasted%20image%2020260807145319.png)


- 阻塞查询引擎前端实例支持的任务类型，是纯文本还是多模态
- 获取模型的配置参数
- 创建app
	- 这里只是创建了lifespan的构造析构逻辑，没有指定真正的引擎前端
- 阻塞init_app_state， 开始把app和engine_client绑定在一起，注册到app.state里面。
- serve_http， 开始启动api server


##### build_app & lifespan
这里来介绍一下，他是如何构建fastapi 的 app的

![](../images/Pasted%20image%2020260807145641.png)

![510](../images/Pasted%20image%2020260807145742.png)
这里可以看到：
- app = FastAPI(......, lifespan = lifespan)

指定的lifespan的逻辑被写到了 vllm/entrypoints/openai/server_utils的lifespan方法里面

![](../images/Pasted%20image%2020260807145836.png)

可以看到，正常来说，我们api server启动app，增加lifespan是用来增加构造析构服务的。但是注意，我们增加的构造准备，析构回收逻辑，是针对服务本身的，**所以这里的lifespan是增加了一个后台的定时清理任务**。而我们的真正服务器的核心逻辑，在引擎engine_client(async_llm)被构造的时候，init()的时候，就已经构造启动好了。

简单看一下这里的lifespan的逻辑

> @asynccontextmanager 异步上下文管理器
> 这是一个装饰器，修饰下面的方法，可以把yield生成器变成上下文的隔断符，这样就相当于上面是服务的构造逻辑，下半段是服务的析构逻辑
> ![](../images/Pasted%20image%2020260807150331.png)
> 因此当我们启动app的时候，就会自动创建一个后台任务，结束这个app服务的时候，就可以销毁这个后台任务。


> 另外这里还有一个 freeze_gc_heap()的方法。
> 这个的作用是，冻结GC的堆，也就是GC只扫描服务开启后，请求处理的创建的新的对象，避免启动期间的对象被重复扫描回收。


---

既然我们已经准备好了app服务的启动和回收。

那么接下来肯定要丰富app服务的各种接口功能，这样才能实现一个服务器

![](../images/Pasted%20image%2020260807150736.png)


我们主要是这一条，router其实就是路由，也就是fastapi的那个接口的地址，比如/items/什么的。这样就知道发过来的请求是哪个接口来处理。
![](../images/Pasted%20image%2020260807150800.png)


这里就是给我们的app 服务，注册一个generate的任务类型，具体定义在
`vllm/entrypoints/openai/generate/api_router.py -> register_generate_api_routers()`


下面看一下具体的注册内容
![](../images/Pasted%20image%2020260807151055.png)



"generate" 是**任务类型**的名称，不是接口路径。意思就是"这个模型能生成文本"。

对应到具体接口，全部走 OpenAI 标准命名：

|接口路径|用途|
|---|---|
|`POST /v1/chat/completions`|**主力** — ChatGPT 风格对话|
|`POST /v1/completions`|老式文本补全（续写）|
|`POST /v1/responses`|OpenAI 新协议（Responses API）|
|`POST /v1/messages`|Anthropic Claude 兼容格式|

再加之前注册的：

|接口路径|用途|
|---|---|
|`GET /v1/models`|列出模型|
|`GET /health`|健康检查|
|`POST /v1/tokenize`|分词|
|`POST /v1/embeddings`|向量嵌入（embedding 模型才有）|

核心就是 `/v1/chat/completions`，绝大部分用户用这一个就够了。

---


现在来分析这个 /v1/chat/completions这个router

![](../images/Pasted%20image%2020260807151643.png)


这个 router 里就**两个**接口：

```python
@router.post("/v1/chat/completions")           # 单条对话
@router.post("/v1/chat/completions/batch")     # 批量对话
```

`app.include_router(router)` 会把 router 里定义的全部路由一次性挂到 app 上。和你学习时的写法等价于：

```python
@app.post("/v1/chat/completions")
async def create_chat_completion(...): ...

@app.post("/v1/chat/completions/batch")
async def create_batch_chat_completion(...): ...
```

只是用 `APIRouter` 把相关接口封装在一个独立的模块里，每个模块只注册少量路由。不是单文件写几十个 `@app.get/post`。


![](../images/Pasted%20image%2020260807151906.png)


![](../images/Pasted%20image%2020260807152142.png)



下面罗列一下build_app里面注册的所有模块和各自的接口
```txt
build_app
│
├── ① 基础设施（无条件注册）
│   ├── register_vllm_serve_api_routers    → vLLM 专属
│   │   ├── lora/          LoRA 管理
│   │   ├── tokenize/      分词
│   │   ├── profile/       性能分析
│   │   ├── cache/         KV 缓存管理
│   │   ├── sleep/         休眠/唤醒
│   │   └── rpc/           内部 RPC
│   ├── register_models_api_router         → GET /v1/models
│   └── register_sagemaker_api_router      → SageMaker 兼容接口
│
├── ② generate 能力 → 有 generate 才注册
│   ├── register_generate_api_routers      → 核心文本生成
│   │   ├── chat/           POST /v1/chat/completions
│   │   ├── completion/     POST /v1/completions
│   │   ├── responses/      POST /v1/responses
│   │   └── anthropic/      POST /v1/messages
│   ├── attach_disagg_router               → 分离式推理
│   ├── attach_rlhf_router                 → RLHF
│   ├── elastic_ep_attach_router           → MoE 弹性调度
│   └── register_generative_scoring_router → 评分模型
│
├── ③ 条件注册（按 supported_tasks）
│   ├── render/          generate 或 render 任务
│   ├── speech_to_text/    transcription 任务
│   ├── realtime/          realtime 任务
│   └── pooling/           embedding/classify/等 pooling 任务
│
├── ④ 中间件 + 异常处理
│   ├── CORS 中间件
│   ├── API Key 认证
│   ├── 异常处理器 (HTTP/Validation/Engine/Generation/Generic)
│   └── Scaling 中间件

```


###### app接口逻辑： /v1/chat/completions

这个chat completions， 就是**聊天完成**功能，有：
- 非流式
- 流式
两种输出模式


下面看一下这个/v1/chat/completions的接口的内容
![](../images/Pasted%20image%2020260807152543.png)
在路由里面，定义好了，这是一个POST提交的指令，触发的任务是create_chat_completion

---

handler 从chat()方法中获取一个app.state的属性，里面存储了一个OpenAIServingChat实例对象

> 这个属性是在build_app后面的init_app_state里面放进去的，但是chat的接口逻辑（使用到这个属性实例）先被注册进去

`chat()` 就是一个**从 app.state 取东西的快捷函数**：

```python
# 路由里定义的上方
def chat(request: Request) -> OpenAIServingChat | None:
    return request.app.state.openai_serving_chat   # 就是取个属性

# 使用
handler = chat(raw_request)
# handler = app.state.openai_serving_chat
#        = OpenAIServingChat 实例（在 init_generate_state 时创建好的）
```

`handler` 就是 `OpenAIServingChat` 实例——之前 `init_generate_state` 里用 `engine_client` + 各种配置构造出来的服务对象。它持有 `engine_client` 引用，对外提供 `create_chat_completion()` 方法。

如果模型不支持 generate 任务，`state.openai_serving_chat` 就是 `None` → `handler is None` → 接口返回 `501 Not Implemented`。


---



这个接口**同时支持流式和非流式**，靠请求体里的 `stream` 参数区分

```python
generator = await handler.create_chat_completion(request, raw_request)
# generator 可能是三种东西：

if isinstance(generator, ErrorResponse):
    return JSONResponse(...)                              # ❌ 出错

elif isinstance(generator, ChatCompletionResponse):
    return JSONResponse(content=generator.model_dump())   # 📦 非流式：一次性返回完整 JSON

return StreamingResponse(content=generator, ...)          # 🌊 流式：返回 SSE 逐 token
```

客户端控制：

```bash
# 非流式（默认）→ 等全部生成完，一次性拿到完整回复
curl ... -d '{"messages":[...], "stream": false}'

# 流式 → 逐 token 推送，和你的 SSE 学习代码一样
curl ... -d '{"messages":[...], "stream": true}'
```

所以 `chat/completions` 不是"流式输出模式"，而是"聊天补全协议"——`stream` 参数只是里面一个开关，决定返回方式。底层调用同一个 `engine_client` 推理。



所以下面就需要去具体分析handler， 也就是`request.app.state.openai_serving_chat`
这个**OpenAIServingChat实例**，是这个实例对象，来具体操作调用我们的engine_client引擎前端提交请求的。



---


注册完这些接口后，返回这个app


---

###### **中间层**：接口handler， init_app_state
<mark style="background:#fff88f">这个handler，来自OpenAIServingChat这个实例，并提供create_chat_completion的方法，来生成异步迭代器，用来流式输出。</mark>


下面先来分析一下init_app_state, 看看是如何把这个OpenAIServingChat和app绑定的（**这个就是把engine_client引擎前端和app绑定。这样接口就可以通过app的属性找到这个实例来操作引擎**）


![](../images/Pasted%20image%2020260807155248.png)


- 通过engine_client获取vllm_config
- 各种校验
- app.state属性写入：
	- ![](../images/Pasted%20image%2020260807155403.png)
	- ![457](../images/Pasted%20image%2020260807155532.png)

- 注册generate任务的相关属性实例
	- ![](../images/Pasted%20image%2020260807155607.png)
	- ![](../images/Pasted%20image%2020260807155637.png)
		- ![](../images/Pasted%20image%2020260807155854.png)
		- ![](../images/Pasted%20image%2020260807160014.png)


可以看到，在api server的这个接口 和 engine_client的引擎前端之间，我们肯定是针对这个引擎有不用的用法的，具体的用法，就是<mark style="background:#fff88f">一个中间的类对象</mark>。

这个类对象就是**OpenAIServingChat**， 来实现这个chat的功能。由**他来实现接口的具体逻辑，驱动引擎前端**。

就是中间层，做三件事：

```
HTTP 请求（用户消息、参数）
        │
        ▼
┌─────────────────────────┐
│   OpenAIServingChat      │  ← 中间层
│                          │
│  1. 协议解析              │  messages → token_ids + sampling_params
│  2. 调用引擎              │  engine_client.generate(...)
│  3. 协议转换              │  RequestOutput → OpenAI JSON/SSE
│                          │
└────────────┬────────────┘
             │
             ▼
       engine_client.generate()    ← 引擎前端
```

路由层只管 HTTP 的事（读请求、发响应），不知道 token 怎么打、采样参数怎么设。引擎层只管推理，不知道 OpenAI 协议长什么样。`OpenAIServingChat` 夹在中间把两边翻译对了。这就是你之前在 `init_generate_state` 看到构造它时为什么要传那么多参数——它需要所有信息来完成这两端转换。


<mark style="background:#fff88f">所以这里本质上就是驱动层，中间件层（runtime层）的那种经典操作系统的设计架构</mark>

![](../images/Pasted%20image%2020260807160320.png)

---

下面先来看一下这个中间适配器类的init参数
**`__init__` 参数分三类：**

| 类别    | 参数                      | 作用                       |
| ----- | ----------------------- | ------------------------ |
| 核心依赖  | `engine_client`         | 引擎驱动（必须）                 |
|       | `models`                | 模型注册信息                   |
|       | `openai_serving_render` | 模板渲染器（messages → prompt） |
| 对话配置  | `chat_template`         | Jinja 对话模板               |
|       | `response_role`         | 回复角色名（"assistant"）       |
| 功能开关  | `tool_parser`           | 工具调用解析                   |
|       | `reasoning_parser`      | 推理过程解析                   |
|       | `enable_auto_tools`     | 自动工具调用                   |
| 调试/日志 | `request_logger`        | 请求日志                     |
|       | `enable_log_outputs`    | 输出日志                     |

---
下面是我们的产生SSE流式输出的异步迭代器的方法create_chat_completion

![](../images/Pasted%20image%2020260807161326.png)


**`_with_kv_transfer_rejection_cleanup`** 是优化相关：当使用远程 KV 缓存预取时，如果请求在到达引擎前就被拒绝（比如校验不通过），需要通知远端"这块缓存不用了，可以释放"。就是一个兜底清理—请求失败了别让远端一直锁着那块显存。你自己实现可以完全不用关心。


<mark style="background:#fff88f">关于传入的request， 和 raw_request这两个参数：</mark>
![](../images/Pasted%20image%2020260807161538.png)

###### 对话模版格式转换
下面看一下这边的格式换行
`/v1/chat/completions` 和 `/v1/completions` 的请求体不一样：

```json
// /v1/chat/completions — 带 role 的多轮对话
{
  "messages": [
    {"role": "system", "content": "你是一个助手"},
    {"role": "user", "content": "你好"},
    {"role": "assistant", "content": "你好！有什么可以帮你？"},
    {"role": "user", "content": "今天天气怎么样"}
  ]
}
```

```json
// /v1/completions — 纯文本续写，没有 role
{
  "prompt": "今天天气真不错，",
  "max_tokens": 50
}
```

`render_chat_request` 就是把带 role 的 messages → 拼成模型认识的格式 → tokenize → `token_ids`。比如 Qwen 模型会拼成：

```
<|im_start|>system
你是一个助手<|im_end|>
<|im_start|>user
今天天气怎么样<|im_end|>
<|im_start|>assistant
```

这一步就是对话模板渲染，把 role+content 结构转成模型训练时见过的文本格式，然后再 tokenize。

---


下面继续分析 这个适配器的create_chat_completion的迭代结果方法

<mark style="background:#fff88f">实际上是调用的_create_chat_completion方法</mark>

![](../images/Pasted%20image%2020260807193902.png)

![](../images/Pasted%20image%2020260807193920.png)


![420](../images/Pasted%20image%2020260807163934.png)

可以看到，这个方法的逻辑是：
- 获取分词器
- request 转换模版
- 构建输出用的结构化解析器
- prompt转成token ids
- 设置请求ID
- 开始获取本请求的prompt
	- 计算长度
	- 计算生成长度
	- 设置采样器参数
	- 调用子类的generate来产生迭代器
	- ![](../images/Pasted%20image%2020260807205111.png)
	- 收集我们这个子请求的迭代器，然后添加到我们这个大的请求的迭代器里面。
	- 大多数时候一个请求就是一个子请求，也就是list.size = 1
	- ![274](../images/Pasted%20image%2020260807205324.png)
- ![381](../images/Pasted%20image%2020260807210237.png)
- 这个夹在**迭代器返回 - api_router的create_chat_completion之间**，把迭代出来的**RequestOutput转成str**
- 之后api_router的await返回的就是str的迭代器，进入StreamingResponse来async for实现真正的流式输出

<mark style="background:#d3f8b6">总结：</mark>
![](../images/Pasted%20image%2020260807210533.png)


至此，我们的/v1/chat/completions的接口任务已经分析完成了

---

init_app_state，也就是适配器层的对象都创建然后绑定到app了，接下来就是启动我们这个api server。


![](../images/Pasted%20image%2020260807211142.png)

至此，我们这个在线服务api server的进程就完成了，一直会await等待shutdown_task，否则服务就会一直启动中。







































![](../images/Pasted%20image%2020260805232226.png)
![](../images/Pasted%20image%2020260805232410.png)
![](../images/Pasted%20image%2020260805233339.png)

![](../images/Pasted%20image%2020260805233645.png)

![](../images/Pasted%20image%2020260805234002.png)






### commit
![](../images/Pasted%20image%2020260805235359.png)



## 2_引擎启动
这里主要分析引擎前端是如何在init的时候，启动引擎后端的，以及他们的进、线程的关系。


也就是engine_client这个变量的创建过程



![](../images/Pasted%20image%2020260807211433.png)

![](../images/Pasted%20image%2020260807211407.png)
![](../images/Pasted%20image%2020260807211622.png)

![](../images/Pasted%20image%2020260807211506.png)


总结一下这个过程
- build_async_engine_client -> engine_client
	- build_async_engine_client_from_engine_args 构造出async_llm的子类对象实例 yield + 上下文管理器抛出
- build_and_serve
	- init_app_state
		- state.engine_client = engine_client 把这个async_llm的子类对象实例，绑定到app上面


这就是引擎前端的调用过程。

---
下面来具体分析async_llm这个引擎前端子类实例对象的构造过程，看看一个引擎前端进程是如何创建多个引擎后端进程的









先来简单看一下引擎后端启动的调用逻辑：

**完整启动链**

```
AsyncLLM.__init__()
  │  EngineCoreClient.make_async_mp_client() # 创建引擎传输层 + 引擎后端
  ▼
AsyncMPClient.__init__() → super().__init__() → MPClient.__init__()
  │  launch_core_engines()
  ▼
CoreEngineProcManager.__init__()
  │  multiprocessing.Process(target=EngineCoreProc.run_engine_core)
  ▼
新进程: EngineCoreProc                                   ← 真正的 GPU 推理进程
  │  加载模型权重 → 创建 Scheduler → 创建 Executor → 死循环取请求做推理
```

IPC 管道就是之前看的 ZMQ socket：两个进程之间通过 ZMQ ROUTER/DEALER 收发 `EngineCoreRequest` 和 `EngineCoreOutputs`。

**这才是完整的 `self.engine_core`——不仅是一个 ZMQ 客户端，它同时还 fork 了一个跑模型的子进程。**


---




先来展示一下，v1/engine/相关的主要用到的文件

![](../images/Pasted%20image%2020260808184446.png)


---
#### 代码梳理

下面将根据引擎前端进程的引擎前端对象，根据这个目录的文件，来逐步trace代码，看看是如何启动引擎后端，然后连接好，逐步工作的

<mark style="background:#d3f8b6">async_llm.py</mark>

前面一节，我们说到，在app的build_async_engine_client那个函数里面，构造了一个AsyncLLM类

![561](../images/Pasted%20image%2020260808230946.png)

**这里分析一下类的继承关系**：
- 基类：EngineClient
	- 这个就是一个抽象基类，子类分为**异步前端和同步前端**
	- 里面的方法全是抽象方法
- 子类
	- AsyncLLM：
		- 这就是我们的异步的**引擎前端**类，下面是提供的一些方法：
		- ![](../images/Pasted%20image%2020260808231446.png)

也就是说，我们的app在构造这个引擎前端的时候，是调用的`from_vllm_config`这个工厂函数来调用init方法构造类对象实例的。
![453](../images/Pasted%20image%2020260808231651.png)

> 这里的调用的是cls()的方法，关于这个的方法，主要还是方便继承的父类方法直接构造子类
> ![](../images/Pasted%20image%2020260808231836.png)


所以我这里调用的是 AsyncLLM子类的__init__的构造方法

下面来看一下我们的AsyncLLM的引擎前端对象实例，里面包含了那些东西
![509](../images/Pasted%20image%2020260808232459.png)


可以看到，核心的就是：
- 配置实例
- 输入预处理器实例
- 输入、输出格式转换器
- self.engine_core
	- 注意，这里的这个不是单指的引擎后端，是包括前端进程里面剩下的所有设计后端管理的：
		- ZMQ传输实例
		- 引擎后端进程管理器实例
- 一个后台协程任务

所以下面主要分析：
- <mark style="background:#ff4d4f">self.engine_core</mark>
- <mark style="background:#ff4d4f">后台协程  _run_output_handler </mark>

---

先分析self.engine_core的构造吧
![](../images/Pasted%20image%2020260808233342.png)

可以看到，调用的是**EngineCoreClient**的工厂函数

![492](../images/Pasted%20image%2020260808233440.png)

而这个是一个基类，同样也是一个工厂函数

![482](../images/Pasted%20image%2020260808233510.png)

所以他实际上，构造的是<mark style="background:#fff88f">AsyncMPClient</mark>这个类的对象，这个是一个<mark style="background:#fff88f">传输层的对象</mark>

下面我们来看一下这个引擎传输层的类的继承关系
- <mark style="background:#fff88f">基类：EngineCoreClient</mark>
	- ![394](../images/Pasted%20image%2020260808233812.png)
	- 可以看到这个基类就是提供了**工厂函数来构造不同的引擎传输层**：
	- ![](../images/Pasted%20image%2020260808233853.png)
	- <mark style="background:#fff88f">子类：MPClient</mark>
		- **这个类来fork我们真正的引擎后端进程管理器**
		- <mark style="background:#fff88f">子类：AsyncMPClient</mark>
			- 再增加前端引擎后端的输出缓存协程队列:**output_queue**
			- ![](../images/Pasted%20image%2020260808234241.png)


> 所以，EngineCoreClient基类，仅负责来选择构造什么样的引擎后端。
> 
> 然后MPClient子类，来负责构造实际的引擎后端进程管理器，
> 
> 然后在这个类的基础上，AsyncMPClient子类来构造专属于这个引擎后端进程的传输层。


下面来看一下MPClient类是如何具体构造我们的引擎后端进程管理器的


1. 构建引擎前端的ZMQ的context（绑在了引擎传输层上，所以也是属于前端的一部分）：
![](../images/Pasted%20image%2020260808234644.png)

> ![](../images/Pasted%20image%2020260808234947.png)
> <mark style="background:#ff4d4f">重要</mark>
> 
> **所以这个时候你在看，就是引擎前端实例，的self.engine_core这个成员，用来保存的是AsyncMPClient这个实例对象的，这个对象，包含隶属于引擎前端的传输层，也包含用于构造和管理引擎后端进程的引擎后端进程管理器**。





2. 构造一个资源管理器，用来统一回收加入的资源
![](../images/Pasted%20image%2020260808234820.png)


3. <mark style="background:#fff88f">这里就是开始创建好针对这个引擎前端的 ROUTER + PULL 套接字</mark>
	1. 然后把这些套接字都加入上面的资源管理器
![](../images/Pasted%20image%2020260808235226.png)

<mark style="background:#ff4d4f">重要</mark>

**这里就是最精彩的部分，with as + launch_core_engines，就是开始真正创建我们的引擎后端进程的地方。**

![595](../images/Pasted%20image%2020260808235542.png)

这个方法，可以看到被装饰成一个上下文管理器，因此，yield上部分是一个资源对象的构造逻辑，下部分是这个资源的等待配对/销毁逻辑，写在一起了。

然后返回一个引擎后端进程管理器：
![539](../images/Pasted%20image%2020260808235853.png)

> **可以看到yield上半部的逻辑是构建CoreEngineProcManager类的实例对象，然后直接抛出，等外面的with as 的逻辑走完了，在进入yield的下半部，进行等待引擎进程们启动**


<mark style="background:#ff4d4f">重要</mark>

下面来分析一下看看 CoreEngineProcManager 这个引擎后端进程管理器是如何构造和启动引擎后端进程们的。

看一下__init__的输入参数：
![610](../images/Pasted%20image%2020260809000716.png)

构造逻辑：
![543](../images/Pasted%20image%2020260809000735.png)

![514](../images/Pasted%20image%2020260809000852.png)

![515](../images/Pasted%20image%2020260809000916.png)


至此，<mark style="background:#fff88f">我们的主进程：</mark>
- 引擎前端实例：class AsyncLLM
	- 成员属性engint_core = EngineCoreClient.make_async_mp_client （基类工厂方法）-> class AsyncMPClient
		- 基类：MPClient 
			- 准备ROUTER + PULL 套接字
			- 资源管理器，保存 引擎后端进程管理器对象 launch_core_engines
				- 构造 class CoreEngineProcManager 实例
					- <mark style="background:#fff88f">按照要求，proc.start() 拉起来配置需要的引擎后端进程</mark>，引擎后端进程的入口函数为：target=EngineCoreProc.<mark style="background:#fff88f">run_engine_core</mark>
				- 等待引擎进程连接
		- 子类：AsyncMPClient
			- 提供output_queue 协程队列 + process_output_socket的后台协程任务

之后，我们的主进程就进入一些接力的后台接受输出的任务：
![](../images/Pasted%20image%2020260809002421.png)

![](../images/Pasted%20image%2020260809002507.png)

以上就是我们的主进程，也就是引擎前端进程。

下面来看看引擎后端进程的入口函数为：target=EngineCoreProc.<mark style="background:#fff88f">run_engine_core</mark> 是如何具体进入的，调用的刚好是引擎后端进程类的一个工厂函数

**此时已经是一个新的进程了**。可以看到这里的类关系是：
- <mark style="background:#fff88f">基类：引擎后端类</mark>
	- <mark style="background:#fff88f">子类：引擎后端进程类</mark>

![535](../images/Pasted%20image%2020260809002707.png)

![550](../images/Pasted%20image%2020260809002721.png)
![542](../images/Pasted%20image%2020260809003046.png)
![352](../images/Pasted%20image%2020260809003141.png)
依然是调用的子类的一个静态方法，来构造一个子类的实例，然后利用基类构造来创建内部的引擎后端

构造完我们的引擎后端进程类实例后，我们调用这个实例的一个开始工作循环，这个就是我们的这个<mark style="background:#fff88f">进程的主要逻辑</mark>。

我们先来看看构造子类和基类：
<mark style="background:#fff88f">看看构造基类EngineCore</mark>, 这个其实已经变成了操作对象实例了，我们主要的进程逻辑在子类市里的run_busy_loop()里面


![](../images/Pasted%20image%2020260809003814.png)


所以，我们看到的引擎后端：EngineCore实例，其实是一个独立的调度域

> 所以<mark style="background:#fff88f">EngineCore是和一个完整模型的推理过程绑定的</mark>，
> 
> 所以DP等于多少，EngineCore就是多少，
> 
> TP是一个模型推理的拆分，所以TP是多少，worker是多少
> 
> 所以，<mark style="background:#fff88f">一个EngineCore， 是独立管理一块逻辑上的kv cache的</mark>，因为是和一个模型的完整推理需要的kvcache相关的

简单总结一下EngineCore的构造逻辑：
![](../images/Pasted%20image%2020260809005131.png)

这里不多分析，下面看看EngineCoreProc的子类实例的构造

这里的init部分，主要是：
- 关于如何把前后端的进程进行握手，连接
- 创建输入输出线程：procress_input/output_sockets

![](../images/Pasted%20image%2020260809005147.png)

![](../images/Pasted%20image%2020260809005201.png)


<mark style="background:#fff88f">至此，引擎前后端，都启动成功，引擎后端进程启动完成之后，就开始进入engine_core.run_busy_loop()，开始工作</mark>


![](../images/Pasted%20image%2020260809005522.png)


![](../images/Pasted%20image%2020260809155939.png)


### 总结
用一张图来总结一下，各个类对象实例的包含关系，以及重要的数据结构

![697](../images/Pasted%20image%2020260809195716.png)










## 2.5_模块间通信格式梳理







## 3_引擎后端架构实现

#### 架构分析


这部分其实就是EngineCoreProc的run_busy_loop的内容了，启动了的后端进程，里面都在干些什么呢？

![](../images/Pasted%20image%2020260809200425.png)


可以看到，就干2件事：
- input_queue的请求，分发给scheduler
- _process_engine_step(), 进行一次推理


##### 分发请求到调度器_process_input_queue()
![](../images/Pasted%20image%2020260809200628.png)
主要核心就是每次看到input_queue里面有东西，就拿出来调用：
- _handle_client_request 来分发请求

![](../images/Pasted%20image%2020260809200721.png)

具体的分发逻辑，是按照收到的请求的指令类型来调用不同的调度器接口

![](../images/Pasted%20image%2020260809200800.png)

所以不存在"多个分发队列"——队列全部在 Scheduler 类内部：

|队列|位置|作用|
|---|---|---|
|`input_queue`|EngineCoreProc|ZMQ → 主循环的中转站（你说得对）|
|`self.waiting`|Scheduler|新请求排队，等 `schedule()` 选中|
|`self.running`|Scheduler|正在跑的请求，每 step 重新调度|
|`finished list`|Scheduler|本步完成/中止的，下步清理 cache|

`_handle_client_request` 只是一个**路由器**，不存数据。
- ADD → `scheduler.add_request()` 塞进 waiting 队列
- ABORT → `scheduler.finish_requests()` 标记完成。


真正的调度逻辑在 `schedule()` 里：从 `waiting` 取、分配 KV cache、放进 `running`。

---

##### 执行一步推理_process_engine_step
![](../images/Pasted%20image%2020260809201917.png)

调用注册的step()方法，来让基类EngineCore来驱动Scheduler 和 Executor 来完成一个token的推理，

![](../images/Pasted%20image%2020260809202925.png)

然后把结果放到output_queue里面，之后返回这次的状态，到底有没有执行




### 3.1_调度器scheduler
下面来分析调度器，是如何根据自己内部的各种队列，来实现调度策略的


我自己总结一下调度器类在构造时的基础属性
```python

class Scheduler():
# 基础属性
	vllm_config # 推理框架配置
	scheduler_config # 调度器配置
	cache_config # kvcache的配置
	kv_cache_config
	parallel_config # 并行化配置（没什么用）
	
	max_num_running_reqs # 每轮最大req数
	max_num_scheduled_tokens # 每轮最大计算token数
	max_model_len # 单个req的模型kvcache上下文窗口长度
	
	
	num_gpu_blocks # GPU的block pool的大小
	
	requests : dict[str, Request] # 保存所有历史请求
	
	policy # 调度策略，FCFS还是PRIORITY，决定req的挑选顺序
	
	
	
	# 调度的主要的3个队列
	self.waiting # 遵循policy的优先级队列
	self.skipped_waiting # 遵循policy的优先级队列
	
	self.running : list[Request]
	
	
	
	self.hash_block_size # 每个hash块多少个token数
	self.kv_cache_manager # kvcache的block管理器
	
	
	current_step = 0 # 步进计数
	_pause_state # 调度器状态
	
	_inflight_prefills # 正在prefill阶段的req的集合
	
	
	
	
	
	

	
	
```



先来看一下调度器类的定义：
```txt
     === 类说明 ===
        继承: SchedulerInterface(ABC)
        职责: vLLM V1 核心调度器。管理请求生命周期（等待→运行→完成），
              分配 KV cache block，每步选取 batch 交给模型执行器做前向推理。

    === 基类方法实现 (22个) ===
        schedule()              — 核心：选取请求 + 分配 KV cache
        update_from_output()    — 根据模型输出更新请求状态，返回 EngineCoreOutputs
        add_request()           — 新请求加入等待队列
        finish_requests()       — 中止/停止请求
        get_num_unfinished_requests() — 未完成请求数
        has_unfinished_requests()     — 是否有未完成请求
        has_finished_requests()       — 是否有已完成待清理的请求
        has_requests()          — 是否有任何待处理请求
        update_draft_token_ids()      — 更新草稿 token（投机解码）
        update_draft_token_ids_in_output() — 同上 + 更新 SchedulerOutput
        get_grammar_bitmask()   — 获取结构化输出语法掩码
        get_request_counts()    — 返回 (运行中, 等待中) 数量
        get_kv_cache_usage()    — KV cache 使用率
        pause_state / set_pause_state — 暂停状态
        reset_prefix_cache()    — 重置 KV 前缀缓存
        reset_encoder_cache()   — 重置编码器缓存
        make_stats()            — 生成调度统计
        shutdown()              — 关闭
        get_kv_connector() / get_ec_connector() / get_kv_event_publisher_config()

    === [新增] 公有方法 (2个) ===
        reset_connector_cache()     — 重置 KV connector 缓存 (disaggregated prefill)
        make_spec_decoding_stats()  — 生成投机解码统计

    === [新增] 核心成员属性 ===
        —— 请求容器 ——
            requests: dict[str, Request]    — 所有请求 {req_id → Request}
            waiting: RequestQueue           — 等待队列（按策略排队）
            skipped_waiting: RequestQueue   — 因依赖/约束被跳过的请求
            running: list[Request]          — 正在运行的请求列表
            finished_req_ids: set[str]      — 本步完成的请求 ID
        —— 调度约束 ——
            max_num_running_reqs: int       — 最大并发请求数
            max_num_scheduled_tokens: int   — 每步最大调度 token 数
            max_model_len: int              — 模型最大上下文长度
            block_size: int                 — KV cache block 大小
            current_step: int               — 调度步数计数器
            policy: SchedulingPolicy        — 调度策略 (FCFS/Priority)
        —— KV Cache ——
            kv_cache_manager: KVCacheManager — KV cache 管理器（block 分配/回收）
        —— 投机解码 ——
            use_eagle: bool                 — 是否使用 EAGLE 投机解码
            num_spec_tokens: int            — 投机 token 数
            num_lookahead_tokens: int       — 前瞻 token 数
        —— KV 传输 (disaggregated prefill) ——
            connector: KVConnectorBase_V1   — KV connector（P/D 分离场景）
            ec_connector: ECConnectorBase   — EC connector（弹性扩容）
        —— 多模态 ——
            encoder_cache_manager           — 编码器缓存管理器
            max_num_encoder_input_tokens    — 编码器最大输入 token 数
        —— 状态追踪 ——
            sched_step_seq / processed_step_seq — 调度/处理步序号
            deferred_frees: deque           — 延迟释放的 block 队列

```

先来同步一下一些概念：
![](../images/Pasted%20image%2020260809202434.png)
![](../images/Pasted%20image%2020260809202513.png)

基本上就是这个类比，类似linux的进程设计。状态流转也类似：

```
                     schedule() 选中
    waiting ───────────────────────────────► running
    (就绪)                                    (运行)

    running ─── 被抢占 ───────────────────► waiting
              ─── 完成/中止 ──────────────► finished

    waiting ─── 条件不满足 ────────────────► skipped_waiting
    (就绪)     (等远程KV/超LoRA上限/...)     (阻塞)

    skipped_waiting ─── 条件满足 ─────────► waiting → running
    (阻塞)            (下轮schedule重试)
```

和 Linux 进程调度确实很像：`running` = `TASK_RUNNING`（在 CPU 上），`waiting` = runqueue 里排队的，`skipped_waiting` = `TASK_UNINTERRUPTIBLE` 这种等 I/O 的阻塞态——等远程 KV 传完、等 LoRA slot 空出来、等多模态编码完。每轮 `schedule()` 都会把 `skipped_waiting` 里的请求重新拿出来看一眼，条件满足了就恢复。


---

#### kvcachemanager

- KVCacheManager 是 Scheduler 和底层 KV cache 之间的抽象层
- KV cache 以 **block** 为单位分配（不是逐 token 分配），一个 block 存储连续若干个 token 的 KV 值

| 参数                     | 含义                      | 单 group 时                 | 多 group 时                 |
| ---------------------- | ----------------------- | ------------------------- | ------------------------- |
| `scheduler_block_size` | 调度分配的**对齐粒度**           | `block_size * DCP` (如 16) | 所有 group 的 **LCM**（最小公倍数） |
| `hash_block_size`      | prefix cache **哈希匹配粒度** | = scheduler_block_size    | 所有 group 的 **GCD**（最大公约数） |

为什么需要两个不同的值？混合架构模型（如 Jamba，attention + Mamba）：

```
attention group: block_size = 16
Mamba group:     block_size = 64

scheduler_block_size = LCM(16, 64) = 64   ← 分配和计算对齐用 64 token
hash_block_size      = GCD(16, 64) = 16   ← prefix 匹配用 16 token（更细）
```

```python
self.kv_cache_manager = KVCacheManager(...)
    ├── coordinator        ← 管理实际的 KVCacheBlock 池（分配/释放/引用计数）
    ├── block_pool         ← block 池引用
    ├── empty_kv_cache_blocks  ← 预构造的空 block 对象（避免 GC）
    ├── watermark_blocks   ← 保留 N 个自由 block，避免频繁抢占
    └── prefix_cache_stats ← prefix cache 命中率统计
```

- Scheduler 调用 `allocate_slots()` 
- → KVCacheManager 算需要多少 block 
- → Block Pool 分配 
- → 返回 `KVCacheBlocks`。
- 
- 如果 pool 不够了，返回 None，Scheduler 就触发抢占。
- 
这就是之前 `schedule()` 里 `new_blocks is None → break / preempt` 那一段。



#### prefix cache

前缀缓存就是：**两个请求共享了开头的 token，第二个请求的 KV 值不用重算，直接复用**
![](../images/Pasted%20image%2020260809221411.png)

![](../images/Pasted%20image%2020260809221504.png)



关于group的含义，我们这里先专注于Attention架构的LLM，所以就是一个group
![](../images/Pasted%20image%2020260809221724.png)




这就是 kv cache block的设计的作用
![](../images/Pasted%20image%2020260809222006.png)
![](../images/Pasted%20image%2020260809222123.png)


这就是kvcachemanager的虚拟页表的设计思想，实际上就是kvcache的显存管理器
![](../images/Pasted%20image%2020260809222308.png)
![](../images/Pasted%20image%2020260809222439.png)

![](../images/Pasted%20image%2020260809222517.png)

整个初始化流程：

```
EngineCore.__init__()
  │
  ├── model_executor.determine_available_memory()   ← 跑一遍算模型峰值显存，确定 KV cache 可用多少
  │
  ├── get_kv_cache_configs(available_memory)        ← 算出来: block_size=16, num_blocks=5000
  │
  ├── model_executor.initialize_from_config(...)    ← Worker 在 GPU 上真正把显存分配掉
  │
  └── KVCacheManager(kv_cache_config, ...)          ← 拿到 block_pool: 5000 个物理 block
```

之后 KVCacheManager 不碰 GPU 显存分配了——它管的是这 5000 个 block 的**逻辑账本**（谁在用、引用计数多少、哪些空闲）。真正的 GPU 显存由 Worker 侧的 Block Pool 持有，初始化完就不再扩了。


关键的分工是：

**申请 block 的时机在 Scheduler，不在 Executor。**

```
Scheduler (CPU)                              Executor (GPU Worker)
─────────────                                ──────────────────────
schedule():
  KVCacheManager.allocate_slots()
    → 返回 new_blocks                         
    → 放进 SchedulerOutput                    
      ├── scheduled_new_reqs                  收到 SchedulerOutput
      ├── num_scheduled_tokens                知道每个请求的 block 映射
      └── req_to_new_blocks ────────────────► 直接写 KV 到对应 block
                                                 ├── 复用 block → COW
                                                 ├── 新 block → 填入 KV 值
                                                 └── 完成 block → 更新引用
```

Executor 只负责**写入**——Scheduler 说"请求 A 的 token 16-31 写到物理 block #42"，Executor 就算出 KV 往里填。Executor 自己不用跟 KVCacheManager 申请任何东西，block 分配在 `schedule()` 这一步已经全部做完了。

KVCacheManager 跑的是**逻辑账本**（谁用哪个 block、引用计数），Worker 侧跑的是**物理仓库**（GPU 显存里的真数据）。Scheduler 管账，Executor 只管搬货。


<mark style="background:#ff4d4f">问答</mark>

> 等一下，你是说kvcachemanager里面的block pool 只是一个按block id来索引的列表，每个block id对应的显存空间，其实是所有层的这个位置的k,v cache的block显存空间，比如32层，那就是32层x2（kv）x16个token的大小。
> 
> 然后你现在来的token，在调度器的时候，根据kvcachemanager，就知道他的block ID了，（这是因为attention每层的的kvcache顺序都是一样的，一个token在layer0写入12号block,在所有层的kvcache都写入第12号block对吧） 
> 
> 然后worker拿到这个token 以及他的block 号，来去每一层的对应的block位置去写是吗？ 
> 
> 
> 可是我还有一个疑问，<mark style="background:#fff88f">这个block内，该token是16个中的第几个，怎么知道的</mark>？


完全正确。第一个问题不重复了，直接答第三个：

**位置由 `num_computed_tokens` 推算出来。**

```
请求A: num_computed_tokens = 100
       新 token 编号 = 100
       100 // 16 = block #6
       100 % 16  = 位置 4（block 内第 5 个槽）

请求B: num_computed_tokens = 47
       新 token 编号 = 47
       47 // 16 = block #2
       47 % 16  = 位置 15（block 内第 15 个槽，马上就满了）
```

Worker 拿到 SchedulerOutput 里每个请求的三个信息就够了：

| 信息                             | 作用                |
| ------------------------------ | ----------------- |
| `num_computed_tokens`          | 知道从哪个 token 位置开始写 |
| `num_scheduled_tokens`         | 知道要写多少个 token     |
| `req_to_new_blocks` (block 列表) | 知道写到哪个物理 block 里  |

写第 n 个 token 时：`block_idx = (num_computed_tokens + n) // 16`，`slot = (num_computed_tokens + n) % 16`，找到 `blocks[block_idx]` → 拿到 block_id → `layer_k[block_id, slot, :, :]`。

![512](../images/Pasted%20image%2020260809230719.png)


同时每个请求内部，都要维护一个自己请求占用的block的表，

![](../images/Pasted%20image%2020260809231030.png)


<mark style="background:#fff88f">每个请求维护自己的虚拟页表（block 列表），映射到物理 block pool 上。和操作系统给每个进程维护页表一个道理</mark>


所以调度器负责选出执行哪个请求，得到需要新计算多少个token, 里面的kvcachemanager负责在这个请求里面附上这个请求的页表（block占用表），然后计算出新的token要写入的block。

worker收到这个请求后，根据token的序号，以及这个页表就知道，往哪里写入了。

![](../images/Pasted%20image%2020260809231335.png)

![](../images/Pasted%20image%2020260809231646.png)

![](../images/Pasted%20image%2020260809231801.png)


#### 优化总结：pagedattention = blockmanager + prefix cache
BlockPool + Prefix Cache = PagedAttention 的两个核心支柱：

|支柱|对应|解决的问题|
|---|---|---|
|**分页管理**|BlockPool + 引用计数|显存不按请求预留，按 block 粒度动态分配/回收|
|**页共享**|Prefix Cache + COW|共享前缀复用同一页，零拷贝零重算|

就是操作系统的虚拟内存思想搬到 KV cache 上——
- 页表（每请求的 block 列表）、
- 物理页池（BlockPool）、
- 写时复制（COW）、
- 页回收（抢占/evict），

全套搬过来了。vLLM 论文的核心贡献就是这个。


![](../images/Pasted%20image%2020260809232203.png)









#### prefill chunked
**Chunked Prefill** 依赖 block 粒度分配——每个 chunk 只需分配自己的 block，下一个 chunk 分配新的 block。如果 KV cache 是连续分配的，一个长 prompt 必须一次性预留整段连续显存，切块就没有意义。



![](../images/Pasted%20image%2020260809232317.png)

代码中三个关键逻辑：

**1. 确定单块大小**（[line 971-973](vscode-webview://0v6anhu7rvonmrg5eum0t53r31phukqu6outl7a0k1sdqa1epd0b/vllm/v1/core/sched/scheduler.py#L971)）：

```python
threshold = self.scheduler_config.long_prefill_token_threshold  # 比如 512
if 0 < threshold < num_new_tokens:
    num_new_tokens = threshold  # 一刀切，最多 512 token/步
```

**2. chunked prefill 没开时，长 prompt 装不下就直接不给调**（[line 977-983](vscode-webview://0v6anhu7rvonmrg5eum0t53r31phukqu6outl7a0k1sdqa1epd0b/vllm/v1/core/sched/scheduler.py#L977)）：

```python
if not self.scheduler_config.enable_chunked_prefill and num_new_tokens > token_budget:
    break  # 不调度这个请求，跳过
```

开了之后，即使 prompt 有 4096 token，也只分配 `min(512, token_budget)` 个 token 的 block——剩下的下步再说。

**3. 请求保持 running 状态**（[line 1153](vscode-webview://0v6anhu7rvonmrg5eum0t53r31phukqu6outl7a0k1sdqa1epd0b/vllm/v1/core/sched/scheduler.py#L1146)）：

```python
# 被 chunked 的请求 → 设置为 RUNNING，但不标记为 prefill_chunk
# 下一轮 scheduler 遍历 running 队列时发现它 num_computed_tokens < num_tokens
# 就继续给它分配下一个 chunk
request.status = RequestStatus.RUNNING
```

**核心效果**：长 prompt 的 TTFT 大幅改善——不用等 4096 token 全部 prefill 完才输出第一个 token，像 decode 一样穿插在每步中逐步推进。同时 PagedAttention 的 block 粒度分配让每个 chunk 独立分配 block，不要求连续显存。




**第一点**：chunked prefill 解决的就是长 prompt 独占计算资源的问题。没有它，4096 token 的 prefill 一次吃掉全部 `token_budget`（8192 能装下），同 batch 的其他 decode 请求全被挤到下一步。

**第二点**：对，`token_budget`（计算预算）和 KV cache 剩余（存储预算）是两套独立约束：



<mark style="background:#fff88f">所以，chunked prefill解决的就是过长的prompt请求，独占调度位的问题。</mark>


![](../images/Pasted%20image%2020260809232922.png)

剩下的复杂度不在调度侧，而是在 **Worker 执行侧**：一个 batch 里同时有 prefill chunk（可能 512 token）和 decode（1 token），attention kernel 要处理两个不同长度的 KV 写入——decode 只写 1 个位置而 prefill chunk 要写 512 个。这个 ragged batch 的处理是 CUDA kernel 的活，不是调度器的活。





#### continuous batching

**Continuous Batching** 依赖 block 级别的动态混合——一个 batch 里 5 个 decode 请求各写 1 个 token，1 个 prefill 请求写 200 个 token，它们的 block 交错分配，互不干扰。没有分页管理，decode 和 prefill 的显存混在一起，新请求插不进来


Continuous Batching 的核心思想一句话：**prefill 和 decode 没有物理隔离，每一步用一个 `token_budget` 混着跑**


![](../images/Pasted%20image%2020260809234219.png)

![](../images/Pasted%20image%2020260809234248.png)
所以"batch"没有消失，它只是变成了**每步动态重新构成的临时集合**。Scheduler 每次 `schedule()` 都从头遍历 `running` + `waiting`，重新决定这步谁上谁下。不像传统做法"锁死一批请求直到全部跑完"。

这就是为什么 `SchedulerOutput` 同时包含 `scheduled_new_reqs`（新进来的）、`scheduled_resumed_reqs`（恢复的）、`finished_req_ids`（这步完成的）、`preempted_req_ids`（这步踢掉的）——每一步 batch 的边界都可以变化。


#### 投机解码 speculative decode

这个的思路是借鉴prefill，以及训练的时候是并行计算的，但是推理是串行推理。

所以，他们提出一种思路：
![](../images/Pasted%20image%2020260810103530.png)


投机解码：
- 大模型，小模型输入一个token
- 同步运行：
	- 大模型推理一步：y2'
	- 小模型推理N步: y2'', y3'', y4'', ....
- 大模型验证小模型的草稿y2'' 是否和自己的正确答案y2'，是一个分布, <mark style="background:#fff88f">小模型y2''预测可信</mark>
	- 大模型并行推理验证后面的
		- 大模型输入y2'', y3'', y4'', ......, 得到y3^, y4^, y5^（大模型的标准答案）
		- 比较：
			- y3'' 和 y3^ 验证同分布，采用
			- y4'' 和 y4^ 验证不是同分布，丢弃
			- 丢弃
			- 丢弃
			- ....
		- 一直到小模型的预测草稿出现错误，就不再采用，直接丢弃
		- 最终大模型采用y2'', y3'' 作为大模型的输出。

> 一次大串行+多次小串行并行 ， 一次大并行评估分布，采用连续正确





---

#### 同步调度器-调度逻辑
![](../images/Pasted%20image%2020260810153127.png)

引擎的 `step()` 方法就是这三个动作的无限循环：
```python
# core.py:647
def step(self):
    # 1. 调度器发出任务
    scheduler_output = self.scheduler.schedule()

    # 2. GPU 执行
    model_output = self.model_executor.execute_model(scheduler_output)

    # 3. 调度器用结果更新状态
    engine_core_outputs = self.scheduler.update_from_output(
        scheduler_output, model_output
    )
```


二者的分工
```
                    schedule()                       update_from_output()
                    ──────────                       ───────────────────
  操作对象:     Request 的选择 + KV cache 分配       GPU 返回的 token + 计数器核销

  对谁做决策:    本轮要算哪些 request、算几个 token     产出 token 是否触发 stop、
                                                      spec token 是否被拒绝

  计数器方向:    乐观递增 (赊账)                      核销/回滚 (平账)
                computed ↑, in_flight ↑,             in_flight ↓, output ↑,
                placeholder ↑ (异步)                  placeholder ↓ (异步),
                                                      computed ↓ (spec 拒绝时回滚)

  输出:          SchedulerOutput                      EngineCoreOutputs
                (发给 GPU 的指令)                      (发给前端的 token 流)
```




调度器的内部状态（8 个计数器 + KV cache + request 队列）只在这两个方法中被修改，形成闭环：

```
  ┌──────────────────────────────────────────────────────┐
  │                    Scheduler 状态                      │
  │                                                      │
  │  running[]  waiting[]  requests{}  kv_cache_manager  │
  │                                                      │
  │  request.num_computed_tokens                         │
  │  request.num_in_flight_tokens                        │
  │  request.num_output_placeholders                     │
  │  request.num_tokens_with_spec                        │
  │  ...                                                 │
  └────────────┬──────────────────────┬──────────────────┘
               │                      │
         ① schedule()          ③ update_from_output()
         发出本轮指令              用 GPU 结果更新状态
               │                      │
               ▼                      ▲
          SchedulerOutput             │
               │                      │
               └──────② GPU ──────────┘
                   execute_model()
```

> **`schedule()` = 向前看，预测下一步需要什么**  
> **`update_from_output()` = 回头看，把 GPU 实际产出的结果落盘到状态里**

两步合作，缺一不可：没有 `schedule()` 状态无法推进，没有 `update_from_output()` 状态无人校验。这就是 vLLM V1 调度器的全部状态机逻辑。



#### schedule() 完整流程

```
schedule() 被 EngineCore.step() 调用
│
├─ Phase 0: 初始化
│   token_budget = self.max_num_scheduled_tokens
│   scheduled_new_reqs / resumed / running / preempted = []
│   req_to_new_blocks = {}      ← 请求→本轮新分配的 block 映射
│   num_scheduled_tokens = {}   ← 请求→本轮调度 token 数映射
│   defer_prefills = throttle_prefills and not capacity_bound
│                    and (running 中有 decode 请求)
│
├─ Phase 1: RUNNING 遍历 (while req_index < len(running) and token_budget > 0)
│   │
│   │  request = self.running[req_index]
│   │
│   ├── 跳过判断 ──────────────────────────────
│   │   ├─ num_output_placeholders > 0 且已满 → req_index++, continue
│   │   ├─ current_step < next_decode_eligible_step → req_index++, continue
│   │   └─ defer_prefills 且这是 prefill chunk → req_index++, continue
│   │
│   ├── ① 计算 num_new_tokens ──────────────────
│   │   num_new_tokens = num_tokens_with_spec + num_output_placeholders
│   │                     - num_computed_tokens
│   │   ├─ long_prefill_token_threshold 截断  (chunked prefill)
│   │   ├─ min(num_new_tokens, token_budget)
│   │   └─ min(num_new_tokens, max_model_len - num_computed_tokens - 1)
│   │
│   ├── num_new_tokens == 0? → req_index++, continue  (不严格FCFS)
│   │
│   ├── ② allocate_slots() ────────────────────
│   │   │
│   │   │  while True:
│   │   │    new_blocks = kv_cache_manager.allocate_slots(request, num_new_tokens)
│   │   │    │
│   │   │    ├─ new_blocks != None → 分配成功, break
│   │   │    │
│   │   │    └─ new_blocks == None → 分配失败, 需要抢占
│   │   │       │
│   │   │       ├─ PRIORITY策略: 抢占 running 中 priority 最高的
│   │   │       │   └─ 若该请求已被本轮调度 → 回退 token_budget, req_index -= 1
│   │   │       │
│   │   │       └─ FCFS策略: running.pop()
│   │   │       │
│   │   │       ├─ _preempt_request() → num_computed_tokens=0, 退回 waiting 队首
│   │   │       │
│   │   │       └─ 抢占的正好是当前请求? → break (无法调度)
│   │   │
│   │   if new_blocks is None → break (终止 RUNNING 遍历)
│   │
│   ├── ③ 记录到 scheduled_running_reqs ────────
│   │   scheduled_running_reqs.append(request)
│   │   num_scheduled_tokens[req_id] = num_new_tokens
│   │   token_budget -= num_new_tokens
│   │   req_index += 1
│   │
│   │   (投机 token 记账 / encoder 记账)
│
├─ 统计 scheduled_loras
│
├─ Phase 2: WAITING 遍历 (while (waiting or skipped) and token_budget > 0)
│   │
│   ├── 容量检查 ──────────────────────────────
│   │    num_running >= max_num_running_reqs → break
│   │
│   ├── ① _select_waiting_queue_for_scheduling()
│   │    │
│   │    │  FCFS:  skipped_waiting 优先 (相当于阻塞优先)
│   │    │  PRIORITY: peek 两队头, 比较 priority+arrival_time
│   │    │
│   │    ▼
│   ├── ② request_queue.peek_request()  ← 看队头，不移除
│   │    │
│   │    ├─ 阻塞状态 (REMOTE_KVS / STREAMING)?
│   │    │   ├─ _try_promote 成功 → 继续处理
│   │    │   └─ _try_promote 失败 → pop + prepend 到 step_skipped → continue
│   │    │
│   │    ├─ num_stale_output_tokens > 0 且非 drop 模式?
│   │    │   └─ 僵尸输出还在路上 → pop + prepend 到 step_skipped → continue
│   │    │
│   │    └─ LoRA 上限? → pop + prepend 到 step_skipped → continue
│   │
│   ├── ③ prefix cache 查找 (仅当 num_computed_tokens == 0) ────
│   │    │
│   │    ├─ get_computed_blocks() → 本地 block hash 命中
│   │    └─ KV connector → 远程 KV cache 命中 (num_external_computed_tokens)
│   │    │
│   │    num_computed_tokens = local + external
│   │
│   ├── ④ 计算 num_new_tokens ──────────────────
│   │    │
│   │    ├─ load_kv_async? → num_new_tokens = 0 (只加载不做本地计算)
│   │    │
│   │    └─ 正常计算:
│   │       num_new_tokens = request.num_tokens - num_computed_tokens
│   │       ├─ chunked prefill 截断
│   │       ├─ min(num_new_tokens, token_budget)
│   │       └─ encoder 相关调整
│   │
│   ├── ⑤ allocate_slots() ────────────────────
│   │    │
│   │    ├─ new_blocks != None → 分配成功
│   │    │
│   │    └─ new_blocks == None → 分配失败 → break (终止 WAITING 遍历)
│   │
│   ├── ⑥ 准入 RUNNING ────────────────────────
│   │    │
│   │    ├─ load_kv_async? → status = WAITING_FOR_REMOTE_KVS → prepend skipped
│   │    │
│   │    └─ 正常准入:
│   │       pop_request()  ← 从 waiting 真正移除
│   │       self.running.append(request)
│   │       status = RUNNING
│   │       num_computed_tokens = num_computed_tokens  (含 prefix cache 命中)
│   │       │
│   │       ├─ 原 status == WAITING  → scheduled_new_reqs
│   │       └─ 原 status == PREEMPTED → scheduled_resumed_reqs
│   │
│   │    token_budget -= num_new_tokens
│   │    (投机 token / encoder / LoRA 记账)
│
├─ 回塞: step_skipped_waiting → self.skipped_waiting (本轮跳过的重新入队)
│
├─ DP 记录: if not defer_prefills: prefill_capacity_bound = bool(self.waiting)
│
├─ Phase 3: 组装 SchedulerOutput ────────────────
│   new_reqs_data (v2: new+resumed 合并)
│   cached_reqs_data (running+resumed 的 block_ids, token_ids, computed_tokens)
│   num_common_prefix_blocks
│   kv_cache_block_copies (CoW)
│   finished_req_ids / preempted_req_ids
│
├─ KV connector meta 填充
│
├─ sched_step_seq += 1  (仅当 total_num_scheduled_tokens > 0)
│
└─ _update_after_schedule()  ← 更新 Request 状态
    for each scheduled request:
      request.num_computed_tokens += num_scheduled_token
      request.num_in_flight_tokens += num_scheduled_token
      request.is_prefill_chunk = (computed < tokens + placeholders)

    ═══════════════════════════════════════

    return scheduler_output
```

---

#### update_from_output() 完整流程

```
update_from_output(scheduler_output, model_runner_output)
│  EngineCore.step() → schedule() 之后 → execute_model() 之后
│
├─ Phase 0: 初始化 + 延迟释放
│   │
│   ├─ defer_block_free? → processed_step_seq++ → _drain_deferred_frees()
│   │   (GPU 写入已完成, 之前延迟释放的 block 现在安全归还)
│   │
│   ├─ KV 加载失败处理
│   │   if kv_connector_output.invalid_block_ids:
│   │     _handle_invalid_blocks() → 标记这些 block 需重新计算
│   │
│   └─ routed_experts 持久化到 scheduler 侧 slot buffer
│
├─ Phase 1: 主循环 — 遍历每个被调度的请求
│   for req_id, num_tokens_scheduled in num_scheduled_tokens:
│   │
│   ├── ① 核销 in-flight ──────────────────────
│   │    request.num_in_flight_tokens -= num_tokens_scheduled
│   │    │
│   │    └─ num_stale_output_tokens > 0? → output_is_stale = True
│   │        num_stale_output_tokens -= num_tokens_scheduled  (逐步消化僵尸)
│   │
│   ├── 跳过判断 ──────────────────────────────
│   │    ├─ KV 加载失败? → continue
│   │    ├─ request is None or is_finished()? → continue
│   │    └─ output_is_stale and drop_stale_output? → continue  (丢弃整个"上一世"输出)
│   │
│   ├── ② 投机解码回退 ────────────────────────
│   │    如果 scheduled_spec_token_ids 存在:
│   │      num_accepted = len(generated_token_ids) - num_sampled
│   │      num_rejected = num_draft_tokens - num_accepted
│   │      │
│   │      └─ if not output_is_stale:
│   │           request.num_computed_tokens -= num_rejected   ← 回退
│   │           request.num_output_placeholders -= num_rejected
│   │
│   ├── ③ 释放 encoder inputs ─────────────────
│   │    (本轮已执行完毕，encoder 不再需要)
│   │
│   ├── ④ 判断停止 ────────────────────────────
│   │    │
│   │    ├─ 有产出 token → _update_request_with_output()
│   │    │   │
│   │    │   ├─ 非 stale: token 写入 _all_token_ids + _output_token_ids
│   │    │   ├─ 非 stale: num_output_placeholders -= len(new_token_ids)
│   │    │   ├─ 非 stale: cache_blocks()  ← 将新 block 注册到 prefix cache
│   │    │   └─ 检查 stop string / max_tokens / EOS → 返回 stopped
│   │    │
│   │    ├─ pooling 请求有输出 → FINISHED_STOPPED
│   │    └─ encoder-only 且 prompt 已完 → FINISHED_STOPPED
│   │
│   ├── ⑤ 语法检查 (structured output) ────────
│   │    grammar.accept_tokens() → 失败则 FINISHED_ERROR
│   │
│   ├── ⑥ routed_experts 提取 ────────────────
│   │    prefill 完成时: 从 slot buffer 读取完整 prompt 的专家路由
│   │    decode 时: 只取新 token 的路由
│   │
│   ├── ⑦ 停止处理 ────────────────────────────
│   │    if stopped:
│   │      finished = _handle_stopped_request()
│   │      │
│   │      ├─ 正常 STOP → _free_request() → 释放 KV cache + encoder cache
│   │      │   (request 设为 None, 可被 GC)
│   │      │
│   │      └─ 流式请求 → status = WAITING_FOR_STREAMING_REQ
│   │          (不释放, 继续等待下一次 input)
│   │    │
│   │    └─ 记入 stopped_running_reqs / stopped_preempted_reqs
│   │
│   └── ⑧ 构造 EngineCoreOutput ───────────────
│        outputs[client_index].append(
│          new_token_ids, finish_reason, logprobs, pooling_output,
│          prefill_stats, kv_transfer_params, events, ...
│        )
│
├─ Phase 2: 清理 ──────────────────────────────
│   │
│   ├─ stopped_running_reqs → 从 self.running 移除
│   ├─ stopped_preempted_reqs → 从 waiting + skipped 移除
│   │
│   ├─ grammar 编译错误 → finish_requests(FINISHED_ERROR) → 追加空 output
│   ├─ KV 加载失败且不重算 → finish_requests(FINISHED_ERROR) → 追加空 output
│   │
│   ├─ KV connector 状态更新 (_update_from_kv_xfer_finished)
│   └─ KV cache 事件收集 + 发布
│
├─ Phase 3: 统计 ──────────────────────────────
│   prefix cache stats + connector stats + cudagraph stats + perf stats
│
└─ 构造 EngineCoreOutputs ─────────────────────
    EngineCoreOutputs(outputs, scheduler_stats, ...)
    return {client_index: EngineCoreOutputs}
```

---

#### 两个方法的对应关系

```
schedule()                         update_from_output()
  分配 KV cache               →      核销 in-flight token
  num_computed_tokens += N    →      num_in_flight_tokens -= N
  num_scheduled_tokens[req]=N →      读取 num_scheduled_tokens[req]
  分配 speculative draft      →      接受/拒绝 → 回退 num_computed_tokens
  预占 output_placeholders    →      核销 num_output_placeholders
  new/resumed/running/preempt →      stopped → 清理 running/waiting
```



#### 重要：调度器schedule() 调度策略总结

这里先做一个理解的复盘

1. 3个队列的定位
2. 一个请求调度的数据流向
3. 一个请求会有哪几种状态

下面是剔除所有优化分支后的**最简核心流程**：

```
schedule() 被 EngineCore.step() 调用
│
├─ Phase 0: 初始化
│   token_budget = max_num_scheduled_tokens
│   scheduled_new_reqs / resumed / running / preempted = []
│   req_to_new_blocks = {}           ← req → 本轮新分配的 block
│   num_scheduled_tokens = {}        ← req → 本轮调度 token 数
│
├─ Phase 1: RUNNING 遍历 ─────────────────────────────────────
│   while req_index < len(running) and token_budget > 0:
│   │
│   │  request = running[req_index]
│   │
│   ├─ ① 算 num_new_tokens
│   │    num_new_tokens = num_tokens_with_spec - num_computed_tokens
│   │    num_new_tokens = min(num_new_tokens, long_prefill_threshold, token_budget)
│   │    num_new_tokens = min(num_new_tokens, max_model_len - num_computed_tokens - 1)
│   │
│   ├─ num_new_tokens == 0 → req_index++, continue
│   │
│   ├─ ② allocate_slots() 分配 KV cache
│   │    │
│   │    ├─ 成功 → new_blocks 到手
│   │    │
│   │    └─ 失败 (显存不够) → 抢占 victim
│   │       │
│   │       ├─ FCFS: 抢 running 队尾 (最年轻)
│   │       ├─ PRIORITY: 抢 priority 最低的
│   │       │
│   │       ├─ victim 已在本轮名单? → 收回其 token_budget, req_index -= 1
│   │       └─ _preempt_request(victim)
│   │           └─ num_computed_tokens = 0, 放回 waiting 队首
│   │
│   ├─ ③ 记录到 scheduled_running_reqs
│   │    scheduled_running_reqs.append(request)
│   │    num_scheduled_tokens[req_id] = num_new_tokens
│   │    token_budget -= num_new_tokens
│   │    req_index += 1
│
├─ Phase 2: WAITING 遍历 ─────────────────────────────────────
│   while (waiting or skipped) and token_budget > 0:
│   │
│   ├─ 容量检查: len(running) >= max_running → break
│   │
│   ├─ ① peek 队头 request（不移除）
│   │
│   ├─ ② prefix cache 查找 (仅当 num_computed_tokens == 0)
│   │    new_computed_blocks, num_cached = get_computed_blocks(request)
│   │    num_computed_tokens = num_cached  ← 已命中 token 数
│   │
│   ├─ ③ 算 num_new_tokens
│   │    num_new_tokens = request.num_tokens - num_computed_tokens
│   │    num_new_tokens = min(num_new_tokens, long_prefill_threshold, token_budget)
│   │
│   ├─ ④ allocate_slots() 分配 KV cache
│   │    │
│   │    ├─ 成功 → new_blocks 到手
│   │    └─ 失败 → break (不抢占 waiting 请求)
│   │
│   ├─ ⑤ 准入 RUNNING
│   │    pop_request()                    ← 从 waiting 真正移除
│   │    running.append(request)
│   │    status = RUNNING
│   │    num_computed_tokens = num_computed_tokens  ← 含 prefix hit
│   │    │
│   │    ├─ 原 WAITING   → scheduled_new_reqs
│   │    └─ 原 PREEMPTED → scheduled_resumed_reqs
│   │
│   │    num_scheduled_tokens[req_id] = num_new_tokens
│   │    token_budget -= num_new_tokens
│
├─ Phase 3: 组装 SchedulerOutput ─────────────────────────────
│   new_reqs_data    ← scheduled_new_reqs 的 block_ids + token_ids
│   cached_reqs_data ← scheduled_running/resumed 的增量信息
│   scheduler_output = SchedulerOutput(
│       scheduled_new_reqs,
│       scheduled_cached_reqs,
│       num_scheduled_tokens,       ← executer 用它知道每个 req 算几步
│       total_num_scheduled_tokens,
│       finished_req_ids,
│       preempted_req_ids,
│       ...
│   )
│
├─ Phase 4: _update_after_schedule() ──────────────────────────
│   for each scheduled request:
│     request.num_computed_tokens += num_scheduled_token
│     request.num_in_flight_tokens += num_scheduled_token
│     request.is_prefill_chunk = computed < tokens
│
└─ return scheduler_output
```

 **四个核心思想**

![](../images/Pasted%20image%2020260811104109.png)

至此，我们的run_busy_loop的第一步，就分析完了 


<mark style="background:#fff88f">附加的老师的关于本地、远端kvcache搜查的逻辑</mark>
![](../images/Pasted%20image%2020260811144712.png)

![](../images/Pasted%20image%2020260811144920.png)

<mark style="background:#fff88f">附加老师关于调度任务输出的主要内容</mark>
![](../images/Pasted%20image%2020260811145032.png)

![](../images/Pasted%20image%2020260811145112.png)

![](../images/Pasted%20image%2020260811145200.png)
![](../images/Pasted%20image%2020260811145259.png)


![](../images/Pasted%20image%2020260811145339.png)







我自己的my-vllm里面的，关于waiting队列的req的调度逻辑：

![](../images/Pasted%20image%2020260814135441.png)
![](../images/Pasted%20image%2020260814135415.png)




### kvcache manager

先来看一下使用方：
每一个token输入，模型的每一层，都需要记录下一对k,v向量。所有层的这对kv向量显存，就是我们这个decode阶段要申请的kvcache。
> 如果是prefill阶段的kvcache， 肯定就是一整块的，而不是一个token向量的。

k,v向量的维度 = d_h x num_head.

所以对应num_computed_tokens = L的req来说。他目前占用的kvcache显存是：
L `*` d_h  `*`  num_heads

![](../images/Pasted%20image%2020260814203331.png)

> 我们worker每次执行一次前向推理，会同时处理多个req，里面的req，
> - 可能会包含new req， 需要prompt/ prompt + output的，一口气写prompt_len  `*` d_h  `*` num_heads 个 dtype的kvcache
> - 如果是cached_req, 就只会需要写一个token的kvcache


所以kvcachemanager的设计规则如下：
- 将可用的KVCache预先划分成一个block pool, 作为仓库
	- 受限因素：
		- 用户显存的限制，允许GPU显存使用比例
		- 模型自身权重占掉，推理的中间张量，cuda graph, 临时buffer
	- 启动时执行一次profiling, 使用随机输入数据跑一遍前向传播，观察实际显存峰值占用。这样可以把权重、激活值以及运行时临时 buffer 等因素都纳入统计，得到更接近真实推理过程的显存使用情况
	- ![397](../images/Pasted%20image%2020260814205034.png)
- 每个req 维护一个 block table 的块表
	- 维护一个空闲队列
	- 维护一个hash 到 block的映射（prefix）
		- 为已经计算过的完整block建立hash映射
- 匹配规则
	- 分配显存的颗粒度是一个block
	- prefix cache匹配的颗粒度是block
	- 一个req，每block_size个token计算hash，每个block的hash包含前面的hash，所以hash值本身就隐含了链式关系

![](../images/Pasted%20image%2020260814214859.png)

```txt
新请求
 |
 | tokenize
 |
切KV block
 |
计算block_hashes
 |
 |
查询 cached_block_hash_to_block
 |
 +--------------+
 |              |
命中           miss
 |              |
复用已有block    allocate新block
 |              |
 |              |
 +------prefill剩余token
                |
                |
          cache_blocks()
                |
                |
        hash->physical block加入表
```

所以，对于调度schedule()中，针对每个req，计算他的prefix的full block， 然后计算链式hash，然后prefix cache看看是否命中。把命中的block除掉，剩下的部分，申请显存block。然后记录在这个req的本轮新申请的blocks列表里面，发出去给执行器，交给worker执行，worker拿到这个block来计算kvcache，最后返回结果。 

那么是什么时候，把这个req没有命中但是计算出来的full block加入我们的kvcachemanager的这个prefix cache的表的呢？是update_after_schedule()还是update_from_output?

答案：

**不是 `update_after_schedule()`，而是在 `update_from_output()`（或者等价的模型执行完成后的更新阶段）。**

原因是：**schedule 阶段只是决定要算什么，还没有真正算出 KV。**




![304](../images/Pasted%20image%2020260814220348.png)
![465](../images/Pasted%20image%2020260814220335.png)


![481](../images/Pasted%20image%2020260814220653.png)


###### kvcachecoordinator
我也来总结一下KVCacheManager类的主要属性
```python
class KVCacheManager:
# 基础属性
	max_model_len # 单个req的最大上下文kvcache长度
	max_in_flight_tokens = max_model_len
	num_kv_cache_groups # kvcachegroup数
	kv_cache_config # 配置
	watermark_blocks # 最小空闲block数，避免频繁抢占
	empty_kv_cache_blocks # 每个group一个空block，一个req如果没有分到block,就引用他
	
	
	
	self.coordinator # 构造一个单group类型的 kv协调器，取出物理block pool句柄

	# 核心属性，单layer的block pool
	self.block_pool = self.coordinator.block_pool # 取出来的block_pool句柄
	
```

所以看来物理block pool的获取，还需要依赖kvcoordinator来获取每个分组不同类型的block

单个kv_group的时候，构造的是UnitaryKVCacheCoordinator这个类

```python

class UnitaryKVCacheCoordinator(KVCacheCoordinator):
# 基类属性
	kv_cache_config # kvcache的属性配置
	max_model_len 
	enable_caching # flag, 开启prefixcache
	
	scheduler_block_size #调度器下一个block 16个token
	
	
	# 核心属性：单层的block id
	self.block_pool # 构建统一内存池块，作为所有组的物理块来源
	
	
	# 核心属性：多个group的管理器，来把公共的block id，解析成各自group layer的group-block id
	self.single_type_manager = tuple(get_manager_for_kv_cache_spec for i in kv_cache_groups)# 为每个kvcache group 构建对应的单类型管理器，形成管理链
	
	
	
	
# 子类属性
	num_single_type_manager # 记录管理器的个数，供后续零命中的时候使用
```

所以，可以看到，这里的协调器，仅仅只是维护保存一个统一的物理block，具体针对某个kvcache block管理的，还是有下一级的管理器的。


###### kvcachemanager
```python
class SingleTypeKVCacheManager:
	scheduler_block_size #block_size
	block_size      #一个block多少个token
	kv_cache_spec   # 这个类型的kvcache规格
	kv_cache_group_id  #本group类型id
	_null_block #空block
	self.block_pool #单卡单层的block池
	_max_admission_blocks_per_request #每个req请求的block上限
	
	
	
	self.new_block_ids: list[int] # 本batch新分配的，需要worker清零的 block_id列表
	self.req_to_blocks: dict[req_name, list[KVCacheBlock]] #每个req的本group的block id，
															# 用来调度的筹码
	self.num_cached_block: dict[req_name, int] #每个req已经占用的block数
	
```




下面我们先看一下block_pool是个什么样子的数据结构

<mark style="background:#40a9ff">一个 BlockPool，N 个管理器，共享同一个池</mark>

![](../images/Pasted%20image%2020260815135336.png)

```python
# 一个 BlockPool，N 个管理器，共享同一个池
class BlockPool:
# 基础属性
	num_gpu_blocks # 单模型副本下，每张卡的最小block数量,由moder_runner测定
	enable_caching # flag， 使能prefix cache
	hash_block_size # 求hash的16个token
	
	# 创建每张卡公共的block逻辑块的列表，用来统一管理
	self.blocks : list[KVCacheBlock] = [KVCacheBlock(i) for i in range(num_gpu_blocks)]
	
	# 用我们创建出来的整个模型副本的单卡的逻辑block表，来构建一个空闲block队列
	self.free_block_queue : FreeKVCacheBlockQueue(self.blocks)
	
	# 构建正反向 的 块hash映射表
	self.cached_block_hash_to_block: BlockHashToBlockMap 
	self.cached_block_hashes_by_block:dict[int, set[BlockHashWithGroupId]]
```

所以一个<mark style="background:#fff88f">BlockPool，块池</mark>，就是<mark style="background:#fff88f">一个模型副本</mark>下 <mark style="background:#fff88f">单类型(</mark>attention的显存) 的<mark style="background:#fff88f">单卡</mark> 的<mark style="background:#d3f8b6">空闲block队列</mark>+<mark style="background:#d3f8b6">hash块映射表</mark>

![](../images/Pasted%20image%2020260815151445.png)

`_block_hash` = 「链式内容哈希 + 所属 group 编号」拼成的一个 bytes 键。哈希管「内容是什么」，group_id 管「这块存在哪一类 KV block pool 里」，两者拼一起才是前缀缓存里真正拿来查表的完整 key。


我们来看一下一个逻辑block块是如何实现的，里面究竟有什么：
```python
class KVCacheBlock:
# 基础属性
	block_id # 单卡内的逻辑block编号：0 - num_gpu_blocks-1
	ref_cnt # 被引用计数
	
	# 【内容hash链 - block_id 信息】
	_block_hash: BlockHashWithGroupId # full block的链式hash值+groupid(还没分组呢)
	_block_hash_num_tokens #这个 block 的哈希覆盖了多少个前缀 token
	
	prev_free_block # 前一个block指针
	next_free_block # 后一个block指针
	
	is_null # flag， 标记这个block永远不擦怒缓存，占位用
```

我们来看一下这个空闲队列是如何实现的：
```python
class FreeKVCacheBlockQueue:
# 基础属性
	num_free_blocks # 逻辑单卡上的可用block数

	(把KVCacheBlocks收尾相接，做成双向空闲block链表)
	
	# 头尾dummy指针，然后接上去
	fake_free_list_head
	fake_free_list_tail

```


所以对于一个KVCacheCoordinator这样一个协调基类，他创建一个BlockPool, 这个里面根据num_gpu_blocks 来创建出空的KVCacheBlock，然后把他们串成双向链表，这个时候，这个就是一个单卡的逻辑显存块池，此时里面的block块还没有分组，因为都是空闲的。


接下来我们看一下KVCacheCoordinator， 他为每一个group的显存组，都创建一个对应的管理器是如何实现的
```python
       self.single_type_managers = tuple(
            get_manager_for_kv_cache_spec(
                kv_cache_spec=kv_cache_group.kv_cache_spec,
                max_in_flight_tokens=max_in_flight_tokens,
                max_model_len=max_model_len,
                block_pool=self.block_pool,
                enable_caching=enable_caching,
                kv_cache_group_id=i,
                dcp_world_size=dcp_world_size,
                pcp_world_size=pcp_world_size,
                scheduler_block_size=self.scheduler_block_size,
                needs_kv_cache_zeroing=self.kv_cache_config.needs_kv_cache_zeroing,
            )
            for i, kv_cache_group in enumerate(self.kv_cache_config.kv_cache_groups)
        )
# 这里经常看到spec, 这个spec是规格的意思，就是配置

# 可以看到他这里面枚举了self.kv_cache_config.kv_cache_groups

class KVCacheConfig:
# 基础属性
	num_blocks #显存profile后的逻辑单卡的 总块数
	kv_cache_tensors: list[KVCacheTensor]
		'''
		class KVCacheTensor:
			size                 # kvcache张量的字节数
			shared_by: list[str] # 共享相同 kvcache张量 的 层名
			offset               # 这一层的
			block_stride
		'''
	kv_cache_groups: list[KVCacheGroupSpec]
		'''
		class KVCacheGroupSpec:
			layer_names: list[str]
			kv_cache_spec: KVCacheSpec
			is_eagle_group 
		'''
        

```

<mark style="background:#fff88f">关于KVCacheTensor类的理解，为什么要设计这个类，原因是，一个KVCacheTensor类，表示一种形状的kvcache的显存空间及其内部划分。</mark>
![](../images/Pasted%20image%2020260815161816.png)

![](../images/Pasted%20image%2020260815162925.png)
- 所以前面kvcachetensor，是描述同一种形状的layer，他们的kvcache显存的整体的tensor的一个类。是用<mark style="background:#fff88f">来描述他们的显存布局的</mark> 
- 后面的kvcachegroupspec, 则是用来描述同一种形状的kvcache的layer，他们这一组，每个层的层名，以及任意层的kvcache的规格。<mark style="background:#fff88f">是用来描述形状的</mark>。

所以我们的KVCacheConfig配置类
```python
class KVCacheConfig:
	num_blocks # profiling 测出来的
	kv_cache_tensors: list[KVCacheTensor] #各种类型的kvcache的显存区域的列表
	kv_cache_groups: list[KVCacheGroupSpec] #各种类型的kvcache的组的列表，每个组有xx层，以及kvcache的形状
```


<mark style="background:#fff88f">所以这个时候，你在看这个，就知道他是针对每种类型的kvcache组，来分别创建不同kvcache类型的管理器</mark>
![](../images/Pasted%20image%2020260815163238.png)
> 这里加深了kvcache group的理解


下面来看一下KVCacheSpec那个类，就是描述每个group的kvcache的形状的类，里面只有描述block_size的属性。

![536](../images/Pasted%20image%2020260815163724.png)
其实，这是一个基类，
![](../images/Pasted%20image%2020260815163802.png)
这里的子类真正列出了一个attention的kvcache的形状：
- 头数
- 头维
- 数据类型
- 量化模式
- 等等

除此之外还有Mamba的kvcache的类型
![](../images/Pasted%20image%2020260815163915.png)



所以这个时候，就很容易理解，KVCacheCoordinator的构造中
- self.block_pool构造所有组的物理块的抽象block列表
	- **block 不是「形状还没定」，而是「永远没有形状」**——形状从来就不属于 block。
- 为每个group形状的kvcache，分别创建对应的管理器，来把真实的block形状和block_pool的抽象的block挂上钩
![](../images/Pasted%20image%2020260815164522.png)

trace代码后，我们开始构造<mark style="background:#fff88f">全注意力的管理器</mark>
![](../images/Pasted%20image%2020260815165232.png)

![](../images/Pasted%20image%2020260815165324.png)

来看看基类，这是一个单类型的管理器
```python
class SingleTypeKVCacheManager:
# 基础属性
	scheduler_block_size
	block_size
	kv_cache_spec # 这里已经是attentionspec了
	block_pool # 构造的时候，传入的KVCacheCoordinator的 抽象block池
	enable_caching #flag
	self.new_block_ids : list[int]
	self.req_to_blocks : dict[str, list[KVCacheBlock]] # 每个req这种group类型的kvcache block列表
	self.num_cached_block : dict[str, int] # 每个req在这种group类型，已经占了多少个kvcache block数量
	self.kv_cache_group_id # 这个group类型ID
```

所以，是不同group的管理器内部，分别维护一个req在这个模型副本上的不同group的kvcache block列表，KVCacheCoordinator里面的block_pool只是表示抽象的block资源。


> 那为什么我们从来没有看到KVCacheBlock这个抽象block块和每个卡里面的实际block物理ID挂上钩呢?


这里的block_id， 就是在KVCacheCoordinator里面的self.block_pool里面的每个KVCacheBlock的block_id，应该是逻辑编号，是这里的range num_gpu_blocks里面的idx吧， 他设置好了这个之后，后面构造具体group的管理器的时候，就获得了我们的每个block的真实显存大小，所以之后，就直接让worker在他申请好的这一大块显存里面，取找就行了是吗？因为workerprofile之后，就直接申请好了每个group的显存区域，所以才有我们的num_gpu_blocks的是吗？


**「逻辑编号」和「物理下标」在这里是同一个数，不存在第二层翻译**

对，[block_pool.py:175-177](vscode-webview://0v6anhu7rvonmrg5eum0t53r31phukqu6outl7a0k1sdqa1epd0b/vllm/v1/core/block_pool.py#L175)：

```python
self.blocks = [KVCacheBlock(idx) for idx in range(num_gpu_blocks)]
```

`block_id` 就是 `0, 1, 2, ..., num_gpu_blocks-1`。你叫它「逻辑编号」没错，但关键是：

> **这个逻辑编号，直接拿来当 GPU 张量第一维的下标用，不用再翻译。**

也就是说，不存在「逻辑 block 5 → 物理 block 17」这种映射。逻辑 5 就是物理 5。我之前说「block_id 本身就是物理 block id」，意思是「CPU 账本里那个整数，原封不动就是 GPU 上的 slot 下标」，不是说有两个编号体系。

---
```
① worker profiling → available_memory（字节）
② 统一 page_size → 公共 page_size_bytes 
③ num_gpu_blocks = available_memory // page_size_bytes   ← 关键数字在这诞生
④ 这个 num_gpu_blocks 回传给 engine，两边各用一份：
   ├─ CPU：BlockPool 造 num_gpu_blocks 个 KVCacheBlock（账本）
   └─ GPU：worker 分配张量，第一维 = num_gpu_blocks（真实显存）
```

**`num_gpu_blocks` 是在「账本」和「显存」都还不存在之前，先由 profiling 算出来的一个数**，然后两边各自拿同一个数去建自己的东西。所以你说的「才有我们的 num_gpu_blocks」——对，它来自 profiling。


你的理解对：block_id 就是 `range(num_gpu_blocks)` 的 idx，`num_gpu_blocks` 由 profiling 定；worker 拿到这个数后**一次申请一整块连续显存**，reshape 成第一维 = num_gpu_blocks 的张量；之后用 block_id 直接当第一维下标去「找」那一块的 KV。**「逻辑编号」和「物理下标」是同一个整数，中间没有翻译表。**


所以接下来的重心在于worker init kvcache, 看看是如何计算单group类型的num_gpu_blocks的



#### 自己关于block_pool 和 初始化kvcache显存的理解

下面我来说一下我的一个关于model\_runner kvcache显存初始化的理解。

num\_gpu\_blocks 表示可用的block数，但是我理解是，<mark style="background:#fff88f">这个是一个模型副本，所有层，共用的一个层内block数</mark>。


因为我发现假设，我们现在的模型，有两个group类型的kvcache张量，假设模型一共20层，0-9层是group0, 每个token的k,v向量是1024维度，都假设一个block\_size=16个token, 所以group0区域的一个block大小假设是16MB，



后10-19层是group1, 每个token的k,v向量是2048维度，假设还是block\_size=16, 所以group1区域的一个block大小是32MB


重点来了，<mark style="background:#fff88f">因为我们模型副本的层数，形状，不同group的层数比例是固定的</mark>，也就是说，输入一个token，每个层都会产生一个token的kv向量，输入16个token，每个层都会产生一个对应group类型的block，所以这个显存消耗是固定的。比如一个token输入，会占用128MB的kvcache, 其中就固定会有比如72MB的group0, 56MB的group1。



所以下面我来说一下我对model\_runner初始化kvcache显存的一个猜测

所以model\_runner的dummy\_run，就是利用这个比例固定，假设最后测定下来，可以给kvcache使用的显存是48G，所以，根据我们上面的72MB:56MB的比例，就可以直接划分27G给group0的tensor, 划分21G给group1的tensor。然后在各自的tensor里面，划分每一层，比如group0的Tensor，里面划分了10个layer,分别属于layer0-9, group1的tensor里面划分了10个layer,分别属于10-19.



然后每个layer区域的显存块里面，根据group的block形状，又切分出layer内的block。



所以我们kvcachemanager，kvcachecoordinator，用到的num\_gpu\_blocks，其实是指的任意group内的任意layer区域里面的block的数量，



因为我们一个layer用多少block，其实就已经决定了同group内任意layer用多少block，不同group的不同layer用多少block。



所以，num\_gpu\_blocks表示的是整个模型副本里面，单层的可用显存block数。



所以当我们调度器让kvcachemanager allocate slots 分配一个block， 从我们的空闲队列里面拿出一个block，底层是让各自group的管理器去真正的去各自的KVCacheTensor里面找到对应的各层的block的逻辑偏移位置是吗？



我理解的对面？请你简单，简洁，直接的回答我，不要长篇大论，不要模棱两可


---

<mark style="background:#fff88f">实际上，这边我理解的对了一半，主要在分配上错了，num_gpu_blocks的理解对了。</mark>

![](../images/Pasted%20image%2020260816101418.png)
![](../images/Pasted%20image%2020260816101436.png)



![](../images/Pasted%20image%2020260816101358.png)

- 按KVCacheTensor为每个layer分配固定字节的raw buffer
	- allocate_kv_cache_tensors
- 每个tensor reshape出block维度
- block_id in range(num_gpu_blocks), 是每个tensor里面的物理偏移。


### profiling kv cache
调度器构造kvcachemanager的核心就是已经知道num_gpu_blocks， 

这个是worker在profiling后，根据峰值显存占用 + 我们的kv_cache_spec 来申请划分好kvcache的显存块，然后把物理显存块的顺序id，当成单卡的逻辑id，这样我们enginecore拿到num_gpu_blocks就可以直接从0 - (num_gpu_blocks-1) 的逻辑id，直接等同于每个卡的物理blockid。

下面来分析是如何profiling的，先看一下一个卡里面的显存的三种使用情况

```python
# vllm启动前
	1. 1G（其他进程）
	2. 0G（模型+层间输入输出缓冲区）
	3. 0G（通信NCCL占用，算子后端）
	   
# vllm启动后，加载完模型，暂停
	1. 1G （其他进程）
	2. 2G （模型权重）
	3. 0.5G （通信库NCCL）

# profiling (peak) 所谓峰值，就是根据每次调度的最大token数，batch的最大req数，塞满。就比如说，构造一个超长的prefill，然后进行一次计算，这样可以把输入输出缓冲区拉到最大，attention算子也需要额外显存
	1. 1G（其他进程）
	2. 4G（模型2G，输入输出缓冲区2G）
	3. 1G（NCCL0.5G， attention backends里面比如中间量也需要缓冲区0.5G）
	   
# profile结束
	1. 1G
	2. 3G（模型2G + 被gc回收过的剩余激活输入输出缓冲张量1G）
	3. 1G（一样）

```

这里要先提一下下面几个点：
- **输入输出缓冲区的管理**：
	- 在kuipa项目里面，我们测试都是输入一个req，prefill阶段需要Nxdim的输入输出缓冲区，decode阶段就需要1个张量输入输出缓冲区。所以我们的选择是直接提前申请输入输出缓冲区。
	- 但是在vllm里面，每次到一张显卡的batch是不定长的。所以在不同情况有不同方法：
		- 正常推理过程：
			- 主要靠 PyTorch CUDA caching allocator（pytorch的tensor变量的内存会有专门的显存池）
			- ![148](../images/Pasted%20image%2020260815211417.png)
		- profile peak期间：
			- 他就是通过构造dummy 撑满一个batch, 然后profile推理，触发pytorch cuda allocator pool的机制来自动创建中间的激活tensor, 看看他最高能触发多少，这个就是我们的峰值显存。

- attention backends的中间变量的显存占用
	- ![215](../images/Pasted%20image%2020260815211914.png)


#### SchedulerOutput
```python
class SchedulerOutput:
# 基础属性
	scheduled_new_reqs : list[NewRequestsData] # 本轮调度的新req名单(pro)
	scheduled_cached_reqs : CachedRequestData # 本轮调度的旧req名单
	
	# 【token id (投机解码草稿token)】
	scheduled_spec_decode_tokens: dict[str, list[int]] # 每个req的投机解码的草稿token列表
	num_invalid_spec_tokens: dict[str, int] # 每个req的被拒绝的草稿token列表
	
	# 【token数统计信息】
	num_scheduled_tokens : dict[str, int] # 本轮req-各自token数的列表
	## 杂项统计
	num_common_prefix_blocks: list[int] # 本轮batch的公共前缀，用于cascade attention
	total_num_scheduled_tokens : int # 本轮总共要计算的tokens数
	
	
	# --------------------------------------------------------------------------
	
	
	finished_req_ids: set[str] # 上一轮已经完成的req
	preempted_req_ids: set[str] # 本轮被抢占，赶回waiting队列的req的集合
	new_block_ids_to_zero: list[int] # 本轮新分配，需要清零的block
	
	
# 每个新请求类
class NewRequestsData:
	req_id # 请求ID
	sampling_params : SamplingParams # 这个req的采样参数
	
	# 【token ids 信息】
	prompt_token_ids : list[int] # prompt的tokenids
	
	# 【req的token数统计信息】
	num_computed_tokens : int # 已经计算过的token数
	
	# 【req 的 单独block id信息】
	block_ids : tuple[list[int],...] # 该req占用的kv cache block id
	
	
	

# 继续req们的增量信息
class CacheRequestData:
	req_ids : list[str] # 本轮被增量调度的req的id集合
	resumed_req_ids: set[str] # 本轮被恢复过来运行的请求
	
	# 【token 数统计信息】
	num_computed_tokens: list[int]
	num_output_tokens: list[int]
	
	# 【req的 单block_id信息】
	new_block_ids: list[tuple[list[int], ...]
```





#### Request
我们再来看一下一个请求类的内部有哪些属性，帮助我们理解
```python
class Request{
# 基础属性
	request_id      # 请求ID
	client_index    # 引擎前端的索引
	priority  # req的优先级
	sampling_params # 采样参数
	arrival_time  # 请求的到达时间
	status    # 请求的状态 = RequestStatus.WAITTING
	events : list[EngineCoreEvent] # 该请求的引擎事件列表
	session_id # 会话ID，关联同一会话的多个req
	max_tokens = sampling_params.max_tokens # 最大输出token数
	
	
	
	#【token ids相关】
	prompt_token_ids # prompt的token id列表
	spec_token_ids # 投机解码的草稿token id 列表
	_output_token_ids # decode出来的token id列表
	output_token_ids # 只读的输出token id列表
	_all_token_ids # prompt + decode 的全量tokenid列表
	all_token_ids # 只读的prompt + decode 的token id列表
	
	
	#【token 数统计信息】
	num_prompt_tokens # prompt的token数
	num_in_flight_tokens # 在途中处理的token数，在异步调度
	num_computed_tokens # 已经计算出kvcache 的token 数
	
	
	
	# 【token_id - hash 信息】
	# 用来更新链式hash，以及维护一个req的链式块hash表
	block_hashes: list[BlockHash] 
			# 链式内容hash，req负责维护内容-链式hash， 
			#kvcachemanager负责维护  链式hash->block
	_block_hasher # 一个块hash的获取器吧
	update_block_hashes() # 计算一个块的链式hash
	
	
	# ---------------------------------------------------------
	
	
	
	
	
		
	# 调度状态相关，局部属性，不是跨模态用的
	is_prefill_chunk = False # True表示该req处于非最后一块chunked的prefil阶段被调度
	num_preemptions = 0 # 被调度器抢占的次数
	skip_reading_prefix_cache # flag, 是否跳过读取prefix cache
}
```
所以，一个req发过来，kvcachemanager, worker接受这些req，天然就知道这个req，他prompt, output的tokenids, 他目前已经计算了的token到哪里

但是注意，每个req内部，<mark style="background:#fff88f">并不知道这个req占用了哪些物理blockID</mark> , block_hashes里面存放的是内容hash, 它回答的问题是：**「这 16 个 token 的内容是什么？」**，而不是**「它们放在 GPU 显存的第几个 block 里？」**。

同一个内容（比如 100 个请求都是 `"The quick brown fox..."` 开头），它们的 `block_hashes` 全一样，但它们可能占用**不同的物理 block_id**（或者通过前缀缓存复用同一个 block_id）


那「占用了哪些 block」记在哪？

记在 **`KVCacheManager` 的 coordinator 里**，不是 `request` 上。你要查某个 req 现在占哪些 block_id，是这么调：

[kv_cache_manager.py:815](vscode-webview://0v6anhu7rvonmrg5eum0t53r31phukqu6outl7a0k1sdqa1epd0b/vllm/v1/core/kv_cache_manager.py#L815)：

```python
def get_block_ids(self, request_id: str) -> tuple[list[int], ...]:
    return self.get_blocks(request_id).get_block_ids()
```

这就是调度器里 `self.kv_cache_manager.get_block_ids(rid)` 那套调用（[scheduler.py:3729](vscode-webview://0v6anhu7rvonmrg5eum0t53r31phukqu6outl7a0k1sdqa1epd0b/vllm/v1/core/sched/scheduler.py#L3729) 等），返回的是**真实的 `block_id` 列表**。


> <mark style="background:#fff88f">req里面的这个就是存放的内容hash，里面包含了链式逻辑，然后kvcache里面存放的是hash->block的映射逻辑，所以中间加了一层hash, 所以两个结合，就可以支持prefix cache的快速索引了</mark>







### 3.2_执行器exculator

#### executor - workers架构

![](../images/Pasted%20image%2020260811151302.png)


简单理解就是workers就是一张卡上的干活的进程，就是我们kuipa的demo层的逻辑


单 GPU 场景下 Worker 就是**一个完整的模型推理单元**。

```
EngineCore
  ├── scheduler: SchedulerInterface     ← CPU: 选请求、分 token
  ├── model_executor: Executor          ← 抽象层
  │       └── Worker (GPU)              ← 持有完整模型，跑完整前向
  │             ├── model: LlamaForCausalLM   (32 层 Transformer)
  │             ├── KV cache tensors          (预分配的 K/V 显存)
  │             └── execute_model()
  │                   ├── prepare_input()     ← SchedulerOutput → PyTorch tensor
  │                   ├── model.forward()     ← 完整 32 层前向
  │                   └── sample()            ← logits → 采样下一个 token
  └── ZMQ / IO 线程
```

多 GPU 时每个 GPU 上各一个 Worker，通过 TP（层内切分）或 PP（层间切分）协作。但对你来说，`Worker = 持有模型 → 接收 SchedulerOutput → 跑前向 → 返回结果`，就是这四件事。

![](../images/Pasted%20image%2020260809233611.png)

Worker 绑定一个 GPU 设备，持有该 GPU 上的模型分片和 KV cache 显存。Scheduler 只有一个跑在 CPU 上，给所有 Worker 安排工作。

![](../images/Pasted%20image%2020260809233805.png)

Worker 每步收到一个完整的 batch——里面同时有 prefill 和 decode——跑一次 `model.forward()` 把所有请求一起算完。没有 "盯着请求 A 直到跑完" 这回事，每步的 batch 都可能不一样。这就是 continuous batching：Worker 每步处理的是一个**请求 mix**，而不是某个请求的完整生命周期。



---

执行器executor的类型：

![](../images/Pasted%20image%2020260811151628.png)

![](../images/Pasted%20image%2020260812145049.png)
> 所以我的理解没有错误，MultiprocExecutor就是单机多卡的执行器



#### MessageQueue
这是一个进程间通信的封装层，内部封装了两种进程间通信方式：
- 共享内存
- ZMQ.PUB,SUB

这样对于executor, worker之间的通信来说，就直接把batch请求任务，往这个队列里面丢，就无需关系这个通信方式，包的大小。这个通信层内部，自己会根据这个batch包的大小，选择合适的底层方案。

还有一个设计点，这个MessageQueue的设计，上面说的是针对Message, 这里的Queue, 实际上是说，
MessageQueue其实是一个环形缓冲区，

所以这个**MessageQueue**是一个封装了共享内存+zmq.PUB,SUB 的 **有多个batch槽位的环形缓冲区**，专门为了应对**异步调度的多轮batch**。如果是同步呢？也能用，不过就直接发一个batch, 消费一个batch了

同步调度时 ring buffer 大部分槽位空着而已，队列入队一个、出队一个、再入队下一个，退化成单槽行为。但代码不用改——抽象层让你不需要关心上层调度是同步还是异步，只管往里丢、从里面取



#### worker进程的启动
- WorkerProc.make_worker_process， 工厂函数
	- WorkerProc.worker_main 工厂函数
		- WorkerProc.__init__
		- WorkerProc.worker_busy_loop()
			- 接收到RPC的func，执行任务调用


```
WorkerProc.__init__()                          # 进程入口
  │
  ├─ wrapper = WorkerWrapperBase(...)          # ① 创建适配层
  │
  ├─ wrapper.init_worker(all_kwargs)           # ② 适配层内部:
  │   └─ self.worker = Worker(...)             #    创建 GPU Worker (一开始就是 Worker)
  │       ↑ 存为 WorkerWrapperBase.worker
  │
  ├─ self.worker = wrapper                    # WorkerProc.worker → WorkerWrapperBase
  │
  ├─ self.worker.init_device()                # ③ WorkerWrapperBase.init_device()
  │   └─ self.worker.init_device()            #    → Worker.init_device()
  │       └─ self.model_runner = GPUModelRunner(...)  # 创建 ModelRunner
  │
  └─ self.worker.load_model()                 # ④ 加载模型权重
      └─ self.worker.load_model()             #    → Worker.load_model()
```

所以三个对象的创建顺序是 **`Worker` → `WorkerWrapperBase` → `WorkerProc`**，而 `GPUModelRunner` 是 `init_device` 时才创建的。`Worker` 类型从一开始就确定了，不是 `init_device` 时切换的。



> 所以，WorkerWrapperBase是充当WorkerProc和Worker的中间层的，WorkerProc收到的RPC任务，WorkerWrapperBase这个装饰器实例负责来解析这个RPC，然后调用Worker的方法

就是这个关系。但它的角色不是"装饰器"，更准确的叫法是 **适配层 + 拦截器**。

它拦截所有 RPC 调用，做两件事：

1. **多模态注入**（有 work 时）— 在 `execute_model` 之前，把预处理好的图片特征注入 `scheduler_output`
2. **透传**（没 work 时）— 直接把调用转发给 Worker


多模态部分我们先不关心，在透传的时候，就是转发RPC给Worker实例。



#### 总结：从EngineCoreProc类的构造 - Worker类的构造时间线梳理

这边我先简单总结一下vllm里面类设计的习惯
- 新的进程，启动，一般使用xxxProc类的工厂函数
	- 构造xxxProc类实例，进入xxxProc.init(), 这个类一般用来作为进程间通信层，来实现握手连接等，或者增加一些线程来监听输入输出等。
		- xxxProc.init()中，才开始构建真正的xxx实例
			- xxx.init()，
				- xxx可能是一个xxxWrapper装饰器
					- 他的内部包含子类，这个装饰器的作用是一个适配器，用来选择合适的子类
				- xxx可能是一个子类
					- 如果这是一个子类，也有一种可能，这个子类只是实现一些特殊的对外接口，真正通用的干活核心是他的基类.init出来的基类实例。

所以，这些vllm里面有很多这种乱七八糟的类包含，继承的设计，简单总结下来有这几种：
1. xxxProc()
	1. 进程启动调用它的工厂函数来构造这个对象，来表示这个进程，已经这个进程的循环逻辑
2. xxxWrapper()
	1. 这个一般作为一个适配器的中间层，他的属性包含了我们需要的类实例，用来选择符合我们的类来构造
3. xxxBase()
	1. 这个类一般是用来作为我们真正需要的实例，有两种设计
		1. 真的就是一个抽象的基类，比如定义一些基本的接口
		2. 作为核心功能的实现，子类仅仅只是包装点接口设置。

---

下面，我来按照主体的时间线，来进行梳理，从EngineCoreProc这个引擎后端进程开始，一直到Worker进程进入循环等待指令。详细梳理一下各个类实例的构建实际，已经每个进程是如何进入循环状态的。
之后，我将开始手写完成到Worker启动并进入循环的框架，之后我们就会进入ModelRunner，来真正接触模型。



**【引擎后端进程 EngineCoreProc 】**
    - (构造)CoreEngineProcManager.init
        - ....
        - 启动EngineCoreProc.run_engine_core()进程
            -(构造)EngineCoreProc（EngineCore）.init()
                - (创建)输入请求队列self.input_queue，输出请求队列self.output_queue
                -（保存）引擎编号 self.engine_index = Dealer套接字identity
                - (过程) 和引擎前端的握手
                    - (保存) self.address = address 记录前端的联系方式
                    - (构造)EngineCore.init()
                        - (构造执行器)：self.model_executor = MultiprocExecutor.init()
                            - (构造) Executor.init()
                                - (调用) 调用子类的_init_executor()
                            - (调用) _init_executor()
                                - (计算) world_size = tp x pp x pcp
                                - (调用) 设置worker的torch线程环境
                                - (计算) MultiprocExecutor 的 zmq 的 URL
                                - (构造) self.rpc_broadcast_mq : MessageQueue
                                - (计算) 连接执行器的信息：scheduler_output_handle
                                - (while)
                                    - (计算) 每个worker的rank
                                    - (调用) WorkerProc.make_worker_process()
                                        - (构造) 管道1:ready;  管道2:death 
                                        - (启动新进程，WorkerProc.worker_main)              >>>>>【Worker # N】
                                    - (保存) 把 unready_worker_handle 加入 unready_workers列表
                                - (阻塞调用)self.workers : List[ WorkerProcHandle ]= WorkerProc.wait_for_ready(unready_workers) 等待所有Worker进程管道发生READY
                                - (创建) self.response_mqs 收集每一个worker的回复队列
                                - (调用) self.rpc_broadcast_mq.wait_until_ready() 验证发送通道的通路
                                - (调用) response_mq.wait_until_ready() 验证接受通道的通路
                                - (创建) future = deque[FutureWrapper] 创建异步RPC的结果future FIFO队列
                                - (调用) success = True， 执行器启动成功
                        - self.available_gpu_memory_for_kv_cache 记录kvcache的显存容量
                        - 【worker初始化第三步】self._initialize_kv_caches(vllm_config), （EngineCore让执行器RPC）让执行器RPC调用Worker初始化kvcache
                        - (构造) structured_output_manager = StructuredOutputManager.init()
                        - (构造调度器) self.scheduler = Scheduler.init()
                            - (保存) self.structured_output_manager = structured_output_manager
                            - (保存) self.max_num_running_reqs 每轮最大请求数
                            - (保存) self.max_num_scheduled_tokens 每轮最大token数
                            - (保存) self.max_model_len 模型kvcache上下文窗口最大长度
                            - (保存) self.requests : dict 请求集合
                            - (保存) self.policy 调度策略
                            - (创建) self.waiting, self.skipped_waiting, self.running 
                            - (创建) self.finished_req_ids, 上一轮完成的req集合
                            - (创建) self.reset_preempted_req_ids, 本轮被抢占的req 集合
                            - (构造) self.kv_cache_manager = KVCacheManager() 显存块管理器
                            - (调用) self.connector, PD 分离用的
                            - (保存) self.current_step 调度步数计数器
                            - (保存) self._pause_state 调度器状态
                            - (保存) self._inflight_prefills 正在prefill的req的集合
                        - (构造)(远程kv) kv_connector, PD分离的通信管道
                        - (调用) 指定引擎self.step_fn() = self.step()
                - (线程1)：输入线程process_input_sockets
                - (线程2)：输出线程process_output_sockets
            - (调用)EngineCoreProc.run_busy_loop()
                - 【loop】
                    - (调用) self._process_input_queue() 收集引擎后端的输入线程收集的ZMQ的请求，放入调度器队列
                    - (调用) self._process_engine_step() 引擎后端执行一步
                        - (调用) outputs, model_executed = self.step_fn()，执行指定的方法
                        - (调用) 把outputs 放入output_queue



**【Worker - # N 进程-WorkerProc】**
    - WorkerProc.worker_main() 工厂函数
        - (保存) ready_writer, death_pipe （与引擎后端进程连接 的 管道）
        - (构造) worker = WorkerProc.init()
            - (保存) self.rank = rank
            - (构造) wrapper = WorkerWrapperBase.init()
                - (声明) self.worker是WorkerBase类
            - (调用) wrapper.init_worker()
                - (构造) self.worker = worker_class()(子类) = Worker.init()
                    - (构造) WorkerBase.init()
                        - (声明) 定义抽象接口：
                            - 各种配置
                            - self.device : torch.device
                            - self.model_runner : nn.Module
                            - self.rank = rank
                            - self.distributed_init_method (执行器的联系方式)
                    - (保存) 使用的model_runner 版本
                        - self.profiler : 测定初始参数
                        - self.profiler_config : 初始测定配置
            - (保存) self.worker = wrapper
            - (调用) self.worker.init_device()
                - (转发) self.worker.init_device()
                    - 【worker初始化第一步】初始化设备 + 分布式上下文通信组 + model_runner(含InputBatch)
                        - (保存) parallel_config = 并行化参数
                        - (计算) tp_pp_world_size 计算所需GPU个数
                        - (调用) 发布worker的逻辑rank id ~ GPU 映射表
                        - (调用) 设置pytorch的device为对应的GPU
                        - (调用) 拉起NCCL通信网络，做TP，PP，PCP，DP、EP、EPLB 组（EP/EPLB 仅 MoE 模型）分组切分
                        - (调用) 设置随机种子
                        - (调用) gc.collect()，CPU侧清理垃圾变量内存
                        - (调用) torch.accelerator.empty_cache(), GPU侧清理垃圾变量显存
                        - (调用) 测量实际可以显存 vs 用户预先设置请求的内存空间
                        - (构造) 算子缓冲区的scratch草稿显存控制器 = init_workspace_manager()
                            - 简单，待定
                        - (构造) self.model_runner = GPUModelRunnerV1.init()
                            - ...
            - (调用) self.worker.load_model()
                - (转发) 为空，转发Worker
                    - 【worker初始化第二步】构造模型结构 + 加载权重(按 TP/PP 切分与设备放置) + model.eval() + 可选 graph包装
                        - (调用) 把vllm.config设为当前的vllm_config
                        - (调用) 调整cuda分配器的切片大小为20MB，用于分配权重显存
                        - (调用)self.model_runner.load_model() 加载权重
                            - (调用)实际测试设备内存
                            - (调用) model_loader = get_model_loader() 获取模型加载器
                            - (调用) self.model = model_loader.load_model() 加载模型
                            - (调用) 加载lora模型
                            - (调用) 加载草稿模型
                            - (调用) (可选) 包装一层cuda graph
        - (调用) ready_writer 发送 ready信号 + worker_response_mq的连接信息
        - (调用) rpc_broadcast_mq.wait_until_ready() 验证我们发送通路的正常，作为reader接收方
        - (调用) worker_response_mq.wait_until_ready() 验证我们回复通路的正常，作为writer发送方
        - (调用) worker.worker_busy_loop() Worker进程的RPC服务循环
            - 【loop】
                - (保存) rpc_broadcast_mq.dequeue，得到method + args + output_rank
                - (调用) 发给worker，调用method
                    - WorkerWrapperBase适配器命中实现
                    - WorkerWrapperBase适配器未命中
                        - Worker.func实现


WorkerProc
    - .worker : WorkerWrapperBase （适配器转发层）
        - .worker : Worker
          - .device : torch.device
          - .model_runner : nn.Module
            - .model
          - .rank = rank
          - .distributed_init_method (执行器的联系方式)
          - .profiler
          - .profiler_config














































#### model_runner
##### xxx_config
```python
class VllmConfig:
	model_config: ModelConfig # 模型配置
	cache_config: CacheConfig # kvcache的形状配置
	parallel_config: ParallelConfig # 并行配置
	scheduler_config: SchedulerConfig # 调度器配置
	device_cofnig:DeviceConfig # 计算设备配置
	load_config # 加载配置
	offload_config # 模型权重卸载配置
	attention_cofnig # 注意力配置
	kernel_config # 内核配置
	speculative_config #投机解码配置
	quant_config # 量化配置
	profiler_config # 测量配置
	kv_transfer_config # pd分离的kv转移器配置
	

class ModelConfig:
	model: str # hf的模型名称/路径
	model_weights: str # 原始模型权重地址
	runner # model runner 的类型
	convert # 使用adapters来转换模型，比如转换文本生成模型->池化任务
	tokenizer # hf的分词器的名称/地址
	tokenizer_mode : TokenizerMode #分词器的类型
		'''
		分词器是**第三方库**，vLLM 不自己实现 tokenization，只是加载/包装。

		具体是哪个，由 `tokenizer_mode` 决定：
		
		- **`hf` / `auto`**：Hugging Face 的 `transformers.AutoTokenizer`，底层是 HF 的 Rust 库 `tokenizers`（fast tokenizer）。
		- **`mistral`**：`mistral_common`（Mistral 自家的库）。
		- **`deepseek_v32/v4`**：DeepSeek 自家的 tokenizer。
		- **`cohere`**：`cohere_melody` 库。
		
		`tokenizer` 字段只是**指定从哪加载**（模型名或本地路径），vLLM 据此去 Hugging Face 仓库 / 本地目录里找 tokenizer 配置文件。
		
		所以 tokenizer 是外部依赖，vLLM 调用它做 text ↔ token id 的转换（编码 prompt、解码输出 token），本身只负责调度和管理。
		'''
	dtype # 模型权重/激活值的数据类型
	seed # 随机种子，我们必须使用全局一样的随机种子，不然TP会导致不一致的采样结果
	
	spec_target_max_model_len # 投机解码的最大长度
	quantization # 量化方式
	quantization_config # 量化配置
	
	hf_config # 模型的huggingface配置
	hf_config_path # 配置地址，未指定就直接用模型的目录
	
	
	
	
class LoadConfig:
	load_format: str # 模型权重的加载格式
		'''
		auto: 默认用safetensors格式加载权重 
		safetensors:
		instanttensor:
		npcache
		dummy: # 用随机值初始化权重，主要用来profiling
		'''
	download_dir:str # 下载、加载目录，默认是huggingface的缓存目录
	safetensors_load_strategy # 加载safetensors权重的策略，
		'''
		默认：使用mmap懒加载
		lazy: 权重被mmap，按需加载
		eager: 加载前，把所有权重读到ddr，NFS推荐
		prefetch: checkpoint 文件被读入OS页缓存，在加载之前，网络，高延迟存储适用
		torchao: 读完重建为 **torchao 量化张量**
		'''
	safetensors_prefetch_num_threads # 张量预取线程数
		
	device # 把模型权重加载到哪个设备上，默认device_config.device
	
	
class CacheConfig:
	block_size #（默认 16）— 一个 block 装多少 token
	num_gpu_blocks / num_cpu_blocks # profiling 后回填的实际块数（用户不设，init=False）
	num_gpu_blocks_override # 手动覆盖 profiling 算出的块数
	gpu_memory_utilization # （默认 0.92）— 显存利用率
	kv_cache_memory_bytes #手动指定 KV cache 字节数（覆盖上面的利用率）
	
	cache_dtype #  KV cache 存储 dtype（auto/fp8/bf16…）
	kv_cache_dtype_skip_layers # 跳过量化的层

	enable_prefix_caching # prefix_match_unit
	prefix_caching_hash_algo #哈希算法（sha256/xxhash…）
```
![](../images/Pasted%20image%2020260816150138.png)
![](../images/Pasted%20image%2020260816150321.png)



##### GPUModelRunner
下面来整理一下GPUModelRunner类的基本属性
```python
class GPUModelRunner:
# 基础属性
	# 配置信息
	vllm_config #推理框架配置
	model_config #运行模型的信息
	cache_config #kvcache规格配置
	offload_config #模型卸载器配置
	load_config # 模型加载器配置
	parallel_config # 并行加速配置
	scheduler_config # 调度器配置
	speculative_config # 投机解码配置
	
	device #运行设备
	dtype  #数据运行精度
	
	
	# 执行信息
	max_num_tokens #一个batch里面，最大tokens计算数
	max_num_reqs #一个batch里req的最大数量
	num_query_heads #每个req的query部分的头数 = 注意力头数
	inputs_embeds_size  # ?
	
	
	# 采样器
	self.sampler # 采样器
	
	
	# kvcache相关属性
	self.kv_caches : list[torch.Tensor] # 各layer的kvcache tensor 列表
	self.attn_groups : list[list[AttentionGroup]] #[kv_cache_group_id][attn_backend_group]
	
	
	# 请求状态
	self.requests : dict[req_name, CacheRequestState] #历史req的信息
	self.input_batch : InputBatch # 输入批实例




	# 单轮req缓冲区
	'''
	这一块的缓冲区的申请，主要用于存放，从本轮batch的调度任务中提取的有用信息，以及和上一次的batch有什么差异。
	'''
	self.input_ids # gpu-cpu双缓冲buffer, 长度=单batch最大可计算tokens数，新计算token的缓冲区
	self.req_indices # gpu-cpu双缓冲buffer,长度=单batch最大可计算tokens数，token->req_id的映射表
	
	self.positions # gpu侧张量，长度=单batch最大可计算tokens数，每个token在req中的pos
	
	
	
	self.query_start_loc # gpu-cpu双缓冲buffer, 长度=最大请求数+1，每个req的开始计算的pos
	self.prev_num_draft_tokens # gpu-cpu双缓冲buffer, 长度=最大请求数，每个req的草稿token数
	self.prev_positions # gpu-cpu双缓冲buffer, 长度=最大请求数，前后两次batch的req的顺序变动映射
	self.num_scheduled_tokens # gpu-cpu双缓冲区，长度=最大请求数，每个请求本次要计算的token数
	
	self.seq_lens # gpu 侧张量，长度=最大请求数， 用来记录每个req的长度，每个req的已有kv的token长度 + 本轮即将计算的token的序列长度
	self.num_computed_tokens # gpu侧张量，长度=最大请求数，每个req已有kv的token长度。
	
```

下面来先看一下，我们model_runner保存的每一个request的历史类CachedRequestState:
里面有哪些内容
```python
class CachedRequestState:
# 基础属性
	req_id : str  # 请求id
	prompt_token_ids : list[int] # prompt的token id列表
	sampling_params : SamplingParams # 采样参数
	generator : torch.Generator # PyTorch 随机数生成器, 给采样器从打分里面采样用的
	
	block_ids : tuple[list[int], list[int], ...] # 该req的各group的kv block的列表
	num_computed_tokens : int # 已经计算的token数
	output_tokens_ids : list[int] # decode输出的token id列表
```




###### InputBatch

下面我们再来看一下InputBatch类实例里面有哪些重要的属性
```python
class InputBatch:
# 基础属性

	# 基础配置
	max_num_reqs # 一个batch的最大req数
	max_model_len # 每个req的kvcache最大上下文长度
	max_num_batched_tokens  # 每个batch中本次最大计算token数
	device     # 设备
	vocab_size # 词袋大小
	
	

	# 【batch内-req_id 的双向索引表】
	_req_ids : list[str] # 一个batch里面的req id 列表(正向batch内索引)
	req_id_to_index : dict[req_id, int] 
				#req_id → 它在当前 batch 里的位置索引（反向batch内索引）
	
	
	
	
	
	# 【token id 信息】
		# 【每个req的完整token ids序列】的大缓冲区
	token_ids_cpu_tensor # 张量（req_id, max_model_len），
						# CPU 侧按「[req, 序列长度]」二维存每个请求完整 token 序列的大缓冲
	token_ids_cpu # token_ids_cpu_tensor的数组格式
	is_token_ids_tensor # 每个位置是不是「真 token id」的布尔掩码，
						# 形状和 `token_ids_cpu_tensor` 一样
	req_prompt_embeds : dict[req_id, Tensor] # 直接以prompt的embedding向量形式的输入
	req_output_token_ids # 每个req已生成的output token id序列
	
	
	
	
	# 【token数统计信息】
		# 【每个req的各种数量统计】
	num_tokens_no_spec # (req_id,), 每个req不含投机解码token数
					# 序列里 真实存在 的 token 总数（prompt + 接受的输出），「序列有多长」	
	num_prompt_tokens # (req_id,) 每个req的prompt长度
	num_computed_tokens_cpu # (req_id, ) 每个req已有kvcache的token数，决定这次从哪里开始
					# 模型前向已算的 token 数（KV 进度），「算到哪了」
	
			'''
			num_tokens, 和 num_computed_tokens的区别：
				num_tokens是说目前req里已经知道这个token id的数量，不管算没算kv
							这个里面包含发过来的prefill阶段的prompt的req;
							投机解码时候的，草稿也被算到这个num_tokens里面了。
				num_computed_tokens 是说，这个token id已经存在的里面，已经有kvcache的。
			'''
	
	
	
	
	# 【每个req 的 单block_id 信息 +  block_id - 物理kv地址 信息（现用现算）】
		# 【block - 物理地址】页表
	block_table = MultiGroupBlockTable() # block table，每个req的kvcache blodk id映射，
									# 前向推理时，attention靠它把逻辑块id转成物理kv地址。
	'''
			    列 = 块位置 0   1   2   3  ...
		行 req0 [ block_id 12, 7, 33, 0, ... ]   ← 这就是 req0 的 block id 链
		行 req1 [ block_id 5, 18, 0, 0, ... ]


-----------------------------------------------------------------------------
	第二层要修正：slot_mapping 管「写」，注意力「读」不经过它
		KV cache 有两条路径，都要「block id → 物理地址」，但方式不同：

	1. 写路径（当前 token 的 K/V 存进去）
		- compute_slot_mapping（GPU kernel）把 block_table + block_size 算成 slot_mapping（每 token 一个写地址）
		- 喂给 `concat_and_cache` kernel，把当前 token 的 K/V 写进对应物理槽

	2. 读路径（注意力读历史 KV）
		- PagedAttention kernel 直接用 block_table + seq_lens，在 kernel 内部按块迭代，每块现场算 `block_id × block_size` 得到物理偏移
		- 不经过 slot_mapping
		  
--------------------------------------------------------------------------
		  
		  
		  
	compute_slot_mapping 的作用 = 并行把「每 token 属于哪个 block、块内哪个位置」解算成「每 token 的物理 slot 地址」

		slot_mapping[token_i] = block_id × block_size + 块内偏移
	slot_mapping 是个一维 int64 张量，长度 = max_num_batched_tokens（每 token 一个，不是每 req、也不是每 block）。每个元素 = 该 token 的 KV 要写入的物理 slot 地址
	'''
	
	# -------------------------------------------------------------------
	
	# 采样策略
	temperature # （req_id, ），每个req的采样温度
	greedy_reqs : set[req_id]#  贪心采样的req集合
	random_reqs : set[req_id] # 随机采样的req集合
	
	top_p # 核采样，每个req一个
	top_k # top_k采样
	
	frequency_penalties # 频率惩罚
	presence_penalties # 存在惩罚
	repetition_penalities # 重复惩罚
	
	
	
	
	
	# 投机解码
	num_accepted_tokens_cpu # 各req 在本步 被接受的 草稿token数，初始=1，不使用投机解码就是1token
	
	
	# 每步状态
	self.batch_update_builder = BatchUpdateBuilder()
	# 每步batch状态变化的内部表示，用于重排持久batch 和 生成 logitsprocs的状态更新。每步重置
	
	
	
	# 限制词
	has_allowed_token_ids  # 限制了 “只允许输出某些token” 的 req集合
	allowed_token_ids_mask # 允许token的掩码矩阵，允许为false
	bad_words_token_ids #req_id -> 禁用词列表
	
	
	
	# 生成相关杂项
	
	spec_token_ids # 每个req上一轮的草稿token列表
	logitsprocs # 自定义的logits处理器集合（打分处理器集合）
	sampling_metadata #采样元数据（打包所有采样参数，生成器，打分处理器，喂给采样器），每次batch组成变化时重组
	
	
	prev_req_id_to_index # 上一批的req_id -> 位置映射
	
	sampled_token_ids_cpu # 上一批真实采样token的CPU缓存，供当前采样参数需要（如penalty）时更新output_token_ids
	
	
	### logprob = log probability 对数概率。即模型给 某个token 打的对数概率值
	# logits(原始分数)-》 softmax->概率p->取对数-》logprob
```

> InputBatch实例，<mark style="background:#fff88f">维护一个 【持久化的 在途请求 状态】</mark>，跨step存活
> 
> 这个实例，是model_runner的一个成员属性，核心是用【槽位req_index】组织一批【当前正在这个GPU worker上跑的请求】。槽位状态跨多步保留
> ![](../images/Pasted%20image%2020260817212901.png)
> 因此，每步只做增量更新，不重建
> ![](../images/Pasted%20image%2020260817213003.png)

所以，实际的数据流程是这样的：
1. SchedulerOutput (调度器发过来的req batch)
2. -> InputBatch实例， `_update_states` 增量更新 
	1. 加新的req, 删除完成的，重排、压缩槽位
3. -> `_preprocess` 从InputBatch 持久化状态中，填写我们的当前步的buffer
	1. input_ids, positions, seq_lens, query_start_loc, slot_mapping
4. -> `_model_forward` + `_sample` 前向 + 采样
5. -> `_bookkeeping_sync` 把结果写会InputBatch
	1. output_token_ids 追加，num_computed_tokens + 1, generator 状态更新
6. 下一轮 SchedulerOutput



下面我整理了一下，我们执行一个req的主要的信息，以及各个模块持有这些信息关系图：

首先总结一下，一个req，到底有哪些信息：
- <mark style="background:#d3f8b6">token ids 信息</mark>
	- 这个是token id列表
- <mark style="background:#d3f8b6">token 数 统计信息</mark>
	- num_tokens, num_computed_tokens, num_prompt_tokens
- <mark style="background:#d3f8b6">token_id - 内容hash链</mark>
- <mark style="background:#d3f8b6">内容hash链 - block_id 信息</mark>
- ~~block_id信息 - 物理kv地址~~
- <mark style="background:#d3f8b6">单block_id信息</mark>
	- 物理kv地址，可以通过block_id的值，就可以推算出来了
		- 写kvcache, 通过compute_slot_mapping， 来计算每个token的物理地址
		- 读kvcache，直接在注意力算子里面，计算每个需要的seq_len个token个物理地址。

然后我梳理了一下各个类，看看里面的主要的属性，搞清楚各个模块持有的信息，就可以搞清楚各个模块的功能了：
- <mark style="background:#fff88f">Request实例</mark>
	- token ids信息
	- token 数统计信息
	- token_id - 内容hash链

> Request实例，经过kvcachemanager, 以及scheduler里的方法，提取出增量信息


- <mark style="background:#fff88f">NewRequestsData实例</mark>
	- token ids 信息
	- token数统计信息
	- req 的 单block_id 信息 （prompt）
- <mark style="background:#fff88f">CacheRequestData</mark>
	- token 数统计信息
	- req 的 单block_id 信息 (decode)

整个KVCacheManger, KVCacheCoordinator, 里面，都只是关于维护block pool的数据结构。

相关的在KVCacheBlock这个一个块的类实例里面

- <mark style="background:#fff88f">KVCacheBlock实例</mark>
	- 内容hash链 - block_id 信息

所以vllm把hash链做在block内，所以一个request只要持有block_id即可。


下面看一下InputBatch里面
- <mark style="background:#fff88f">InputBatch实例</mark>
	- token ids 信息
	- token 数统计信息
	- req的单block_id信息


---


<mark style="background:#d2cbff">所以至此，一个req的一开始,只有3个核心信息：</mark>
- <mark style="background:#d3f8b6">token_ids 信息</mark>
- <mark style="background:#d3f8b6">tokens 数统计信息</mark>
- <mark style="background:#d3f8b6">block_ids 信息</mark>
	- hash写在KVCacheBlock块里面，所以和block_id匹配
	- block_id的值和物理地址绑定

每个Request实例，构建的时候，拥有前两个+hash
- 经过KVCacheManager， 把hash信息换成了block_id信息

**所以NewRequestsData, CacheRequestsData实例里面，已经拥有了这三个核心增量信息**。

然后打包成SchedulerOutput实例发出去，给InputBatch实例，进行**更新目前信息，合并增量信息**

最后InputBatch实例，留下来的就是完整的当前GPU要处理的：
- token_ids 信息 （完整）
- tokens 数统计信息 （完整）
- block_ids 信息 （完整）
> 增加请求，被抢占了，执行完了，InputBatch就移除请求



![](../images/Pasted%20image%2020260817222257.png)

















#### 总结：模型的构建和加载权重，初始化kvcache 流程梳理

这边来梳理一下worker的主要工作：
- 构造模型加载器
- 构造模型实例，加载模型权重
- profiling 测试kvcache的实际可用显存
- 初始化kvcache显存张量

下面我将通过顺序一步一步，从worker的构造开始


【EngineCore进程】
- EngineCoreProc.run_engine_core()
	- (构造)EngineCoreProc.init()，<mark style="background:#b1ffff">引擎后端的功能 + 通信</mark>
		- (创建) EngineCoreProc.input_queue
		- (创建) EngineCoreProc.output_queue
		- (保存) EngineCoreProc.engine_index
		- (with) 与前端握手通信
			- (构造) 基类 EngineCore.init， <mark style="background:#affad1">构造引擎后端的功能实例</mark>
				- (构造) EngineCore.self.model_executor = MultiprocExecutor.init()， <mark style="background:#fff88f">构造执行器</mark>
					- (创建) MultiprocExecutor.rpc_broadcast_mq()，发送通道
					- (while)
						- (调用) WorkerProc.make_worker_process, 创建，启动worker进程
							- (创造) ready 管道
							- (创造) death管道
							- (创建) 【<mark style="background:#fdbfff">Worker进程】》》》》》 WorkerProc.worker_main()</mark>
					- (调用) <font color="#ffc000">MultiprocExecutor.self.workers</font> = WorkerProc.wait_for_ready, 阻塞等待worker进程全部启动成功
					- (保存) MultiprocExecutor.response_mqs 收集回复队列
				- (调用) EngineCore.`_initialize_kv_caches(vllm_config)` <mark style="background:#fff88f">初始化kvcache显存</mark>
					- (保存) 获取kv_cache_spec规格
					- (调用) EngineCore.model_executor.determine_available_memory()让执行器 <mark style="background:#b1ffff">做profile探测kvcache可用显存空间</mark>
						- (RPC) <mark style="background:#fdbfff">》》》》》》》》》发送determine_available_memory任务</mark>
					- (保存) 根据探测结果，更新kv_cache_configs
					- (调用) EngineCore.model_executor.initialize_from_config 开始<mark style="background:#b1ffff">让执行器初始化kvcache显存区域</mark>
						- (RPC)<mark style="background:#fdbfff">》》》》》》》》》发生initialize_from_config任务</mark>
				- (构造) EngineCore.self.scheduler = Scheduler.init()， <mark style="background:#fff88f">构造调度器</mark>
				- (调用) EngineCore.step_fun = self.step()，<mark style="background:#fff88f">指定单步运行方法</mark>
	- (调用) EngineCoreProc.run_busy_loop()







【worker进程】
- <mark style="background:#fdbfff">【Worker进程开始】WorkerProc.worker_main()</mark>
	- (构造) WorkerProc.init()
		- (保存) self.rank = rank  分布式通信的卡号
		- (构造) wrapper = WorkerWrapperBase() <mark style="background:rgba(92, 92, 92, 0.2)">构造Worker调用适配器实例</mark>
		- (调用) wrapper.<mark style="background:#fff88f">init_worker() </mark>， 开始<mark style="background:#fff88f">构造Worker实例</mark>
			- (构造 )WorkerWrapperBase.worker = Worker.init()
				- (构造) WorkerBase.init()
					- (保存) 保存配置文件
					- (声明) WorkerBase.self.device 设备是cuda
					- (声明) WorkerBase.model_runner : nn.Module
				- (保存) 各种保存，记录使用model_runner的版本
		- (保存) WorkerProc.self.worker = wrapper
		- (调用) WorkerProc.self.worker.<mark style="background:#fff88f">init_device()</mark>
			- (调用) 设置设备是CUDA + NCCL通信组构建+创建内存拍照器
			- (构造) Worker.self.model_runner = GPUModelRunnerV1.init(), <mark style="background:#d3f8b6">构造model_runner</mark>
				- (保存) 保存各种配置config
				- (构造) GPUModelRunner.self.sampler = Sampler.init() <mark style="background:#b1ffff">构造采样器</mark>
				- (声明) GPUModelRunner.self.kv_caches : list[torch.Tensor] <mark style="background:#b1ffff">声明占位各kvcache tensor列表</mark>
				- (创建) GPUModelRunner.self.requests 持久化请求状态记录
				- (创建) GPUModelRunner.self.input_batch = InputBatch.init, 构建输入格式转换器
				- (创建) 每轮batch输入的整理统计信息 的 缓冲区申请
		- (调用) WorkerProc.self.worker.<mark style="background:#fff88f">load_model()</mark>
			- (构造) GPUModelRunner.get_model_loader(load_config), <mark style="background:#d3f8b6">构建模型加载器</mark>
				- 返回一个DefaultModelLoader(BaseModelLoader) 实例
			- (创造) GPUModelRunner.self.model = BaseModelLoader.load_model()  <mark style="background:#d3f8b6">加载模型+权重拷贝</mark>
				- (调用) <mark style="background:#b1ffff">指定torch的设备</mark> = cuda
				- (调用) model = initialize_model() <mark style="background:#b1ffff">构造Qwen2ForCausalLM 模型实例</mark>
					- (调用) 从 model_config中<mark style="background:#fdbfff">解析出模型类 model_class</mark>
					- (调用) 获取这个类的初始化参数列表
					- (构造) model = Qwen2ForCausalLM.init() <mark style="background:#fdbfff">构造模型实例</mark>
					- (调用) return model 返回模型实例
				- (调用) DefaultModelLoader.load_weights(model, model_config) <mark style="background:#b1ffff">加载模型权重</mark>
					- (调用) DefaultModelLoader.get_all_weights <mark style="background:#d4b106">返回safetensors的权重迭代器</mark>
						- 指定model_config.model， yield from `_get_weights_iterator`
							- weights_iterator = safetensors_weights_iterator <mark style="background:#d2cbff">判定到是safetensors格式</mark>的
								- safe_open，pt格式，<mark style="background:rgba(173, 239, 239, 0.55)">使用mmap懒加载，yield抛出一个个权重tensor</mark>
					- (调用) Qwen2ForCausalLM.load_weights(权重数据迭代器)
						- AutoWeightsLoader.load_weights(迭代器)
							- 迭代器抛出的权重长这样：
							- ![384](../images/Pasted%20image%2020260817105357.png)
							- 把weights迭代器的每一条权重，打包成(name, data)
							- (调用) AutoWeightsLoader.`_load_module()`， 开始<mark style="background:#b1ffff">递归匹配模型的张量参数 《-》weights里面的张量数据</mark>
								- child_modules 为 内部子模块
								- child_params 为 内部的张量参数
								- (调用) `_load_param` <mark style="background:#b1ffff">递归到叶节点</mark>，开始加载这个权重数据到这个权重参数
									- (调用) default_weight_loader(param, weight_data)， 实际的拷贝器函数
										- <mark style="background:#d4b106"> param.data.copy_(loaded_weight)，利用张量类型的data.copy_来触发拷贝，然后触发page fault，从磁盘->cpu->gpu</mark>
	- (调用) WorkerProc.worker_busy_loop()
		- 接受RPC并执行

		- <mark style="background:#fdbfff">》》》》》》determine_available_memory 任务</mark>
			- (调用) model_runner.profile_run()
				- (调用) GPUModelRunner.`_dummy_run()`
					- (计算) 指定dummy batch的规格，让缓冲区达到峰值
					- (调用) 创建kvcache槽位，self.`_get_slot_mappings`
					- (调用) <mark style="background:#d3f8b6">outputs = self.model() 前向推理</mark>
			- (执行) 计算可用kvcache 显存字节量
				- (保存) self.available_kv_cache_memory_bytes = self.requested_memory - profile_result.non_kv_cache_memory-cudagraph评估
		- <mark style="background:#fdbfff">》》》》》》initialize_from_config任务</mark>
			- (保存) 保存 cache_config.num_gpu_blocks
			- (调用) model_runner.initialize_kv_cache(kv_cache_config) 开始初始化显存，构造每层的kvcachetensor
				- (调用) kv_caches = self.GPUModelRunner.initialize_kv_cache_tensors() 划分tensor
					- (调用) kv_cache_raw_tensors = self.`_allocate_kv_cache_tensors` 划分tensor
					- (调用) kv_caches = self.`_reshape_kv_shape_tensors` 把每个tensor， reshape出block维度。








































---

#### 梳理调度任务-inputbatch-缓冲区-模型输入的数据流转

先整理一下GPUModelRunner里面所有出现的描述我们的请求的变量，给他们归类整理一下

```python
class GPUModelRunner:
# init
	max_num_tokens # 本轮最大要计算的tokens数
	max_num_reqs   # 本轮的最大req数
	
	self.kv_caches : list[torch.Tensor] # list[layer_i层的kvcache tensor]
	
	
    #————————————————————————————————————————————————————————————————
	self.requests : dict[req_id, CacheRequestState] # 持久化状态对象库
	self.input_batch # 持久化状态对象池
	#----------------------------------------------------------------
	
	self.input_ids # [token_0, token_1, .....], 长度=max_num_tokens
	self.positions # [pos_0, pos_1, ......], 长度=max_num_tokens
	
	self.query_start_loc #[l_0, l_1, ......, l_n], 长度=max_num_reqs+1
	
	self.seq_lens # [req_0_len, req_1_len, ....], 长度=max_num_reqs
	self.num_computed_tokens # [num_0, num_1, ....], 长度=max_num_reqs
	
	self.prev_num_draft_tokens #[num_draft_0, num_draft_1, ...], 长度=max_num_reqs
	self.req_indices #[req_x, req_x, req_y, ...], 长度=max_num_tokens
	
	self.prev_positions # [last_pos_req0, last_pos_req1, ...], 长度=max_num_reqs
	self.num_scheduled_tokens # [num_0, num_1, ...], 长度=max_num_reqs
	
	self.inputs_embeds #[embed_size_token_0, embed_size_token_1, ...], 长度=max_num_tokens
	
	self.is_token_ids # [1,1, 0, 0,....], 长度=max_num_tokens
	self.num_decode_draft_tokens #[num_0, num_1,....], 长度=max_num_reqs
	
	self.num_accepted_tokens #[num_0, num_1,...], 长度=max_num_reqs
	self.query_pos # [p1, p2, p3, q1,q2,...], 一维token ids中，每个toekn在各自req内query的位置

	
def execute_model:
	slot_mappings # 写token 的 kvcache， 各个token的kv地址列表
				  # 读block 的 kvcache, 直接attention算子来
	
	
def _prepare_inputs:
	req_indices
	token_indices


```

下面来开始整理
![357](../images/Pasted%20image%2020260818234616.png)
![](../images/Pasted%20image%2020260818235154.png)

所以建立在这个的基础上，你可以看到，这些用_make_buffer创建出来的缓冲区，其实就是对本轮调度的一个一维化罢了



关于要不要填充
- input_ids 是未填充的，用来取要计算的token
- token_indices_tensor，是这个input_ids对应位置token在填充后的索引
- token_ids_cpu_tensor, 这个就是完整的填充后的一维存放
![](../images/Pasted%20image%2020260819144647.png)
![](../images/Pasted%20image%2020260819144810.png)
![](../images/Pasted%20image%2020260819144850.png)



### 各种并行化方案
不同的并行化方案，其实就是对应着怎么分配worker任务

- world_size 表示我们整个vllm里面启动了多少worker
- tp_size 表示 TP启动的worker数量
- pp_size 表示 PP启动的worker数量
- pcp_size 表示PCP启动的worker数量
- data_paraller_size 表示DP的worker数量


> **Worker 本身必须具备同时参与多种并行策略组合的能力。**

因为一个 Worker 不知道自己只属于 TP、PP 还是 DP，它只知道：

- 自己的 global rank
- 自己属于哪个并行组
- 自己负责模型的哪一部分
- 自己需要和哪些 GPU 通信
#### TP，PP，DP，EP
先来解释一下这几个并行方案

![](../images/Pasted%20image%2020260814182538.png)

vllm里面设计了一个5D张量来快速把一维的GPU rank list 转化成各个并行的peer分组。

但是我没有必要了解这个，你就理解，每个卡，他们的分工是什么就行了

> tp_size, pp_size, dp_size, ep_size, 这些都是说的你如何来划分对象
> 
> pp_size, 你把一个<mark style="background:#fff88f">模型副本来切分成pp_size段pipeline</mark>
> tp_size, 把每个pipeline, <mark style="background:#fff88f">里面的权重，切分成tp_size段</mark>（<mark style="background:#affad1">想想多头注意力，天然支持并行</mark>，不同语义空间维度互不相关，需要相关计算的时候，再每个tp组内peer，all-reduce一下）
> dp_size, 这个最不同，他是描述你有几个模型副本
> ep_size, 他是你<mark style="background:#fff88f">把所有的专家模型，分成几段</mark>，
> 
> 上面这些你想象成任务，划分了各种任务栏
> 然后world_size 是表示你拥有的GPU，你现在要把这world_size个GPU分配到这些任务栏去。

举例：tp_size = 3, pp_size = 5, 此时你现在有15个gpu

所以，可以这样分gpu的并行

![512](../images/Pasted%20image%2020260814183352.png)







#### PCP
> 这个更加复杂，先把TP，PP搞懂。



上下文并行（超长上下文）
![278](../images/Pasted%20image%2020260811153122.png)




### 物理拓扑-模型并行拓扑关系梳理

假设：

```
8 node × 16 GPU
world_size=128
```

遵循以下规则：
- **物理拓扑规则**：
	- world_size 永远表示整个vllm集群中用到的gpu数量
	- local_world_size 永远表示一个节点内的gpu的数量
- **模型并行拓扑规则**：
	- <mark style="background:#affad1">1个dp副本 = 1个enginecore引擎后端 = 1个executor实例</mark>。
	- executor的类选择依赖于这个dp副本的gpu是否跨节点：
		- 不跨节点：
			- 一个节点里面跑多少个dp副本，就有多少个执行器，并且每个执行器都是MultiprocExecutor
		- 跨节点：
			- 一个dp副本一个enginecore进程一个executor，跑在多个节点上，这个进程，执行器肯定运行在一个节点上，所以是RayExecutor, 
			- 并且其余的节点上不会有enginecore, executor，仅仅只是被ray分布式框架创建好worker进程对象而已，被首节点的executor控制。



![](../images/Pasted%20image%2020260814191259.png)



|配置|一个模型副本GPU|DP数量|每节点DP副本|EngineCore|Executor|Executor类型|
|---|---|---|---|---|---|---|
|TP16 PP1 DP8|16|8|1|8|8|MultiprocExecutor|
|TP8 PP1 DP16|8|16|2|16|16|MultiprocExecutor|
|TP16 PP2 DP4|32|4|0.5|4|4|RayExecutor|
|TP16 PP8 DP1|128|1|0.125|1|1|RayExecutor|



#### vllm_config

`VllmConfig` 是整个推理实例的总配置，里面组合了多个子配置

```python
class VllmConfig:
    model_config # 模型本身
	    # 模型路径
	    # 模型类型
	    # dtype 参数类型
	    # tokenizer
	    # max_model_len
	    # trust_remote_code
	    
    cache_config # kvcache相关
	    # GPU cache占比
	    # block_size = 16个token
	    # KV cache dtype
	    # swap space
	    
    parallel_config #并行化配置
	    # tp,pp,dp
	    # distributed_executor_backend = "mp"，“ray”,"external_launcher"
	    
	    
    scheduler_config # 调度器配置
	    # max_num_batched_tokens
	    # max_num_seqs
	    # scheduler policy
	    # chunked prefill
	    
	    
    device_config # 运行平台
	    # device="cuda"
	    
	    
    load_config # 加载模型配置
	    # safetensors
	    # tensorizer
	    # bitsandbytes
	    # remote loading
	    
	    
    compilation_config # 编译优化配置
	    # torch.compile
	    # CUDA graph
	    # dynamo
	    
	speculative_config # 投机解码配置
		# draft model
		# accept/reject
```

让gpt列了一些实际的例子
```python
class VllmConfig:

    model_config              # 模型本身配置
        model = "/models/Qwen2.5-7B-Instruct"              # 模型路径
        model_type = "qwen2"                              # 模型架构类型
        tokenizer = "/models/Qwen2.5-7B-Instruct"          # tokenizer路径
        max_model_len = 32768                              # 最大上下文长度
        dtype = "float16"                                  # 模型计算数据类型
        seed = 0                                           # 随机种子
        trust_remote_code = False                          # 是否允许加载远程自定义模型代码
        limit_mm_per_prompt = None                         # 单个请求最大多模态输入限制


    cache_config              # KV Cache相关配置
        block_size = 16                                    # 一个KV cache block包含的token数量
        gpu_memory_utilization = 0.9                       # GPU显存使用比例
        swap_space = 4                                     # CPU swap空间大小(GB)
        cpu_offload_gb = 0                                 # CPU offload显存大小
        cache_dtype = "auto"                               # KV cache数据类型(fp16/bf16/fp8)
        enable_prefix_caching = True                       # 是否开启Prefix Cache复用历史KV
        num_gpu_blocks = None                              # 根据显存自动计算GPU KV block数量


    parallel_config           # 模型并行配置
        tensor_parallel_size = 4                           # Tensor Parallel大小，权重沿tensor维度切分的GPU数量
        pipeline_parallel_size = 1                         # Pipeline Parallel大小，模型层切分的stage数量
        data_parallel_size = 1                             # Data Parallel大小，模型副本数量
        context_parallel_size = 1                          # Context Parallel大小，沿sequence维度切分prefill
        expert_parallel_size = 1                           # MoE Expert Parallel大小，专家并行数量
        distributed_executor_backend = "mp"                # Worker启动后端(mp/ray/external_launcher)
        world_size = 4                                     # 当前模型并行组总GPU数量(TP*PP*CP等)
        rank = 0                                           # 当前进程全局rank编号
        local_rank = 0                                     # 当前节点内rank编号


    scheduler_config           # 调度器配置
        max_num_batched_tokens = 8192                      # 单轮调度最大token数量
        max_num_seqs = 256                                 # 最大同时运行请求数量
        policy = "fcfs"                                   # 调度策略(first come first serve)
        enable_chunked_prefill = True                     # 是否开启chunked prefill
        max_num_partial_prefills = 1                      # 最大同时进行部分prefill数量
        enable_prefix_caching = True                      # 是否允许调度prefix cache请求
        enable_preemption = True                          # 是否允许抢占低优先级请求
        scheduling_steps = 1                              # scheduler执行步数


    device_config              # 设备运行配置
        device = "cuda"                                    # 推理设备类型(cuda/cpu)
        device_id = 0                                      # 当前GPU编号
        platform = "cuda"                                  # 计算平台


    load_config                # 模型加载配置
        load_format = "auto"                               # 权重加载格式(auto/safetensors/pt)
        download_dir = "~/.cache/huggingface"              # 模型下载缓存目录
        use_safetensors = True                             # 是否优先加载safetensors格式权重
        quantization = None                                # 量化方式(None/AWQ/GPTQ/FP8)
        load_sharded_state = False                         # 是否分片加载模型权重
        skip_loading_weights = False                       # 是否跳过权重加载


    compilation_config         # 编译优化配置
        enforce_eager = False                              # 是否强制使用eager模式，关闭CUDA Graph
        use_inductor = False                               # 是否使用torch.compile + Inductor
        backend = "inductor"                               # torch.compile后端
        cuda_graph_capture_sizes = [1,2,4,8,16,32,64]      # CUDA Graph捕获的batch size集合
        max_capture_size = 512                             # CUDA Graph最大capture batch大小
        compile_mode = "default"                           # 编译优化模式


    speculative_config          # 投机解码配置
        enabled = False                                  # 是否开启投机解码
        draft_model = "/models/Qwen2.5-0.5B"              # 草稿模型路径
        num_speculative_tokens = 5                        # 小模型一次预测token数量
        acceptance_method = "rejection_sampling"          # 大模型验证接受策略
        draft_tensor_parallel_size = 1                    # 草稿模型TP大小


    lora_config                 # LoRA配置
        enable_lora = False                               # 是否开启LoRA
        max_loras = 4                                     # 最大同时加载LoRA数量
        max_lora_rank = 64                                # LoRA最大rank
        lora_modules = []                                 # LoRA模块列表


    observability_config        # 监控配置
        enable_metrics = True                             # 是否开启指标统计
        collect_model_forward_time = False                # 是否统计模型forward耗时
        otlp_traces_endpoint = None                       # OpenTelemetry trace地址
```
















### 各种加速方案



#### torch.compile()
![](../images/Pasted%20image%2020260811154858.png)

**torch.compile：优化“计算图本身”。**

做的事情：
```
PyTorch动态图
    ↓
捕获graph
    ↓
算子融合/生成优化kernel
    ↓
更快forward
```

例如：原来：

```
Linear kernel
+
Add kernel
+
ReLU kernel
```

可能融合：

```
一个kernel完成
```





#### cuda graphs
![](../images/Pasted%20image%2020260811154728.png)
**CUDA Graph：优化“计算图执行过程”。**

不改变计算：第一次：

```
capture:
kernel1
kernel2
kernel3
```

之后：
```
cudaGraphReplay()
```

直接执行，不需要CPU逐个launch kernel。


![](../images/Pasted%20image%2020260811155310.png)







### Worker
#### worker的初始化
主要是下面3件事情：
- init device(初始化设备)
	- 各种并行方案下，设备环境，分布式上下文的准备，多卡多节点的<mark style="background:#d3f8b6">通信组的准备</mark>
	- <mark style="background:#fff88f">model_runner实例化</mark>，管理调用各个算子来处理数据，采样器，GPU侧<mark style="background:#fff88f">输入输出缓冲区</mark>这些
	- inputbatch实例化，管理batch输入的状态（每个worker需要同时处理多个req）
- load model (加载模型)
	- 实例化各层<mark style="background:#fff88f">算子</mark>
	- 加载<mark style="background:#fff88f">模型权重</mark>，按照并行策略完成参数切分
	- 切换pytorch的推理模式
	- torch.compile()对模型的执行图进行优化
- initialize <mark style="background:#fff88f">KV cache</mark>(初始化kv cache)
	- 确定各层的kvcache规格
	- 估算可用显存，block数量
	- 分配显存，绑定
	- flashattention后端配置
	- warmup批次，为常见batch_size的形状捕获cuda graphs, 减少kernel launch开销。

### executor
- executor
	- 这个定位是：<mark style="background:#fff88f">一个 Executor 对应一个模型副本（model replica）的控制入口</mark>
	- 他不对应节点
- worker
	- 这个就是对应卡， 
	- <mark style="background:#fff88f">一个模型实例内部，可以有多个 Worker（因为 TP/PP/PCP）</mark>
- 节点：
	- <mark style="background:#fff88f">一个物理机器（服务器）通常对应一个 node（节点）</mark>

所以，除了DP的情况下，其他任何一种情况，uni, mp, ray, 启用tp, pp, pcp优化，都只会有一个引擎后端进程，也就只有一个executor，也就是只有一个模型实例在跑。

如果在启用了DP的情况下，因为是直接把模型拷贝一份，并行跑，所以，会有多个引擎后端进程，就会有多个executor


为了加深DP和executor代表一个模型副本的理解，下面举两个例子

> **单机多卡**：
> 单机8卡，DP=2 TP=4
> 含义：两个模型副本，每个副本用4卡跑，所以有两个executor，对应两个enginecoreproc, 运行在同一个机器上

```txt
EngineCoreProc0
      |
   Executor0
      |
   Worker0-3


EngineCoreProc1
      |
   Executor1
      |
   Worker4-7
```


> 多机多卡：
> 2台机器，每台8卡，DP=2 TP=8
> 含义：一台机器一个节点，所以有两个节点，DP=2， 所以一个节点跑一个副本，每个副本需要8张GPU

```txt
Node0:(机0)

Replica0（副本0 = DP0）

EngineCoreProc0 
      |
  Executor0（一个副本对应一个executor）
      |
 Worker0-7


Node1:（机1）

Replica1（副本1 = DP1）

EngineCoreProc1
      |
  Executor1（一个副本对应一个executor）
      |
 Worker8-15
```


<mark style="background:#ff4d4f">注意</mark>
**这个 Executor 管理的 Worker 
同一台机

---


> 但是你可以看到，这样的多进程架构是存在单机限制的，只有单机多卡的情况下，多进程才能互相通信，
> 
> 但是如果分在多机，也就是多节点的情况下，这种多进程的架构就很难协同了，这就是<mark style="background:#fff88f">多机协同的和单机限制的矛盾</mark>

因此需要解决<mark style="background:#fff88f">跨机资源发现</mark>，<mark style="background:#fff88f">网络握手</mark>和<mark style="background:#fff88f">进程对齐</mark>的问题

![518](../images/Pasted%20image%2020260811201603.png)

> Ray：**分布式计算框架 / 分布式任务调度框架**

Ray主要解决：

> 如何在多台机器上创建、管理、调度分布式计算任务。

它提供：
- 节点发现
- 进程/对象管理
- 任务调度
- Actor模型通信


#### 通信网络
##### 节点内部 GPU-GPU 通信
![474](../images/Pasted%20image%2020260811201956.png)
既然提到了这个通信网络，这边就先梳理一下多机多卡的通信方式


![313](../images/Pasted%20image%2020260811202037.png)

- 单机内
	- GPU-GPU通信：NVLink（最快），PCIe Switch（稍慢）
- 多机间
	- GPU（node 0）- GPU (node 1) :  RDMA+Ethernet/InfiniBand
		- 依赖 CUDA + NCCL分布式通信库（先建立通信拓扑图）


![338](../images/Pasted%20image%2020260811202806.png)



##### 节点之间的进程/任务管理和通信

![202](../images/Pasted%20image%2020260811202832.png)

- ray
	- 负责：任务调度 + worker创建
		- 我提交RayExecutor()， ray发现各个节点的卡资源
		- 然后ray告诉每个worker : 你的rank是多少 你的GPU是多少 master在哪里
		- worker启动后，由NCCL接管
- slurm



#### 并行组划分，5D张量表示
![452](../images/Pasted%20image%2020260811204023.png)


### executor和worker通信机制
这个也是进程间的通信机制

一种类 RPC 的进程间调用机制（vLLM 源码中正是将其核心方法命名为 `collective_rpc`）

> 类似调用服务？把worker当成一个提供服务的进程

RPC 是 **Remote Procedure Call（远程过程调用）**。

简单理解：

> **像调用本地函数一样，调用另一台机器/另一个进程里的函数。**

Executor 负责发送待执行的方法名及其参数，Worker 负责在自身进程中接收请求、执行对应逻辑，并将执行结果返回给 Executor。在这个抽象下，Executor 相当于调用方，Worker 相当于服务端。







## 3.5_cuda_graph

![406](../images/Pasted%20image%2020260822210611.png)

A，B，C,....都表示cpu下发放到cuda stream里面的任务（异步）

即便如此，每次cpu下发任务，内核驱动解析，排队，调度，这个过程都会带来CPU的开销（多次进入内核态），尤其是在高频率的重复执行相同操作序列的场景下（推理中的每层的decode）这个时候的cpu开销（单进程，每层都要多次进入内核态提交）

所以cuda graph的设计就是消除这类重复性的调度成本：

**运行你在一次执行过程中，将一组已经定义好的，CUDA操作录制下来，包括kernel launch, 异步内存拷贝，事件同步等，记录下他们之间的依赖关系**

> 这个录制的过程，就被成为**图的捕获**

**当这些操作被记录完成后，CUDA 运行时会将它们组织成一张有向无环图（DAG, Directed Acyclic Graph），这就是 CUDA Graph**

图中不仅包含有哪些操作，更重要的是还记录了操作之间的依赖关系。例如，某个 kernel 必须等前面的数据拷贝完成后才能启动，而另外一些彼此独立的操作则可以并行执行。正因为依赖关系被显式表达出来，系统在后续执行时就能够更准确地控制执行顺序。

<mark style="background:#fff88f">更关键的是，一旦图被构建完成，后续重复执行时就不需要 CPU 再逐个调用 API、逐条提交操作、逐步建立依赖关系，而是只需要发起一次图执行请求。这样可以显著减少 CPU 的参与和提交开销</mark>

**CUDA Graph 并不是简单地把多个 CUDA 操作打包在一起，而是把操作内容和依赖关系一起固化为可重复执行的执行计划**。这样做的主要收益，是降低频繁重复执行相同计算流程时的调度成本，并让运行时基于完整的依赖信息更高效地组织执行

<mark style="background:#d3f8b6">  更准确地说，CUDA Graph 的主要价值在于把一组固定的 CUDA 操作及其依赖关系提前固化下来，使后续执行时能够以更低的 CPU 提交成本完成同样的 GPU 工作。</mark>

### 使用注意事项
![](../images/Pasted%20image%2020260822211757.png)

- 重放，依赖稳定的**内存地址**



### 使用方法
在原有我们的基础上，做以下优化：
1. 提前申请静态张量，禁止动态形状
	1. 这条执行路径上的 输入， 输出， 中间缓冲区， 都预先分配好。且形状必须保持一致
2. 录制期间，cpu不能同步，且纯cpu的行为无法被录制
3. cuda graph仅能记住内存地址，所以，需要实现原地写入 copy_() 、 fill_()
	1.  xxx_表示in-place 原地修改数据
		1. fill_()表示，把整个Tensor的所有元素填成同一个值
		2. copy_(), 把另一个tensor的数据原地写入当前张量


### 支持不同batch_size, 不同序列长度
当我们面临不同batch形状的输入输出中间缓冲区的形状的需要的时候。

cuda Graph本身不擅长直接处理动态shape。所以有以下两种做法：

1. 为不同shape，或者不同bucket，分别录制多张graph，运行时按需选择合适的执行
	1. batch=1, batch=2
	2. seq_len = 512, 1024, 2048
2. 使用padding/mask， 把较小输入映射到一张较大的固定shape上。



### 注意点
前面说到，我们cuda graph，依赖的是固定的地址，所以需要提前把输入输出，中间缓冲区创建出来，
这里的中间缓冲区，不是内部一个局部算子的输出的临时张量（这个可以直接录制地址）
```txt
Capture：

graph_input
   │ 0x1000
   ↓
Embedding
   │
   ├── 临时buffer 0x2000
   ↓
Layer 0
   │
   ├── 临时buffer 0x3000
   ├── 临时buffer 0x4000
   ↓
Layer 1
   │
   ├── 临时buffer 0x5000
   ...
   ↓
graph_output
      0x9000

              ↓

这些 GPU 地址被 CUDA Graph 固定下来

              ↓

Replay：

直接再次使用
0x1000
0x2000
0x3000
0x4000
...
0x9000
```
这就是为什么你**不用手工把模型 forward 里面所有中间 buffer 都提前创建出来**。

PyTorch 在 capture 的时候就把这些中间显存分配纳入 graph 的内存管理了。

<mark style="background:#d3f8b6">那什么时候需要把中间缓冲区提前创建出来呢？</mark>

**需要提前创建中间缓冲区，通常不是因为 “CUDA Graph 一定要求你手动创建”，而是因为你想主动控制内存、shape、地址和生命周期**

![506](../images/Pasted%20image%2020260822220134.png)




### 为什么decode比prefill更适合 cuda graph

<mark style="background:#fff88f">decode</mark>
![154](../images/Pasted%20image%2020260822220916.png)

<mark style="background:#fff88f">prefill</mark>
![268](../images/Pasted%20image%2020260822221003.png)


<mark style="background:#fff88f">所以，在一个batch都是decode的req的时候，就是天然适合cuda graph的时候了</mark>

![356](../images/Pasted%20image%2020260822221118.png)![271](../images/Pasted%20image%2020260822221132.png)
![247](../images/Pasted%20image%2020260822221149.png)

所以，如果是一个batch是混合的prefill/decode， 这个就不是很方便

所以，一般在实际的推理框架中，**只有纯 decode batch 才走 CUDA Graph，混入 prefill 就退回 eager**

![524](../images/Pasted%20image%2020260822221716.png)

### vllm里的cuda_graph 实现

关键数据结构：
- BatchDescriptor
```python

# 用来描述当前batch的关键形状特征
# 并作为CUDAGraph 分派、匹配使用的重要key
class BatchDescriptor:
	num_tokens # 该batch的总token数
	num_reqs # 该batch的总req数
	uniform : bool = False # 表示当前batch中各个req的token数是否一致
```

- CudaGraphEntry
```python
# 用来保存某个BatchDescriptor 对应的 已捕获 CUDA graph， 以及该图重放时需要的相关信息
# 一个CUDAGraphEntry实例就对应一个图
class CUDAGraphEntry:
	batch_descriptor: BatchDescriptor # 该graph的输入batch的key
	cudagraph : torch.cuda.CUDAGraph # 该graph本体
	output: Any # graph执行后的输出缓存，以弱引用形式保存，减少内存占用
	input_addresses: list[int] # 输入张量的地址列表，用于在replay的时候校验输入地址是否一致
```


model_runner实例，在init()初始化的时候，会创建cudagraphdispatcher调度器，但是此时的内部的key尚未真正初始化完成，因为他需要等待attention backend初始化结束后，才能确定当前后端实际支持那些cudagraph mode，以及应该生成那些可分派的BatchDescriptor

可以看一下cudagraphdispatcher内部的主要属性：
```python
class CudagraphDispatcher:
	vllm_config # 构造的配置
	uniform_decode_query_len = 1+ vllm_config.num_speculative_tokens # 统一解码query长度
	
	self.cudagraph_keys: dict[CUDAGraphMode, set[BatchDescriptor]] = {
		CUDAGraphMode.PIECEWISE: set(),
		CUDAGraphMode.FULL: set(),
	}
	
	self.keys_initialized = False
	
	# 默认mode, 表示当前轮次的计算，该用什么策略，是分段图模式，还是完整图模式。
	self.cudagraph_mode = CUDAGraphMode.NONE
```

---
当构造一个空的CudagraphDispatcher后，model_runner会开始initialize_cudagraph_keys(), 为当前配置 和后端能力生成一组 有效的 cudagraph 调度key 然后放到调度器的容器里面

> 所以这里你也看到了，调度器里面，只持有不同mode下的graph key, 并没有graph实例。
> 调度器，仅负责在容器里面，快速匹配合适的cudagraph描述符。

后续的推理阶段，调度器，会根据输入的batch形状，返回
- runtime_mode
	- 用于描述本轮应采用的图类型，FULL / PIECEWISE
- batch_descriptor (key)
	- 当前batch的关键形状特征，后续执行组件，再根据这两个信息，去查找是否已有捕获的 CUDA Graph可供重放


> 所以，initialize_cudagraph_keys 所做的是：
> - 为mixed/prefill 路径 预生成一批 PIECEWISE key
> - 为 uniform decode 路径 预生成一批 FULL key
> - 将这些key 按照 mode分类保存，供运行时分派使用

![](../images/Pasted%20image%2020260823142850.png)


----

```python

# 包装一个可执行对象，来增加 cuda图捕获和重放能力。
'''
这个类的使用工作流：
	1. 初始化阶段，指定一个执行模式：FULL / PIECEWISE
	2. 运行阶段，wrapper实例，接受一个运行模式，一个batch key 从 前向上下文，然后相信这个调度结果
	3. 如果指定的运行模式是NONE， 就单纯的直接调用这个执行对象
	4. 否则，如果mode匹配上了wrapper的模式
		   4.1 如果key不存在，就执行图捕获，然后记录graph
		   4.2 如果key存在，就直接执行图重放
		   
	这个包装器，不会存吃持续缓存， 或者拷贝任何model的输入到重放的输入缓冲区。

'''
class CUDAGraphWrapper:
	vllm_config
	compilation_config
	
	
	self.runnable # model
	self.runtime_mode #支持的运行图模式, 不可以为NONE，否则不init
	
	# 包装器里面，记录下我们目前已经捕获key-graph集合
	self.concrete_cudagraph_entries: dict[BatchDescriptor, CUDAGraphEntry] = {}

	
	self.first_run_finished = False
	
```

所以，当我们得到一个batch后，原本的逻辑，就是扁平化处理一下，然后塞给模型运行。

在这之中，我们增加了一个调度cuda graph的逻辑：
- 输入batch
- 判断预处理：
	- 1. batch类型：混合、纯decode、纯prefill
	- 2. 走什么mode: FULL完整图、PIECEWISE分段图
	- 3. 根据batch类型，判断是否要padding成固定形状


#### FULL PIECEWISE 的理解
关键就在于：
- 纯decode的batch， 只要padding到相同形状档位，他们的grid划分是可以复用的
- 非纯decode的batch， 即便padding到相同的形状档位，batch的形状不一样，导致grid的program的划分无法复用。


![](../images/Pasted%20image%2020260823171208.png)


#### padding
![490](../images/Pasted%20image%2020260823173528.png)
![468](../images/Pasted%20image%2020260823173554.png)
![](../images/Pasted%20image%2020260823173500.png)

所以自始至终就是填的扁平input_ids， 这些属于填充，本质就是为了让graph能跑起来

**也没有掩码来排除填充，纯靠真实计数**

![](../images/Pasted%20image%2020260823174030.png)

#### 实际流程
![412](../images/Pasted%20image%2020260823214003.png)


![316](../images/Pasted%20image%2020260823214754.png)
#### warmup
每次wrapper发现这次的（mode, key）还没有现成的graph, 那么在真正跑eager + capture之前，就会先跑几次dummy run, 目的是：
- 加载/编译 kernel 
	- triton kernel 第一次跑才编译，避免在capture的时候引入额外的launch
- 稳定显存布局
	- warmup用辅助stream，跑完sync同步，确保capture时显存池状态干净

> **cuda graph捕获时，任何新的kernel 编译/ 内存分配，都会被打进图里， warmup 先把这些 “一次性开销” 在 capture外触发掉，否则捕获到的图里面会包含 编译，分配等不该回放的东西。**


#### PIECEWISE的依赖

当trace到wrapper里面的调用的时候
![416](../images/Pasted%20image%2020260823233704.png)
可以看到这边，如果是要录制的话，无论是FULL，还是PIECEWISE，都是一样的代码，所以wrapper只管录制操作，并没有区分。

所以PIECEWISE是分段图的录制，所以他不光光依赖CUDA graph， 还依赖torch.compiler

![](../images/Pasted%20image%2020260823233835.png)

需要torch.compile 把模型的前向切开，否则cudagraph录制，永远只能录一段。

这就是为什么他们的简历里面只支持FULL的cuda graph








#### 流程展示

【worker进程里model_runner的过程中】

- (构造) model_runner.init()
	- 配置元信息
	- 构造采样器
	- kv cache tensor的列表创建
	- 持久化请求状态字典
	- inputbatch 转换器
	- <mark style="background:#fff88f">(保存) self.cudagraph_batch_sizes 保存排序后的 compilation_config.cudagraph_capture_sizes: list[int] 里面的图捕获大小列表</mark>
	- <mark style="background:#fff88f">(保存) self.uniform_decode_query_len 保存均匀解码(batch里都是decode req, 且qtoken一样多)</mark>
	- <mark style="background:#d3f8b6">（构造）self.cudagraph_dispatcher = CudagraphDispatcher.init()</mark> 构造<mark style="background:#ff4d4f">graph调度器</mark>
	- 输入batch缓冲区创建
- (调用) model_runner.load_model()
	- 获取模型加载器，构造模型实例 + 权重拷贝
	- <mark style="background:#fff88f">(保存) cudagraph_mode = self.compilation_config.cudagraph_mode</mark>
		- <mark style="background:#d3f8b6">发现确实是启动了cudagraph，mode不是NONE</mark>，是FULL_AND_PIECEWISE
			- <mark style="background:#affad1">(构造) self.model = CUDAGraphWrapper()</mark> 构造<mark style="background:#ff4d4f">cudagraph模型装饰器</mark>
				- <mark style="background:#b1ffff">self.concrete_cudagraph_entries 记录下我们目前已经捕获key-graph集合</mark>

- (调用) model_runner.profiler_run() 测算kvcache可用显存
	- （调用）self. dummy_run()
		- 根据不同的情况，构造不同的dummy batch: 混合、纯decode、纯prefill
		- <mark style="background:#fff88f">(调用) _determine_batch_execution_and_padding 计算该batch需要的mode, 以及padding</mark>
		- 创建dummy_run 计算这些dummy token所需的kvcache的槽位
		- 前向推理
			- <mark style="background:#fff88f">设置 cuda graph 的 上下文</mark>
			- <mark style="background:#fff88f">调用self.model，驱动装饰器来执行模型，并录制模型的行为</mark>
		- 返回结果
- (调用) model_runner.initialize_kv_cache() 初始化kvcache显存为张量
- (调用) model_runner.execute_model()
	- 更新inputbatch持久化信息
	- 开始从inputbatch里面提取本次要执行的缓冲区信息，准备input_ids
	- （调用） _determine_batch_execution_and_padding_ 开始决定这个batch，他是走什么mode, 什么形状，要不要padding。
	- 读取已经计算好的slotmapping, 整理格式
	- 构建attention 元数据
	- 统一预处理模型前向所需的全部输入
	- model_forward前向推理
	- 







## 4_并行优化策略
### 4.1_模型不并行
#### DP
##### EP
### 4.2_模型并行
#### TP
##### SP
#### PP










## thank you



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
#### TP
张量并行
#### PP
流水线并行
#### DP
数据并行
#### PCP
上下文并行（超长上下文）
![278](../images/Pasted%20image%2020260811153122.png)
#### EP
专家并行

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







## Worker
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





## 4_并行优化策略
### 4.1_模型不并行
#### DP
##### EP
### 4.2_模型并行
#### TP
##### SP
#### PP










## thank you

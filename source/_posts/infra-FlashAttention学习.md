这篇是我在学习triton算子的时候，开始正式学习flashattention的原理，发现有很多版本，所以单独写一篇来记录：

# 先验知识
MAC（Memory Access Cost，存储访问开销）

![](../images/Pasted%20image%2020260819194222.png)

# 朴素注意力算子
关于注意力计算，一开始我们已经学习了：
- 单头注意力self-Attention
- 多头注意力MHA
- 分组多头注意力GQA

我们原始的朴素注意力的计算，主要有3个阶段

![](../images/Pasted%20image%2020260819194652.png)

所以，一共包含8次HBM全局显存的读写操作

![574](../images/Pasted%20image%2020260819194731.png)


# v1

## softmax的更新
### 选用稳定版的softmatx
![](../images/Pasted%20image%2020260819195101.png)
### 分块向量中softmax的计算

x 向量，划分成 x1 + x2向量，不能单独计算各自的softmax(x1), softmax(x2)

x1向量，计算出m(x1), l(x1)后，仅保存这两个值，就不用保存x1向量的完整向量了
- m(x1)
	- x1向量的最大值
- l(x1)
	- 分母Σ和

**这里x1就处理完了，下面开始处理x2**

- 求出m(x2)
- 求出l(x2)

**之后开始处理更新全局**
- m(x) = max(m)
	- 从m(x1), m(x2)中选一个出来
- l(x),更新计算错误的那一个分母
	- 乘回去，重新除
	- ![389](../images/Pasted%20image%2020260819195716.png)


![](../images/Pasted%20image%2020260819195822.png)



![449](../images/Pasted%20image%2020260819195911.png)


![482](../images/Pasted%20image%2020260819200019.png)

上述其实是一个增量计算的过程。我们首先计算一个分块的局部softmax值，然后存储起来。当处理完下一个分块时，可以根据此时的新的**全局最大值**和**全局EXP求和项**来更新旧的softmax值。接着再处理下一个分块，然后再更新。当处理完所有分块后，此时的所有分块的softmax值都是“全局的”。


## flashattention

```txt
以下是我的理解：

我已经彻底理解了，未归一化的累加器，就是分块矩阵乘分数到V上的，就单单乘分数的分子，分数更新，由于每次都是只乘分子，所以直接把这个更新的alpha乘到旧的O_i就可以完成更新，最后统一除一个最新的全的l分母，至此，完成，本质上这就是一个把softmax的计算，拆分结合到分块矩阵乘里面，利用仅分子乘的乘法结合律的特性，每步更新历史的分数状态，因为是每步更新，所以历史分数里面，都始终是统一的上一轮更新上去的新分数，只要乘一个alpha就可以完成整体历史分数的修正，在O_i上，然后加上分块矩阵的乘法的当前一个分块，所以O_i里面的内容，应该这样看，是Σ（每个循环步的分数_该循环步对应的v_k）， 因为每个循环步的分数都是累计更新的，第一次只有j=0的分数，第二次j=1来了，j=0的分数乘上alpha，然后j=0的分数_v_0 加上这一次的j=1的分数_v_1, 然后j=2来了，j=0,1的分数都再次乘上alpha进行修正，然后加上j=2的分数_v_2, 这样一直累计更新。直到最后一步，O_i 直接除l_i， 这个一直累计的分母，得到我们真正的O_i
```

下面画个图解释一下
![](../images/Pasted%20image%2020260819234259.png)


那我们vllm里面的flashattention相较于朴素实现的flashattention有哪些结合的优化呢：
### pagedattention优化
朴素实现的标准flashattention, 输入都是直接一整块的张量显存，但是我们的kvcache张量线程，都已经是用block来统计的。

所以我们的flashattention传入的应该是slot_mappings，读写那个token的kvcache向量，就直接通过slot_mapping来跳转查找
### 变长batch
支持变长batching，朴素的batch发过来是，填充后的
req_0: 1,2,3, xx, xx, xx, xx
req_1: 43, 23,34,12, xx,xx
req_2:1, xx,xx,xx,xx,xx
这样每个req都是等长，然后内部挨个用mask来屏蔽计算的。

但是我们vllm有支持变长batch，所以发过来的就是input_ids的那样
[1, 2, 3, 43, 23, 34, 12, 1]
这样，然后通过各种索引映射表来区分那个是req0, 那个是req1, 哪个是req2

---


### kernel一次处理的多少req的问题

我们的
![](../images/Pasted%20image%2020260820002016.png)


## my-vllm里面的Qwen2Attention层实现
我们的Decode block里面，Qwen2DecoderLayer类里面主要分为两部分：
```python
class Qwen2DecoderLayer:
	self.self_attn = Qwen2Attention(config)
	self.mlp = Qwen2MLP(config)
	self.input_layernorm = RMSNorm(...)
	self.post_attention_layernorm = RMSNorm(...)
```
可以看到，Qwen2Model的一个layer的decode block里面，主要分成前面的注意力计算，以及后面的FFN的计算。

所以他是吧qkv投影放到注意力算子层里面一起实现的。
> 我们kuipa里面是用的matmul + gqa算子两层封装来凑起来的，vllm里面就一层封装


下面我们来看一下Qwen2Attention
```python
class Qwen2Attention:
	
	# 投影矩阵
	'''
	Q向量的维度， 可以与K/V向量的维度不一样， 但是K/V向量的维度一般相同
	'''
	self.q_proj = nn.Linear(hidden_size, q_size, bias)
	self.k_proj = nn.Linear(hidden_size, kv_size, bias)
	self.v_proj = nn.Linear(hidden_size, kv_size, bias)
	
	# 旋转位置编码
	self.rope_theta = config.rope_thera	

	# 多头注意力GQA的参数
	self.num_heads = config.num_attention_heads
	self.num_kv_heads = config.num_key_value_heads
	self.head_dim = config.hidden_size // config.num_attention_heads

	# 输出投影矩阵，投影回语义空间
	self.o_proj = nn.Linear(q_size, hidden_size, bias)
	
	# kvcache
	self.kv_cache: torch.Tensor
	'''
	注意，GQA里面，每个q_i头，都得到一个头的v_q_i,（这个v_q_i是通过和k头算权重，在v头上加权得到的，每个v_q_i都是一个head_dim向量）
	
	所以gqa的注意力输出，在进入O投影之前，就是和Q向量一样的维度。是q_size
	'''
```
![493](../images/Pasted%20image%2020260820221544.png)

注意，每个注意力层实例，<mark style="background:#fff88f">里面有一个关键的self.kv_cache : torch.Tensor</mark>

<mark style="background:#fff88f">这个就是model_runner在初始化kvcache后，划分出每层的tensor，然后reshape后，这个张量实例，就是保存到模型的每个注意力层的实例里面了</mark>


![513](../images/Pasted%20image%2020260820223529.png)

看一下前向推理，可以看到，我们这个注意力层的输入，不是向量，是一个张量，意味着这是<mark style="background:#fff88f">可以批量处理的</mark>， 一口气处理一整个batch的token向量

具体实现是，里面每个投影矩阵本身是nn.Linear，支持张量输入，批量处理，然后计算结果也是张量，

> `torch.Tensor.view()` 是在不改变底层数据的前提下，重新解释tensor的形状

> view 和 reshape的区别：
> view() 必须尽量共享原来的底层存储
> reshape()更灵活，必要时可以偷偷复制一份数据












# v2
# v3
# v4
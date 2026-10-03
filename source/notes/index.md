---
title: 笔记导航
---

建议从深度学习基础和 SFT 开始，经过 Transformer、CUDA 算子与性能分析，再进入 LLaMA、nano-vllm 和 my-vllm 推理系统。

## 深度学习与 SFT

- {% post_link "infra-深度学习基础-pytorch+python" "深度学习基础：PyTorch + Python" %}：从 Python、自动微分、数据集到模型训练，建立深度学习基础。
- {% post_link "大模型学习项目1-7B模型QLoRA指令微调-SFT" "7B 模型 QLoRA 指令微调（SFT）" %}：记录量化、LoRA、数据格式和 7B 模型指令微调项目。

## Transformer

- {% post_link "infra-Transformer 推理性能分析" "Transformer 推理性能分析" %}：梳理 Decoder-only 结构、注意力、FFN、KV Cache 与推理优化术语。

## CUDA、FlashAttention 与 Nsight

- {% post_link "infra-CUDA编程" "CUDA 编程" %}：从线程层级和内存模型开始，学习 softmax、reduce、matmul 等 CUDA 算子。
- {% post_link "infra-FlashAttention学习" "FlashAttention 学习" %}：沿着 online softmax、分块计算和 PagedAttention 理解高效注意力。
- {% post_link "infra-Nsight Compute学习笔记" "Nsight Compute 学习笔记" %}：以矩阵乘法 kernel 为例，记录性能指标和瓶颈分析方法。

## 工程基础

- {% post_link "infra-现代c++学习" "现代 C++ 学习" %}：整理类型推导、auto、智能指针、右值引用等现代 C++ 用法。
- {% post_link "infra-单元测试库GTest+glog" "GTest + glog 单元测试" %}：记录推理项目中的测试组织、断言和日志接入。
- {% post_link "infra-流畅的python-学习" "流畅的 Python 学习" %}：从 vLLM 学习中遇到的 Python 高级用法起步，当前仍在起步中。

## LLaMA、nano-vllm 与 my-vllm

- {% post_link "infra-基于cuda自制llama大模型推理框架" "基于 CUDA 自制 LLaMA 推理框架" %}：从 CMake、C++、CUDA 基础组件走向 tensor、算子和 kernel 设计。
- {% post_link "infra-nano-vllm 源码解读" "nano-vllm 源码解读" %}：通过 API、Engine、模型算子、TP 与 KV Cache 理解教学级推理引擎。
- {% post_link "infra-基于vllm的my-vllm大模型推理框架二次优化" "my-vllm 二次优化" %}：围绕 AsyncLLM、EngineCore、KV Cache 与 TP/PP/DP/EP、MoE 并行梳理 vLLM。

## 面试复盘

- {% post_link "infra-面经整理" "AI Infra 面经" %}：以图片整理 AI Infra 与大模型方向面试题，作为复盘入口。

嵌入式与操作系统笔记较多，可从现有分类树进入：[嵌入式](/categories/学习笔记/嵌入式/) · [嵌入式 / OS](/categories/学习笔记/嵌入式/OS/)。

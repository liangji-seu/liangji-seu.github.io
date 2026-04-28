---
title: ACM模式输入输出
date: 2026-04-14 09:08:33
categories: [学习笔记, 嵌入式, CPP] 
tags: [嵌入式, cpp]
---



# ACM输入输出模式
![alt text](../images/ACM模式输入输出-01-0428123440.png)

## 输入
### 指定输入个数
![alt text](../images/ACM模式输入输出-02-0428123440.png)

```c
int n;
cin >> n; // 读入3，说明数组的大小是3
vector<int> nums(n); // 创建大小为3的vector<int>
for(int i = 0; i < n; i++) {
	cin >> nums[i];
}

// 验证是否读入成功
for(int i = 0; i < nums.size(); i++) {
	cout << nums[i] << " ";
}
cout << endl;

```
### 不指定输入个数，以换行符 "\n" 结束
## 输出
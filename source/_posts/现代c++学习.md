
这个文档，主要用来记录学习现代c++的笔记，主要学习前4章的内容：
- 类型推导
- auto关键字
- 智能指针
- 右值引用
这几个章节，然后用c++重构nanovllm的引擎部分作为项目来练手


# 类型推导

类型推导，就是**编译器**自动帮你**推断变量是什么类型**，**不用你手动写类型**。

![237](../images/Pasted%20image%2020260518095537.png)

## c98和现代c++的区别
![258](../images/Pasted%20image%2020260518095655.png)

C++98只有一种类型推导规则：**函数模板**

在c11中，增加了两条规则：
- <mark style="background:#fff88f">auto</mark>
- <mark style="background:#fff88f">decltype</mark>

C++14**继续扩展**了 auto 和 decltype 的使用情况


## 模板类型推导
### 引用和指针上的类型推导

对于这样一个模板的类型推导
```cpp
template<typename T>
void f(ParamType param);

f(expr);
```

我们在给定表达式expr时，可以获得ParamType的类型，然后**基于ParamType来推导T的类型**。这就是类型推导。

但是这个有3种情况
#### ParamType 是指针/（非通用）引用

对于下面这三种情况

```cpp

template<typename T>

void f(T& param); // param是一个引用类型


// x是一个int， ParamType 是 int
int x = 27; 
f(x) // param = x

// cx是一个const int, ParamType 是 const int&
// T 推导为const int
const int cx = x; 
f(cx) // param = cx 

// rx是const int的引用, ParamType 是 const int&
// T 推到为const int
const int& rx = x; 
f(rx) // param = rx
```

解析如下：
![383](../images/Pasted%20image%2020260518102206.png)

规则总结：
- **`const` 会被保留，并且 “吃掉” 到 `T` 里**
    - 传 `const int` / `const int&` → `T` 推为 `const int`，`param` 为 `const int&`
    - 这样 `param` 不能被修改，保证了常量安全。
- **引用本身的 `&` 会被忽略**
    - 传 `int&` / `const int&` → 推导时 `&` 消失，`T` 只看被引用对象的类型。
    - 所以 `T` **永远不会被推成引用类型**，只会推成普通类型（带不带 `const` 看情况）。



#### ParamType 是 （通用）引用

```cpp
template<typename T>
void f(T&& param); // param现在是一个通用的引用

int x = 27; // 和之前一样
const int cx = x; // 和之前一样
const int& rx = x; // 和之前一样


f(x); // x是左值，所以T是int&
		// param的类型也是int&

f(cx); // cx是左值，所以T是const int&
		// param的类型也是const int&

f(rx); // rx是左值，所以T是const int&
		// param的类型也是const int&

f(27); // 27是右值，所以T是int
		// 所以param的类型是int&&
```

- **如果 expr 是一个左值**， T 和 ParamType(T&&) 都会**被推导成左值引用**。这有些不同寻常。
	- 第一，这是**模板类型 T** 被**推导成一个引用的唯一情况**。
	- 第二，尽管 ParamType 利用右值引用的语法来进行推导，但是他最终推导出来的类型是左值引用。
	
- **如果 expr 是一个右值**，那么就执行“普通”的法则（第一种情况）

<mark style="background:#fff88f">简单总结来说就是</mark>：
![](../images/Pasted%20image%2020260518102837.png)


> **引用**的本质，是别名，就是两个符号，对应同一块内存

| 特性                                                  | 引用（`int&`）                                                   | 指针（`int*`）            |
| :-------------------------------------------------- | :----------------------------------------------------------- | :-------------------- |
| **本质**                                              | 别名                                                           | 存储地址的变量               |
| <mark style="background:#fff88f">**必须初始化吗？**        | ✅ 必须，且只能绑定到一个对象                                              | ❌ 可以先声明后赋值    </mark> |
| <mark style="background:#fff88f">**能重新绑定吗？**        | ❌ 绑定</mark>后不能改，只能改绑定对象的值                                    | ✅ 可以随时指向别的地址          |
| <mark style="background:#fff88f">**是否可能为空？**</mark> | ❌ 不存在空引用（UB 除外）                                              | ✅ 可以是 `nullptr`       |
| **语法**                                              | 直接用 `.` 访问成员                                                 | 要用 `->` 访问成员          |
| **底层实现**                                            | <mark style="background:#fff88f">通常用指针实现</mark>，但编译器帮你隐藏了解引用 | 直接操作地址                |


> 什么是左值，右值
> **左值**：有名字、能取地址、可以出现在赋值号左边的值
> 	比如变量 `x`、`cx`、`rx`，都有名字，能 `&x` 取地址，是左值
> 	
> **右值**：临时的、没有名字、用完就消失的值，只能出现在赋值号右边
> 	比如字面量 `27`、表达式返回的临时对象 `x+1`，都没有名字，不能取地址，是右值
> 
> 一个简单判断方法：**能对它取 `&` 的，就是左值；不能的就是右值。**

所以x, cx, rx 都是左值，但是27是临时对象，所以是右值

> **左值引用**：Type& , 绑定到左值上
> 	![](../images/Pasted%20image%2020260518103601.png)
> **右值引用**：Type&&, 只能绑定到右值，目的是为了支持移动语义（`std::move`）
> 	![](../images/Pasted%20image%2020260518103554.png)



<mark style="background:#fff88f">总结</mark>

> <mark style="background:#fff88f">通用引用</mark> T&&
> 只有在模板参数推导的场景下，才叫通用引用，能同时绑定左值和右值
> **传递左值**给通用引用：
> 	`T` 被推导成 `Type&`，`ParamType` 变成 `Type& &&` 这里触发了引用折叠规则：**`& + && → &`**，所以最终 `ParamType` 是 `Type&`（左值引用）
> **传递右值**给通用引用：`T` 被推导成 `Type`，`ParamType` 变成 `Type&&`（右值引用）























#### ParamType 既不是指针也不是引用（按值传递）

当ParamType既不是指针，也不是引用，我们把他处理成pass-by-value

```cpp
template<typename T>
void f(T param);
```
这就意味着 param 就是完全传给他的参数的**一份拷贝**,一个完全新的对象

规则如下：
- **忽略引用特性**：如果传入的 `expr` 是个引用，推导时会直接把 `&` 去掉，只看底层的类型。
- **忽略顶层 `const`/`volatile`**：如果去掉引用后，类型带有 `const`/`volatile`（顶层），也会被忽略。

因为本质上就是形参拷贝了，所以不关心这些原本的性质了。

举例(特殊)：
![396](../images/Pasted%20image%2020260518104329.png)

- `const char*`：修饰的是**指针指向的内容**，表示 `ptr` 指向的 `char` 是不可修改的（底层 const）。
- `* const ptr`：修饰的是**指针本身**，表示 `ptr` 这个变量本身的值（地址）不可修改（顶层 const）。

会**忽略顶层的 `const`/`volatile`**，但会保留底层的 `const`/`volatile`。

因为 `param` 是原对象的拷贝，原对象 “本身不可修改” 的特性（顶层 const）对拷贝出来的新对象没有约束，所以会被去掉；但 “指向的对象不可修改” 的特性（底层 const）是类型的一部分，必须保留

**所以，T被推导成 const char*, 表示这块内存不可修改，但是指针本身是可以重定向的**。


### 数组参数
一般我们用的时候，我们把数组当作指向第一个元素的指针。
![](../images/Pasted%20image%2020260518104642.png)

实际上，`name`的类型是 `const char[13]`, 而不是`const char*`,  但是因为数组到指针的退化规则，代码会被正常编译。

但是如果数组类型，被传递给一个模板参数，类型推导会怎么样呢？
![](../images/Pasted%20image%2020260518104836.png)

因为数组参数声明会被当做指针参数，传递给模板函数的按值传递的**数组参数**会被**退化成指针类型**。这就意味着在模板 f 的调用中，模板参数 T 被推导成 `const char*` ：
![](../images/Pasted%20image%2020260518105106.png)

#### 特例
![](../images/Pasted%20image%2020260518105124.png)

**T最后推导出来的实际的类型就是数组** `const char [13]`

函数 f 的参数（数组的引用）被推导成了 `const char(&)[13]`

这个特例的使用
```cpp
//在编译的时候返回数组的长度（数组参数没有名字，
//因为只关心数组包含的元素的个数）
template<typename T, size_t N>
constexpr size_t arraySize(T (&)[N]) noexcept{
	return N;
}
```
声明数组的引用可以使的创造出一个推导出一个**数组包含的元素长度**的模板![](../images/Pasted%20image%2020260518105619.png)


定义为 `constexpr` 说明函数**可以在编译的时候得到其返回值**
![](../images/Pasted%20image%2020260518105840.png)


### 函数参数

数组不是唯一可以退化成指针的东西，函数类型也可以被退化成函数指针。
![](../images/Pasted%20image%2020260518105925.png)




### 总结
![](../images/Pasted%20image%2020260518110305.png)


## auto类型推导
了解了模板类型推导，auto的类型推导基本所有的内容。

**因为除了第一个例外，auto类型推导就是模板类型推导**

模板类型推导和 auto 类型推导是有<mark style="background:#fff88f">一个直接的映射</mark>


他们的对应关系是：

|auto 写法|对应的模板形式|
|:--|:--|
|`auto x = expr;`|`template<typename T> void f(T param); f(expr);`|
|`const auto cx = expr;`|`template<typename T> void f(const T param); f(expr);`|
|`auto& rx = expr;`|`template<typename T> void f(T& param); f(expr);`|
|`auto&& urx = expr;`|`template<typename T> void f(T&& param); f(expr);`|
也就是说：
- `auto` 就相当于模板里的 `T`
- `auto` 前面 / 后面的 `const`/`&`/`&&`，就相当于模板里的 `ParamType`

### 左值引用
<mark style="background:#fff88f">（auto& a = xxx， const保留，&丢）</mark>
T& x = expr
和模板类型推导规则一样：
- 保留 `expr` 的 `const` 特性
- 忽略 `expr` 本身的引用特性&




### 通用引用
T&& x = expr
和模板类型推导规则一样：
- `expr` 是左值 → auto 推成左值引用（**引用折叠**）
- `expr` 是右值 → auto 推成普通类型，最终是右值引用

### 按值传递
<mark style="background:#fff88f">（auto a = xxx， const，&全丢）</mark>
T x =expr
`auto x = expr;
- 忽略 `expr` 的引用特性
- 忽略顶层 `const`/`volatile`(因为拷贝出来的对象，没有约束)
- 底层 `const` 会保留

### 唯一的例外
这是 auto 和模板推导唯一不一样的地方：

- 模板推导不支持**初始化列表** `{}`
- auto 支持，并且会把 `auto x = {expr};` 推成 `std::initializer_list<T>`

![](../images/Pasted%20image%2020260518111919.png)

##### 初始化列表{}
这个是c++11的新特性

**用{} 给变量赋值，就是初始化列表**

c98的写法：
![](../images/Pasted%20image%2020260518112601.png)


c11之后
![](../images/Pasted%20image%2020260518112616.png)
这种 `{}` 形式，就叫 **初始化列表**。


对于`auto x = {1,2,3}`
`auto`推导出来的类型是：`std::initializer_list<int>`

它是一个**C++11 新增的模板类型**，用来表示 “一堆值的集合”。


总结，auto对{}的推导为：
![](../images/Pasted%20image%2020260518112806.png)
![](../images/Pasted%20image%2020260518112851.png)
而模板是不能推导{}的，这就是auto和模板推导唯一的区别了

而<mark style="background:#fff88f">初始化列表这个类型，是c++11专门给容器，函数传参涉及的，统一批量传值工具</mark>， 其本质，就是一个临时，只读，轻量的值列表，目的仅仅用来初始化和传参

![251](../images/Pasted%20image%2020260518113050.png)

还有一个好处，<mark style="background:#fff88f">就是让传参的形式统一：</mark>

![206](../images/Pasted%20image%2020260518113136.png)



## decltype

给定一个变量名或者表达式， `decltype` 会告诉你这个**变量名或表达式**的**类型**，不会做任何模板 /auto 那样的推导修改

和 `auto` 对比一下：

- `auto`：会做推导，忽略引用、顶层 const（按值传递时）
- `decltype`：**不推导、不修改**，表达式是什么类型，就返回什么类型。

![447](../images/Pasted%20image%2020260518132715.png)
> 注意，[]操作符的返回值是引用



### （c++11）核心的用途：尾置返回类型

在c++11之前，我写一个函数，接受一个容器，返回索引i的引用
```cpp
？？？ authAndAccess(Container& c, Index i){
	return c[i];//返回一个引用
}
```
可以发现，如果我想返回一个引用，肯定函数的类型是`ParamType& `

这就带来一个问题，我这是模板函数，**我还不知道输入的容器的类型呢**。这就没办法

**c++11里面，用`decltype` + `尾置返回类型`解决**

C++11 引入了 `-> decltype(...)` 语法，把返回类型写在函数参数后面：

```cpp
template<typename Container, typename Index>
auto authandaccess(Container& c, Index i) -> decltype(c[i]) {
	return c[i]; //容器c用[]运算符获得的c[i]，是引用
}
```
- `auto` 只是占位符，真正的返回类型由 `decltype(c[i])` 决定
- `decltype(c[i])` 会原封不动地返回 `c[i]` 的类型（比如 `int&`）

### c++14的用法：自动用decltype规则推导

c++14进一步简化了上面的写法，引入`decltype(auto)`

```cpp
template<typename Container, typename Index>
decltype(auto) authandaccess(Container& c, Index i){
	return c[i]; //容器c用[]运算符获得的c[i]，是引用
}
```
- 像 `auto` 一样自动推导返回类型
- 但**使用 `decltype` 的推导规则**（不忽略引用、const）

> 疑问：既然都是推导类型，那为什么直接用auto不行？
> 
> 因为c[i]返回的是xxx类型的引用，比如int&, 如果用auto进行模板规则的推导，会走左值推导，得出int的结果
> 
> 而 `decltype(auto)` 会保留 `int&`，完美解决这个问题。


### decltype的坑：（）会改变结果
![449](../images/Pasted%20image%2020260518133849.png)
- 对变量名直接用 `decltype`，返回它的声明类型
- 对变量加括号，就变成了 “左值表达式”，`decltype` 会返回 `T&`

![](../images/Pasted%20image%2020260518133940.png)
所以，如果是返回局部变量的值，就不能加（）, 否则会返回引用。

### 总结
![](../images/Pasted%20image%2020260518134046.png)

## auto关键字
一些 auto 类型的推导结果虽然完成符合规定的算法，但是从程序员的角度来看是错误的

如何引导 auto 得到正确的结果是很重要

这里包含了所有 auto 的输入和输出

### 优先使用auto，不是显式类型声明

这里说明的是auto解决了**老式c++里面变量声明**的两大痛点：
- 复杂类型写起来麻烦
- 容易忘记初始化
![469](../images/Pasted%20image%2020260518141516.png)


auto的解决办法是：
- 自动推导类型，不用写复杂名字
- 强制初始化，从根源上避免未定义行为
![](../images/Pasted%20image%2020260518141607.png)


#### auto可以持有编译器才知道的类型（Lambda）
Lambda 表达式的类型是编译器内部生成的匿名类型
![381](../images/Pasted%20image%2020260518141904.png)

- `auto` 会直接推导为 Lambda 的原生类型，**没有额外开销，调用更快**
- `std::function` 是一个类型擦除的包装器，会有额外的内存开销和调用成本，而且代码写起来更繁琐

#### `auto` 能避免 “类型截断 / 不匹配” 的隐性错误
![](../images/Pasted%20image%2020260518142133.png)

![](../images/Pasted%20image%2020260518142225.png)

#### 重构代码更简单

![](../images/Pasted%20image%2020260518142320.png)




### auto不能用的特殊情况
<mark style="background:#fff88f">**代理类**</mark>

**auto 不是万能的，遇到「代理类」这类特殊场景，它会推导出错误类型，这时候需要用`static_cast`手动修正**


![](../images/Pasted%20image%2020260518144242.png)

除了这个，还有其他情况，也有有代理类来做优化
![397](../images/Pasted%20image%2020260518145012.png)
![389](../images/Pasted%20image%2020260518145518.png)
#### 解决办法
##### 显示类型初始化原则
用 `static_cast` 强制把表达式转换成你想要的类型，再给 `auto` 推导：![](../images/Pasted%20image%2020260518145332.png)
- `static_cast<bool>` 会把代理类转换成真正的 `bool`
- `auto` 再推导出 `bool`，彻底避免持有代理类

**总结**：
`auto` 会推导出表达式的真实类型，而不是你 “期望” 的类型。当遇到代理类这类特殊场景时，需要用 `static_cast` 显式转换，把它变成你想要的类型，再交给 `auto`。




## 使用现代C++
### 统一初始化{}
这里就是统一用{}来初始化。

C++11之前，初始化语法比较混乱。

<mark style="background:#affad1">为什么需要{}来统一初始化</mark>
原来的初始化是这样子的：

![](../images/Pasted%20image%2020260518150114.png)
很乱。

我们用{}，被称为统一初始化，因为**它可以用于任何地方**：
- 非静态数据成员指定默认值
- 初始化不可复制的对象（如 `std::atomic`）等

<mark style="background:#fff88f">优势 1：阻止“变窄转换”（Narrowing Conversions）</mark>
![491](../images/Pasted%20image%2020260518150340.png)
![409](../images/Pasted%20image%2020260518150536.png)



<mark style="background:#fff88f">优势 2：免疫 C++ 史上最令人头疼的解析（Most Vexing Parse）</mark>
在 C++ 中有一条让无数新手掉坑的规则：“**任何可以解析为函数声明的东西，都会被解析为函数声明**”。
![531](../images/Pasted%20image%2020260518150352.png)


##### 特殊情况
不是所有情况的初始化，都可以使用{}来初始化的。

因为{1，2，3}这种，本质上就是一个初始化列表的对象。

但是，如果你的类初始化的参数里面，有一个接收初始化列表的，这样在调用构造函数的时候，编译器就会优先匹配它。

![396](../images/Pasted%20image%2020260518151149.png)

![469](../images/Pasted%20image%2020260518151205.png)

##### 默认构造函数与空{}

如果一个类既有默认构造函数，又有 `std::initializer_list` 构造函数，那么**空的 `{}` 意味着调用默认构造函数，而不是传入一个空的`initializer_list`**。
![474](../images/Pasted%20image%2020260518151315.png)





### nullptr

现代c++, 如果想要表示空指针，永远只用nullptr

抛弃了0, NULL 

#### 抛弃0，NULL的原因

<mark style="background:#affad1">根本原因：类型冲突</mark>
c++里面，0，NULL， 本质上都是int，都不是指针类型。所以在函数重载的时候引发灾难
![492](../images/Pasted%20image%2020260518152202.png)

当你写下 `f(NULL)` 时，你的本意是想调用指针版本的函数，但编译器却把它当成整数传给了 `f(int)`。这不仅违背直觉，还可能导致难以察觉的 Bug。

而 `nullptr` 的优势：
`nullptr` 的类型是 `std::nullptr_t`，它可以隐式转换为**任何**指针类型（如 `int*`, `Widget*` 等），但它**绝对不会**被视为一个整数

![461](../images/Pasted%20image%2020260518152248.png)


<mark style="background:#affad1">模板类型推导失效</mark>
![459](../images/Pasted%20image%2020260518152353.png)

<mark style="background:#affad1">代码可读性</mark>
使用 `nullptr` 能让代码意图瞬间清晰。
![](../images/Pasted%20image%2020260518152425.png)



### 声明别名using
在原来的c98里面，我们使用typedef来给类型起别名

但是在现代c++中，使用using 别名声明

因为 `typedef` 在泛型编程（模板）中存在着致命的设计缺陷

#### typedef的缺陷

<mark style="background:#affad1">可读性：尤其是处理函数指针的时候</mark>

在底层开发或系统级编程中，我们经常需要**处理回调函数**或**中断处理函数**

- 用 `typedef` 定义函数指针的语法非常反人类，名字被“埋”在了中间；
- 而 `using` 则保持了清晰的“左边是名字，右边是值”的直觉逻辑。
![465](../images/Pasted%20image%2020260518152934.png)


正常回调的使用案例, 写起来更加简洁
```cpp
#include<iostream>
#include<vector>
#include<string>
using namespace std;


class Button {

public:
	//typedef void (*ClickCallback)(int, int);
	using ClickCallback = void(*)(int, int);

	//绑定回调函数
	void setClick(ClickCallback cb) {
		this->cb = cb;
	}

	//触发回调
	void click() {
		if (cb)
			cb(100, 200);
	}
private:
	ClickCallback cb;
};

void onClick(int x, int y) {
	cout << "click callback" << endl;
}



int main() {

	Button btn;

	//绑定回到
	btn.setClick(onClick);
	btn.click();
	return 0;
}
```

---

<mark style="background:#affad1">模板别名的使用</mark>
这是 `using` 碾压 `typedef` 的根本原因。

当你在实现**自定义的容器**（比如某种基于智能指针的链表、或者自定义的 HashMap）时，你通常**希望给一个带有自定义分配器的模板类**起个**简短的**名字。

![433](../images/Pasted%20image%2020260518161554.png)

**但是typedef却不支持直接模板化**

所以，你不能写成：
```cpp
templete<typename T> 
typedef sdt::list<T, std::allocator<T>> MyCustomList;
```
根本原因 ——**`typedef` 不支持模板别名, C98就不支持，而 `using` 支持**，

C++11 引入的 `using` 别名声明，天然支持模板化，也就是我们常说的**模板别名（Alias Templates）**


---
<mark style="background:#affad1">终结 `typename` 和 `::type` 的噩梦</mark>

![389](../images/Pasted%20image%2020260518162302.png)
![392](../images/Pasted%20image%2020260518162158.png)

> 注意这里，使用这个类型的时候，必须要typename xxx，编译器才能通过，直到这是你的模板。

你在模板里写 `MyCustomList_C98<T>::type` 时，编译器会一脸懵
- `MyCustomList_C98<T>` 是个模板，编译器不知道它里面的 `::type` 是**类型**，还是**静态成员变量**
- 比如它可能是 `int`，也可能是一个静态的 `int` 变量名，编译器没法判断

这种 “依赖于模板参数 `T`，编译器无法直接判断的名字”，就叫**依赖类型（Dependent Type）**
> 是因为T未知，编译阶段还没有实例，自然也就没有类型。


而使用`using` 支持直接定义模板别名，编译器**100% 确定它就是个类型**

![393](../images/Pasted%20image%2020260518162522.png)

|写法|模板里使用时|可读性|编译器理解成本|
|:--|:--|:--|:--|
|`typedef + 结构体`|`typename MyCustomList_C98<T>::type`|差|高，必须你加 `typename` 提示|
|`using` 模板别名|`MyCustomList<T>`|好|低，编译器直接知道是类型|


<mark style="background:#affad1">C++14 里全面引入 `using` 模板别名</mark>

**C++ 标准库为了解决 `typedef` 和 `typename`/`::type` 的麻烦，在 C++14 里全面引入 `using` 模板别名**，把类型特征（Type Traits）的写法彻底简化了


C++11 引入了 `<type_traits>` 头文件，用来操作类型（比如移除引用、移除 const、判断是否是指针等），但它的实现是基于 `typedef` 的老路子，导致使用起来非常麻烦


![](../images/Pasted%20image%2020260518163559.png)

相当于给你省略了创建别名的方法，














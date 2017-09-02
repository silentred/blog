---
title: Go Assembly 学习笔记
date: 2017-09-02 15:56:48
categories:
- tech
- golang
tags:
- golang
- assembly
---

> 最近升级 go1.9，发现一个获取 goroutine id 的依赖没有支持1.9，于是手动写了一个，顺便学习一下 go assembly。希望你看完这篇文章后，对go汇编有一定的了解。

<!-- more -->

# Go Assembly

首先安利一个获取当前goroutine id 的library, [gid](http://github.com/silentred/gid)，支持 go1.7 - go1.9, 可能是目前最小的库了，使用也很简单: `id := gid.Get()`。

Go汇编语法类似 Plan 9，它不是对机器语言的直接表达，拥有半抽象的指令集。总体来说， machine-specific 操作一般就是它们的本意，其他概念例如 memory move, subroutine call, return 是抽象的表达。

## 常量

evaluation 优先级和 C 不同，例如 3&1<<2 == 4, 解释为 (3&1) << 2。
常量被认为是 unsigned 64-bit int, 因此 -2 不是负数，而是被作为 uint64 解读。

## 符号

4个预定义的符号，表示 pseudo-registers, 伪寄存器（虚拟寄存器？）。

- FP: frame pointer, 参数和本地变量
- PC: program counter: 跳转，分支
- SB: static base pointer: 全局符号
- SP: stack pointer: 栈顶

用户定义的符号都是通过偏移(offset)来表示的。

SB寄存器表示全局内存起点，foo(SB) 表示 符号foo作为内存地址使用。这种形式用于命名 全局函数，数据。`<>`限制符号只能在当前源文件使用，类似 C 中的 static。`foo+4(SB)`表示foo 往后 4字节的地址。

FP寄存器指向函数参数。0(FP)是第一个参数，8(FP)是第二个参数(64-bit machine). `first_arg+0(FP)`表示把第一个参数地址绑定到符号 first_arg, 这个与SB的含义不同。

SP寄存器表示栈指针，指向 top of local stack frame, 所以 offset 都是负数，范围在 [ -framesize, 0 ), 例如 x-8(SP). 对于硬件寄存器名称为SP的架构，`x-8(SP)` 表示虚拟栈指针寄存器， `-8(SP)` 表示硬件 SP 寄存器.

跳转和分支是针对PC的offset，或者 label, 例如:
```
label:
	MOVW $0, R1
	JMP label
```
label 范围是函数级别的，不同函数可以定义相同名称的label。

## 指令

例如：
```
TEXT runtime·profileloop(SB),NOSPLIT,$8
	MOVQ	$runtime·profileloop1(SB), CX
	MOVQ	CX, 0(SP)
	CALL	runtime·externalthreadhandler(SB)
	RET
```

TEXT 指令定义符号 `runtime·profileloop`, RET 表示结尾，如果没声明，linker会添加 jump-to-self 指令。
$8 表示 frame size,一般后面需要加上参数大小。这里因为有 NOSPLIT，可以不加。

全局数据符号用 DATA 声明，方式为 `DATA	symbol+offset(SB)/width, value`
GLOBL 定义数据为全局。例如：

```
DATA divtab<>+0x00(SB)/4, $0xf4f8fcff
DATA divtab<>+0x04(SB)/4, $0xe6eaedf0
...
DATA divtab<>+0x3c(SB)/4, $0x81828384
GLOBL divtab<>(SB), RODATA, $64

GLOBL runtime·tlsoffset(SB), NOPTR, $4
```
定义并初始化了 divtab<>, 一个 只读的 64字节 表，每一项4字节。定义了 runtime·tlsoffset， 4字节空值，非指针。

指令有一个或两个参数。如果有两个，第一个是 bit mask, 可以为数字表达式。值的定义如下：

- NOPROF = 1 ; (For TEXT items.) Don't profile the marked function. This flag is deprecated. 废弃
- DUPOK = 2 ; It is legal to have multiple instances of this symbol in a single binary. The linker will choose one of the duplicates to use. 此符号允许存在多个，链接器选择其一使用。
- NOSPLIT = 4 ; (For TEXT items.) Don't insert the preamble to check if the stack must be split. The frame for the routine, plus anything it calls, must fit in the spare space at the top of the stack segment. Used to protect routines such as the stack splitting code itself. 不插入代码，不检查是否需要 stack split. (疑问，高版本go使用连续栈，这个指令还有作用吗？)
- RODATA = 8 ; (For DATA and GLOBL items.) Put this data in a read-only section. 数据存入只读区
- NOPTR = 16 ; (For DATA and GLOBL items.) This data contains no pointers and therefore does not need to be scanned by the garbage collector. 表示非指针，不需要 GC。
- WRAPPER = 32 ; (For TEXT items.) This is a wrapper function and should not count as disabling recover. 
- NEEDCTXT = 64 ; (For TEXT items.) This function is a closure so it uses its incoming context register.

# Example: Add

```go
//main.go
package main
import "fmt"
func add(x, y int64) int64
func main() {
    fmt.Println(add(2, 3))
}
```

```asm
// add.s
TEXT ·add(SB),$0-24
    MOVQ x+0(FP), BX
	MOVQ y+8(FP), BP
    ADDQ BP, BX
    MOVQ BX, ret+16(FP)
    RET

```

定义一个函数的方式为： `TEXT package_name·function_name(SB),$frame_size-arguments_size`
例子中 package_name 是空，表示当前package。 之后是一个 middle point(U+00B7) 和 函数名称。
frame_size 是 $0, 表示了需要 stack 的空间大小，这里是0， 表示不需要stack，只使用 寄存器。函数的参数和返回值的大小为 `3 * 8 = 24` bytes。

`MOVQ` 表示移动一个 64bit 的值(Q 代表 quadword)。这里是从 FP(frame pointer, 指向 函数参数的起始位置) 移动到 `BX` 和 `BP`. 语法 `symbol+offset(register)` 中的 offset, 代表了从 register 为起点，移动 offset后的地址。这里的 x, y 是在函数定义中的参数符号。

`ADDQ` 那一行指令 表示把两个 64bit register的值相加，存到 BX。

最后的 `MOVQ` 把 BX 中的值，移动到 FP+16的位置， 这里的 `ret` 符号是编译器默认的返回值符号。

# Example: Hello

```go
package main

import _ "fmt"
func hello()

func main(){
    hello()
}
```

```asm
#include "textflag.h"

DATA world<>+0(SB)/8, $"hello wo"
DATA world<>+8(SB)/4, $"rld "

GLOBL world<>+0(SB), RODATA, $12

// 需要 stack空间 88字节，没有参数和返回值
TEXT ·hello(SB),$88-0
	SUBQ	$88, SP
	MOVQ	BP, 80(SP)
	LEAQ	80(SP), BP
    // 创建字符，存在 my_string
    LEAQ	world<>+0(SB), AX 
	MOVQ	AX, my_string+48(SP)        
	MOVQ	$11, my_string+56(SP)
	MOVQ	$0, autotmp_0+64(SP)
	MOVQ	$0, autotmp_0+72(SP)
	LEAQ	type·string(SB), AX
	MOVQ	AX, (SP)
	LEAQ	my_string+48(SP), AX        
	MOVQ	AX, 8(SP)
    // 创建一个 interface
    CALL	runtime·convT2E(SB)           
	MOVQ	24(SP), AX
	MOVQ	16(SP), CX                    
	MOVQ	CX, autotmp_0+64(SP)        
	MOVQ	AX, autotmp_0+72(SP)
	LEAQ	autotmp_0+64(SP), AX        
	MOVQ	AX, (SP)                      
	MOVQ	$1, 8(SP)                      
	MOVQ	$1, 16(SP)
    // 调用 fmt.Println
    CALL	fmt·Println(SB)

    MOVQ 80(SP), BP
	ADDQ $88, SP
	RET

```

第一行的 `#include` 加载一些常量，这里我们将用到 `RODATA`. 

`DATA` 用于在内存中存储字符串，一次可以存储 1,2,4或8 字节。在符号后的`<>`作用是限制数据在当前文件使用。

`GLOBL` 将数据设为全局，只读，相对位置12.


# Example: gid

gid 库中用到的函数

```
#include "go_asm.h"
#include "go_tls.h"
#include "textflag.h"

// 返回值 8 bytes, 符号为 getg
TEXT ·getg(SB), NOSPLIT, $0-8
    // get_tls 的宏为： #define	get_tls(r)	MOVQ TLS, r
    // 等价于 MOVQ TLS, CX
    // 从 TLS(Thread Local Storage) 起始移动 8 byte 值 到 CX 寄存器
    get_tls(CX)
    // g的宏为： g(r)	0(r)(TLS*1)
    // 等价于 0(CX)(TLS*1), AX
    // 查到意义为 indexed with offset, 这里 offset=0, 索引是什么意思不清楚
    MOVQ    g(CX), AX
    // 从AX起始移动 8 byte 值，到ret符号的位置
    MOVQ    AX, ret+0(FP)
    RET

```

# Example: SwapInt32

一个原子交换 int32 的函数

```go
package atomic
import (
    "unsafe"
)

func SwapInt32(addr *int32, new int32) (old int32)
```

```
#include "textflag.h"
// 参数大小 = 8 + 4 + 4 , + 4 (默认的 ret符号?)
TEXT ·SwapInt32(SB),NOSPLIT,$0-20
	JMP	·SwapUint32(SB)
TEXT ·SwapUint32(SB),NOSPLIT,$0-20
    // 第一个参数 移动 8 byte 到 BP
	MOVQ	addr+0(FP), BP
    // 第二个参数 移动 4 byte 到 AX
	MOVL	new+8(FP), AX
    // 原子操作, write-after-read, 把 (AX, offset=0) 与 (BP, offset=0) 交换 4 byte 数据
	XCHGL	AX, 0(BP)
    // 移动 AX 到 old 符号
	MOVL	AX, old+16(FP)
	RET
```
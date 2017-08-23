---
title: 关于Go语言channel与select
date: 2017-08-23 14:25:34
categories:
- tech
- golang
tags:
- golang
- channel
---

> 本文会尝试解释 go runtime 中 channel 和 select 的具体实现，部分内容来自 gophercon2017。Go版本为1.8.3

<!-- more -->

# channel

第一部分讲述一下 channel 的用法。channel 可以看做一个队列，用于多个goroutine之间的通信，例如下面的例子，一个goroutine发送msg，另一个msg接受消息。channel 分为带缓冲和不带缓冲，我认为差别不是很大，具体请自行google。

channel的功能点：
1. 队列
2. 当超过buffer长度时阻塞
3. 当一端阻塞，可以被另一个端唤醒

我们围绕这3点功能展开，讲讲具体的实现。

```go
package main

import "fmt"

func main() {
    // Create a new channel with `make(chan val-type)`.
    // Channels are typed by the values they convey.
    messages := make(chan string)
    // _Send_ a value into a channel using the `channel <-`
    // syntax. Here we send `"ping"`  to the `messages`
    // channel we made above, from a new goroutine.
    go func() { messages <- "ping" }()
    // The `<-channel` syntax _receives_ a value from the
    // channel. Here we'll receive the `"ping"` message
    // we sent above and print it out.
    msg := <-messages
    fmt.Println(msg)
}
```

## channel结构

注释标注了几个重要的变量，从功能上大致可以分为两个功能单元，一个是 ring buffer，用于存数据； 一个是存放 goroutine 的队列。

```go
type hchan struct {
	qcount   uint           // 当前队列中的元素个数
	dataqsiz uint           // 缓冲队列的固定大小
	buf      unsafe.Pointer // 缓冲数组
	elemsize uint16
	closed   uint32
	elemtype *_type // element type
	sendx    uint   // 下一次发送的 index
	recvx    uint   // 下一次接收的 index
	recvq    waitq  // 接受者队列
	sendq    waitq  // 发送者队列

	// lock protects all fields in hchan, as well as several
	// fields in sudogs blocked on this channel.
	//
	// Do not change another G's status while holding this lock
	// (in particular, do not ready a G), as this can deadlock
	// with stack shrinking.
	lock mutex
}
```

## Ring Buffer

主要是以下变量组成的功能, 一个 buf 存储实际数据，两个指针分别代表发送，接收的索引位置，配合 size, count 在数组大小范围内来回滑动。

```go
qcount   uint           // 当前队列中的元素个数
dataqsiz uint           // 缓冲队列的固定大小
buf      unsafe.Pointer // 缓冲数组
sendx    uint   // 下一次发送的 index
recvx    uint   // 下一次接收的 index
```

举个例子，假设我们初始化了一个带缓冲的channel, `ch := make(chan int, 3)`， 那么它初始状态的值为:
```go
qcount   = 0
dataqsiz = 3
buf      = [3]int{0， 0， 0} // 表示长度为3的数组
sendx    = 0
recvx    = 0
```

第一步，向 channel 里 send 一个值， `ch <- 1`, 因为现在缓冲还没满，所以操作后状态如下:
```go
qcount   = 1
dataqsiz = 3
buf      = [3]int{1， 0， 0} // 表示长度为3的数组
sendx    = 1
recvx    = 0
```

快进两部，连续向 channel 里 send 两个值 (2, 3)，状态如下：
```go
qcount   = 3
dataqsiz = 3
buf      = [3]int{1， 2， 3} // 表示长度为3的数组
sendx    = 0 // 下一个发送的 index 回到了0
recvx    = 0
```

从 channel 中 receive 一个值， `<- ch`, 状态如下:
```go
qcount   = 2
dataqsiz = 3
buf      = [3]int{0， 2， 3} // 表示长度为3的数组
sendx    = 0 // 下一个发送的 index 回到了0
recvx    = 1
```

## 阻塞

我们看下，如果 receive channel 时，channel 的 buffer中没有数据是怎么处理的。逻辑在 `chanrecv` 这个方法中，它的大致流程如下，仅保留了阻塞操作的代码。

```go
func chanrecv(t *chantype, c *hchan, ep unsafe.Pointer, block bool) (selected, received bool) {
    // 检查 channdel 是否为 nil
    
    // 当不阻塞时，检查buffer大小，当前大小，检查chennel是否关闭，看看是否能直接返回

    // 检查发送端是否有等待的goroutine，下部分会提到

    // 当前buffer中有数据，则尝试取出。
	
    // 如果非阻塞，直接返回

    // 没有sender等待，buffer中没有数据，则阻塞等待。
	gp := getg()
	mysg := acquireSudog()
	mysg.releasetime = 0
	if t0 != 0 {
		mysg.releasetime = -1
	}
	// No stack splits between assigning elem and enqueuing mysg
	// on gp.waiting where copystack can find it.
	mysg.elem = ep
	mysg.waitlink = nil
	gp.waiting = mysg
	mysg.g = gp
	mysg.selectdone = nil
	mysg.c = c
	gp.param = nil
	c.recvq.enqueue(mysg)
    //关键操作：设置 goroutine 状态为 waiting, 把 G 和 M 分离
	goparkunlock(&c.lock, "chan receive", traceEvGoBlockRecv, 3)

	// someone woke us up
    // 被唤醒，清理 sudog
	if mysg != gp.waiting {
		throw("G waiting list is corrupted")
	}
	gp.waiting = nil
	if mysg.releasetime > 0 {
		blockevent(mysg.releasetime-t0, 2)
	}
	closed := gp.param == nil
	gp.param = nil
	mysg.c = nil
	releaseSudog(mysg)
	return true, !closed
}
```

这里的操作就是 创建一个 当前 goroutine 的 sudog, 然后把这个 sudog 放入 channel 的接受者等待队列；设置当前 G 的状态，和 M分离，到这里当前G就阻塞了，代码不会执行下去。
当被唤醒后，执行sudog的清理操作。这里接受buffer中的值的指针是 `ep` 这个变量，被唤醒后好像没有向 `ep` 中赋值的操作。这个我们下部分会讲。

## sudog

还剩最后一个疑问，当一个goroutine因为channel阻塞，另一个goroutine是如何唤醒它的。

channel 中有两个 `waitq` 类型的变量, 看下结构发现，就是sudog的链表，关键是 sudog。sudog中包含了goroutine的引用，注意一下 `elem`这个变量，注释说可能会指向stack。

```go
type waitq struct {
	first *sudog
	last  *sudog
}

type sudog struct {
	// The following fields are protected by the hchan.lock of the
	// channel this sudog is blocking on. shrinkstack depends on
	// this.
	g          *g
	selectdone *uint32 // CAS to 1 to win select race (may point to stack)
	next       *sudog
	prev       *sudog
	elem       unsafe.Pointer // data element (may point to stack)

	// The following fields are never accessed concurrently.
	// waitlink is only accessed by g.

	acquiretime int64
	releasetime int64
	ticket      uint32
	waitlink    *sudog // g.waiting list
	c           *hchan // channel
}
```

讲阻塞部分的时候，我们看到goroutine被调度之前，有一个 `enqueue`操作，这时，当前G的sudog已经被存入`recvq`中，我们看下发送者这时的操作。

这里的操作是，sender发送的值 直接被拷贝到 sudog.elem 了。然后唤醒 sudog.g ，这样对面的receiver goroutine 就被唤醒了。具体请下面的注释。

```go
func chansend(t *chantype, c *hchan, ep unsafe.Pointer, block bool, callerpc uintptr) bool {
	// 检查工作

    // 如果能从 chennel 的 recvq 弹出 sudog, 那么直接send
	if sg := c.recvq.dequeue(); sg != nil {
		// Found a waiting receiver. We pass the value we want to send
		// directly to the receiver, bypassing the channel buffer (if any).
		send(c, sg, ep, func() { unlock(&c.lock) })
		return true
	}

	// buffer有空余空间，返回； 阻塞操作
}

func send(c *hchan, sg *sudog, ep unsafe.Pointer, unlockf func()) {
	// 处理 index

    // 关键
	if sg.elem != nil {
        // 这里是根据 elemtype.size 复制内存
		sendDirect(c.elemtype, sg, ep)
		sg.elem = nil
	}

	// 一些处理

    // 重新设置 goroutine 的状态，唤醒它
	goready(gp, 4)
}

func sendDirect(t *_type, sg *sudog, src unsafe.Pointer) {
	// src is on our stack, dst is a slot on another stack.

	// Once we read sg.elem out of sg, it will no longer
	// be updated if the destination's stack gets copied (shrunk).
	// So make sure that no preemption points can happen between read & use.
	dst := sg.elem
	typeBitsBulkBarrier(t, uintptr(dst), uintptr(src), t.size)
	memmove(dst, src, t.size)
}

// memmove copies n bytes from "from" to "to".
// in memmove_*.s
//go:noescape
func memmove(to, from unsafe.Pointer, n uintptr)
```

# select

在看 `chanrecv()`方法 时，发现了一个 block 参数，代表操作是否阻塞。一般情况下，channel 都是阻塞的（不考虑buffer），那什么时候非阻塞呢？

第一个想到的就是 select, 在写了default case的时候，其他的channel是非阻塞的。

还有一个可能不常用，就是 channel 的反射 value, 可以是非阻塞的，这个方法是public的，我们先看下简单的。

```go
func (v Value) TryRecv() (x Value, ok bool)
func (v Value) TrySend(x Value) bool
```

select 就复杂一点点，首先在源码中发现一段注释:

```go
// compiler implements
//
//	select {
//	case c <- v:
//		... foo
//	default:
//		... bar
//	}
//
// as
//
//	if selectnbsend(c, v) {
//		... foo
//	} else {
//		... bar
//	}
//
func selectnbsend(t *chantype, c *hchan, elem unsafe.Pointer) (selected bool) {
	return chansend(t, c, elem, false, getcallerpc(unsafe.Pointer(&t)))
}

// compiler implements
//
//	select {
//	case v = <-c:
//		... foo
//	default:
//		... bar
//	}
//
// as
//
//	if selectnbrecv(&v, c) {
//		... foo
//	} else {
//		... bar
//	}
//
func selectnbrecv(t *chantype, elem unsafe.Pointer, c *hchan) (selected bool) {
	selected, _ = chanrecv(t, c, elem, false)
	return
}
```
如果是一个 case + default 的模式，那么编译器就调用以上方法来实现。

如果是多个 case + default 的模式呢？select 在runtime到底是如何执行的？写个简单的select编译一下。
```go
package main

func main() {
	var ch chan int
	select {
	case <-ch:
	case ch <- 1:
	default:
	}
}
```

`go tool compile -S -l -N test.go > test.s` 结果中找一下关键字，例如:

```
0x008c 00140 (test.go:5)	CALL	runtime.newselect(SB)
0x00ad 00173 (test.go:6)	CALL	runtime.selectrecv(SB)
0x00ec 00236 (test.go:7)	CALL	runtime.selectsend(SB)
0x0107 00263 (test.go:8)	CALL	runtime.selectdefault(SB)
0x0122 00290 (test.go:5)	CALL	runtime.selectgo(SB)
```

这里 `selectgo` 是实际运行的方法，找一下，注意注释。先检查channel是否能操作，如果不能操作，就走 default 逻辑。

```go
loop:
	// pass 1 - look for something already waiting
	var dfl *scase
	var cas *scase
	for i := 0; i < int(sel.ncase); i++ {
		cas = &scases[pollorder[i]]
		c = cas.c

		switch cas.kind {
        // 接受数据
		case caseRecv:
			sg = c.sendq.dequeue()
            // 如果有 sender 在等待
			if sg != nil {
				goto recv
			}
            // 当前buffer中有数据
			if c.qcount > 0 {
				goto bufrecv
			}
            // 关闭的channel
			if c.closed != 0 {
				goto rclose
			}
		case caseSend:
			if raceenabled {
				racereadpc(unsafe.Pointer(c), cas.pc, chansendpc)
			}
            // 关闭
			if c.closed != 0 {
				goto sclose
			}
            // 有 receiver 正在等待
			sg = c.recvq.dequeue()
			if sg != nil {
				goto send
			}
            // 有空间接受
			if c.qcount < c.dataqsiz {
				goto bufsend
			}
        // 走default
		case caseDefault:
			dfl = cas
		}
	}

	if dfl != nil {
		selunlock(scases, lockorder)
		cas = dfl
		goto retc
	}
```



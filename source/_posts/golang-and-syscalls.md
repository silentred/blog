---
title: Golang 与系统调用
date: 2017-08-12 17:04:37
categories:
- tech
- golang
tags:
- golang
---

> gopher con 中的一个视频讲解了如何用golang实现一个简单的strace，本文是基于此演讲整理而来。

<!-- more -->

## 什么是系统调用

先看下wiki的定义：
```
In computing, a system call is the programmatic way in which a computer program requests a service from the kernel of the operating system it is executed on. This may include hardware-related services (for example, accessing a hard disk drive), creation and execution of new processes, and communication with integral kernel services such as process scheduling. System calls provide an essential interface between a process and the operating system.
```

系统调用是程序向操作系统内核请求服务的过程，通常包含硬件相关的服务，例如访问硬盘，创建新进程。系统调用提供了一个进程和操作系统之间的接口。

### syscall无处不在

只要在os上写程序，就无法避免和syscall打交道。举个最常用的例子, `fmt.Println("hello world")`, 这里就用到了系统调用  `write`, 我们翻一下源码。

```go
func Fprintln(w io.Writer, a ...interface{}) (n int, err error) {
	p := newPrinter()
	p.doPrintln(a)
    // writer 是 stdout
	n, err = w.Write(p.buf)
	p.free()
	return
}

Stdout = NewFile(uintptr(syscall.Stdout), "/dev/stdout")

func (f *File) write(b []byte) (n int, err error) {
	if len(b) == 0 {
		return 0, nil
	}
    // 实际的write方法，就是调用syscall.Write()
	return fixCount(syscall.Write(f.fd, b))
}
```

### Zero-Copy

再举一个例子，我们常听到的 zero-copy，我们看看zero-copy是用来解决什么问题的。

```
read(file, tmp_buf, len);
write(socket, tmp_buf, len);
```

借用一张图来说明问题
![img](resource/image/read-write-syscall.jpg)

1. 第一步，`read()`导致上下文切换(context switch)，从用户模式进入内核模式，DMA(Direct memory access) engine 从磁盘中读取内容，存入内核地址buffer。
2. 第二步，数据从内核buffer拷贝入用户buffer，`read()`返回，上下文切换回用户态。
3. 第三步，`write()`上下文切换，把buffer拷贝到内核地址buffer。
4. 第四步，`write()`返回，第四次上下文切换，DMA engine 把数据从内核buffer传给协议引擎，一般是进入队列，等待传输。

我们看到，这里数据在用户空间和内核空间来回拷贝，其实是不必要的。

解决的办法有: `mmap`, `sendfile`, 具体可以参考这篇[文章](http://www.linuxjournal.com/article/6345?page=0,0)

到这里我们应该对

## 
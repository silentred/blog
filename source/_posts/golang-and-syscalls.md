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

到这里我们应该对系统调用有了一定的认识了。

## Strace

`strace` 是用于查看进程系统调用的工具, 一般使用方法如下

```shell
strace <bin>
strace -p <pid>
// 用于统计各个系统调用的次数
strace -c <bin>

// 例如
strace -c echo hello
hello
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
100.00    0.000029          29         1           write
  0.00    0.000000           0         3           read
  0.00    0.000000           0         5         1 open
  0.00    0.000000           0         6           close
  0.00    0.000000           0         5           fstat
  0.00    0.000000           0        11           mmap
  0.00    0.000000           0         3           mprotect
  0.00    0.000000           0         3           munmap
  0.00    0.000000           0         3           brk
  0.00    0.000000           0         1         1 access
  0.00    0.000000           0         1           execve
  0.00    0.000000           0         1           arch_prctl
------ ----------- ----------- --------- --------- ----------------
100.00    0.000029                    43         2 total

```

### 原理

// ptrace

## Ptrace

### 接口

## myStrace

了解以上内容后，presenter 现场实现了一个go版本的strace, 需要在 linux amd64 环境编译。
[github](https://github.com/silentred/gosys)

// strace.go
```golang
package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

func main() {
	var err error
	var regs syscall.PtraceRegs
	var ss syscallCounter
	ss = ss.init()

	fmt.Println("Run: ", os.Args[1:])

	cmd := exec.Command(os.Args[1], os.Args[2:]...)
	cmd.Stderr = os.Stderr
	cmd.Stdout = os.Stdout
	cmd.Stdin = os.Stdin
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Ptrace: true,
	}

	cmd.Start()
	err = cmd.Wait()
	if err != nil {
		fmt.Printf("Wait err %v \n", err)
	}

	pid := cmd.Process.Pid
	exit := true

	for {
		if exit {
			err = syscall.PtraceGetRegs(pid, &regs)
			if err != nil {
				break
			}
			//fmt.Printf("%#v \n",regs)
			name := ss.getName(regs.Orig_rax)
			fmt.Printf("name: %s, id: %d \n", name, regs.Orig_rax)
			ss.inc(regs.Orig_rax)
		}

		err = syscall.PtraceSyscall(pid, 0)
		if err != nil {
			panic(err)
		}

		_, err = syscall.Wait4(pid, nil, 0, nil)
		if err != nil {
			panic(err)
		}

		exit = !exit
	}

	ss.print()
}
```

// 用于统计信息的counter, syscallcounter.go
```golang
package main

import (
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/seccomp/libseccomp-golang"
)

type syscallCounter []int

const maxSyscalls = 303

func (s syscallCounter) init() syscallCounter {
	s = make(syscallCounter, maxSyscalls)
	return s
}

func (s syscallCounter) inc(syscallID uint64) error {
	if syscallID > maxSyscalls {
		return fmt.Errorf("invalid syscall ID (%x)", syscallID)
	}

	s[syscallID]++
	return nil
}

func (s syscallCounter) print() {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 8, ' ', tabwriter.AlignRight|tabwriter.Debug)
	for k, v := range s {
		if v > 0 {
			name, _ := seccomp.ScmpSyscall(k).GetName()
			fmt.Fprintf(w, "%d\t%s\n", v, name)
		}
	}
	w.Flush()
}

func (s syscallCounter) getName(syscallID uint64) string {
	name, _ := seccomp.ScmpSyscall(syscallID).GetName()
	return name
}
```

最后结果：
```
Run:  [echo hello]
Wait err stop signal: trace/breakpoint trap
name: execve, id: 59
name: brk, id: 12
name: access, id: 21
name: mmap, id: 9
name: access, id: 21
name: open, id: 2
name: fstat, id: 5
name: mmap, id: 9
name: close, id: 3
name: access, id: 21
name: open, id: 2
name: read, id: 0
name: fstat, id: 5
name: mmap, id: 9
name: mprotect, id: 10
name: mmap, id: 9
name: mmap, id: 9
name: close, id: 3
name: mmap, id: 9
name: arch_prctl, id: 158
name: mprotect, id: 10
name: mprotect, id: 10
name: mprotect, id: 10
name: munmap, id: 11
name: brk, id: 12
name: brk, id: 12
name: open, id: 2
name: fstat, id: 5
name: mmap, id: 9
name: close, id: 3
name: fstat, id: 5
hello
name: write, id: 1
name: close, id: 3
name: close, id: 3
        1|read
        1|write
        3|open
        5|close
        4|fstat
        7|mmap
        4|mprotect
        1|munmap
        3|brk
        3|access
        1|execve
        1|arch_prctl
```

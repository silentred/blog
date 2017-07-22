---
title: Java AOP, Annotation 笔记
date: 2017-07-22 14:26:02
categories:
- tech
- java
tags:
- java
---

> 最近想看下 RocketMQ, 就打算把 Java 的语法先复习一下，大约4年前写过一些 java，时间久了有些遗忘，而且当时有些东西没搞懂就用了，现在正好补一下这个坑。

<!-- more -->

## Spring Boot

想学语言最好的方法就是先写他几句，切入点选择了 Spring Boot。没有太多比较，只是因为 Spring 鼎鼎大名。
启动很简单，IDE帮忙做了很多事情，但是也有些不爽，只能猜测背后发生的事，具体的命令就不清楚了。

根据文档，建一个web app很容易，但是搞清楚启动流程就没那么简单了。这些个 Annotation 完全不知道具体作用是什么。
于是先找 Annotation 资料。

```java
@SpringBootApplication
public class Application {

    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }

    @Bean
    public CommandLineRunner commandLineRunner(final ApplicationContext ctx) {
        return new CommandLineRunner(){
            @Override
            public void run(String... args) throws Exception {
                System.out.println("Let's inspect the beans provided by Spring Boot:");

                String[] beanNames = ctx.getBeanDefinitionNames();
                Arrays.sort(beanNames);
                for (String beanName : beanNames) {
                    System.out.println(beanName);
                }
            }
        };
    }

}
```

## Annotation

找了一些资料，说说我的理解.

注解就是一种额外的属性，metadata, 是什么的元信息呢？可以是各种，例如 package, class, method, field, parametor等。既然是元信息，那么如果没有人使用它，它就没有任何作用，这点和 Golang 中的 tag类似，但是 tag只能修饰 struct field，作用范围没有java这么广。

我们来自定义一个注解。所有的注解都是 extends `java.lang.annotation.Annotation` 的 child interface. 在 annotaion 包里面，给Annotation定义了一些枚举属性，来定义 Annotation 的属性，也就是 定义注解属性的注解。有这么几种:

1. `@Documented`: 注解是否包含在JavaDoc中一个简单的标记注解，标识是否将注解信息添加在java文档中
2. `@Retention`: 什么时候使用该注解定义该注解的生命周期
    - `RetentionPolicy.SOURCE` 表示在编译阶段丢弃，这些注解在编译结束之后就没意义了，所以它们不会写入字节码.
    - `RetentionPolicy.CLASS` 表示在类加载的时候丢弃，在字节码文件的处理中有用，注解默认都使用这种方式
    - `RetentionPolicy.RUNTIME` 表示始终不对丢弃，运行期也保留该注释，因此可以使用反射机制读取该注解的信息。
3. `@Target`: 注解应用于什么地方如果不明确指出，则改注解可以放在任何地方。
    - `ElementType.TYPE` :用于描述类、接口或enum声明
    - `ElementType.FIELD` :用于描述实例变量
    - `ElementType.METHOD` ：给方法注解
    - `ElementType.PARAMETER`：给参数注解
    - `ElementType.CONSTRUCTOR` ：给构造方法注解
    - `ElementType.LOCAL_VARIABLE` ：给局部变量注解
    - `ElementType.ANNOTATION_TYPE` :给注解注解
    - `ElementType.PACKAGE` :用于记录java文件的package信息需要说明的是
4. `@Inherited`: 是否允许子类继承此注解
5. `@Repeatable`: 表示他标记的注解是repeatable的，不太理解。

我们来自定义个 Annotation

```java
import java.lang.annotation.*;

@Target(value = ElementType.TYPE)
@Retention(value = RetentionPolicy.RUNTIME)
public @interface Count {
    public int count() default 0;
}
```

通过反射使用:

```java
@Count(count = 3)
public class Application {
    public static void main(String[] args) {
        int cnt = Application.class.getAnnotation(Count.class).count();
        System.out.printf("Count = %d", cnt);
    }
}
```

JVM 有 ClassLoader 这个上帝，运行时能拿到所有类的信息，包括注解，所以能通过检查注解做初始化工作。通常一个配置文件就能搞定所有初始化。
Golang就做不到，因为没办法通过name找到对应类型，只能通过反射对象得到类型，IoC 不如 java彻底。

## AOP

面向切面是一个实用的设计模式，作用是在一个method前后插入一些代码逻辑，这些逻辑一般是复用需求非常大的。
实现方法是动态代理，查了一些资料，说说我的看法。

### JDK

最原始的方式就是利用 JDK 提供的 `InvocationHandler` 和 `Proxy`，拼字符串生成新的代理类源码 .java 文件，然后动态编译，用到了 `javax.tools.JavaCompiler`·等工具。
看了一个别人的例子，感觉非常丑陋。

### AspectJ

AspectJ 解决了拼字符串的痛苦，自己定义了一种 DSL， 并且提供了编译工具，生成.java源码。猜测本质还是利用了 JDK的提供的接口。这两种都是编译期间AOP实现。

### cglib

cglib 通过修改字节码实现AOP，是运行时的AOP，所以效率稍差，好处是不用写难看的代码，不用引入aspectj的第三方编译器。现在硬件很便宜，这些性能损耗几乎可以忽略。

### One for all: Spring AOP

Spring AOP 为 AspectJ 和 cglib 封装了统一的接口，对开发完全透明，具体实现由Spring决定。例如，针对接口的AOP，Spring选择使用JDK，针对 concrete class 的AOP，选择 cglib。（这个结论不确定）

## Other

最近对语言类型一些思考:

- 动态弱类型：PHP
- 动态强类型：Python
- 静态强类型: Go, Java
- 貌似没有静态弱类型

Java选择字节码中间状态，带来了一些动态效果，兼具灵活和稳健，Go就相对没那么灵活。所以Java玩出花的东西，Go就不支持，但是这些花活有一定的学习成本，菜鸟容易掉坑里.
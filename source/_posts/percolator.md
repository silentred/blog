---
title: Percolator 学习笔记
date: 2019-03-16 23:04:09
categories:
- tech
- database
tags:
- database
- transaction
---

> 最近去 PingCAP 杭州分舵听了 TiDB事务 的分享, 模型使用的是 Percolator，听着比较简单，回来补下论文，看看有什么遗漏.

<!-- more -->

# Percolator在谷歌解决的定位

Percolator专门为增量处理而构建，并不打算替代大多数数据处理任务的现有解决方案。计算结果不能分解为小而多的更新（例如，对文件进行排序）可以通过MapReduce更好地处理。此外，计算应具有较强的一致性要求;否则，Bigtable就足够了。最后，计算在某个维度上应该非常大（总数据大小，转换所需的CPU等）;传统DBMS可以处理不适合MapReduce或Bigtable的较小计算。

在谷歌中，Percolator的主要应用是准备网页以包含在实时网络搜索索引中。通过将索引系统转换为增量系统，我们可以在抓取它们时处理单个文档。这将平均文档处理延迟减少了100倍，并且搜索结果中出现的文档的平均年龄下降了近50％（搜索结果的年龄包括除索引之外的延迟，例如文档之间的时间改变并被抓取）。该系统也被用来将页面渲染成图像;Percolator跟踪网页和他们所依赖的资源之间的关系，因此当任何依赖的资源发生变化时可以对页面进行重新处理。

# 设计

Percolator 为增量处理提供了两个抽象功能:
- 随机访问数据的 ACID 事务
- 观察者，用于组织增量计算


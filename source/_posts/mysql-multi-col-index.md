---
title: MySQL 多列索引
date: 2017-08-12 15:47:05
categories:
- tech
- mysql
tags:
- mysql
- index
---

> 说说 mysql 联合索引， 解读 mysql 文档， 看看什么时候会利用 联合索引，什么时候 mysql server 不使用。

<!-- more -->

## 例子

### 建表语句

```mysql
CREATE TABLE test (
    id         INT NOT NULL,
    last_name  CHAR(30) NOT NULL,
    first_name CHAR(30) NOT NULL,
    PRIMARY KEY (id),
    INDEX name (last_name,first_name)
);
```

### 会利用索引的查询

```mysql

// last_name 是索引最左字段，所以可以利用
SELECT * FROM test WHERE last_name='Widenius';

// 两个AND等值查询，可以利用
SELECT * FROM test
  WHERE last_name='Widenius' AND first_name='Michael';

// 和上面等价，sql优化器会处理顺序问题
SELECT * FROM test
  WHERE first_name='Michael' AND last_name='Widenius';

// first_name 可以是等值OR, 或者 范围条件
SELECT * FROM test
  WHERE last_name='Widenius'
  AND (first_name='Michael' OR first_name='Monty');

SELECT * FROM test
  WHERE last_name='Widenius'
  AND first_name >='M' AND first_name < 'N';
```

### 不会利用联合索引

```mysql
// 条件中没有包含最左字段 last_name
SELECT * FROM test WHERE first_name='Michael';

// 个人认为， last_name 的条件会用到索引，因为最左原则；
// 最后和另一个条件合并结果
SELECT * FROM test
  WHERE last_name='Widenius' OR first_name='Michael';
```

### Index Merge Optimization

```
SELECT * FROM tbl_name
  WHERE col1=val1 AND col2=val2;
```

对于这类的请求，如果有 multiple-column index, 则直接使用此索引。如果有单独索引 col1 或者 col2, 那么优化器尝试 Index Merge optimization, 或者尝试找到限制最多的索引(排除的行数最多，这样效率较高)。

Index Merge 是指，对于多个范围扫描，把合并结果。合并结果的类型可以是 并集，交集，等。索引不能跨表。
以下例子可能会利用 Index Merge.

```
// key1, key2 有单独索引, 分别利用索引，结果合并
SELECT * FROM tbl_name WHERE key1 = 10 OR key2 = 20;

// 和上面一样, 得到合集后，扫描合集筛选 non-key 字段
SELECT * FROM tbl_name
  WHERE (key1 = 10 OR key2 = 20) AND non_key = 30;

// 时利用两个索引scan，取交集
SELECT * FROM tbl_name
  WHERE (key1_part1 = 1 AND key1_part2 = 2) AND key2 = 2;

// 同上，主键可以是范围查询
SELECT * FROM innodb_table
  WHERE primary_key < 10 AND key_col1 = 20;

// 取并集
SELECT * FROM t1
  WHERE key1 = 1 OR key2 = 2 OR key3 = 3;
```

### 最左前缀

假设有 (col1, col2, col3) 联合索引，最左前缀为 col1, 不包含col1条件的查询，不会使用此联合索引。

```
// 会使用
SELECT * FROM tbl_name WHERE col1=val1;
SELECT * FROM tbl_name WHERE col1=val1 AND col2=val2;

// 不会使用
SELECT * FROM tbl_name WHERE col2=val2;
SELECT * FROM tbl_name WHERE col2=val2 AND col3=val3;
```
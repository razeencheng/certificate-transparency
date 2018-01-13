# 搭建证书透明度(certificate-transparency)日志服务之从入门到放弃

最近在搭建证书透明度日志服务，折腾了几天，最后结果是 “测试完美通关，部署各种出错"。So, 先暂停一段时间，写篇博客记录一下这几天傻傻折腾的过程。 

*注* 后面`certificate-transparency` 简写为CT。



<!--more-->



### CT是什么？

从中文翻译就可看出，证书透明嘛，就是让证书透明化。

至于各中细节，[屈屈有篇博客](https://imququ.com/post/certificate-transparency.html#toc-0)写的蛮详细的，我就不赘述了。

当然，[官方](https://www.certificate-transparency.org/what-is-ct)也有更详细的文档说明。



### 搭建CT日志服务

#### 1）Before 搭建

看完上面的博客或文档，我们知道CT系统的组成有这么三个部分：

​        1）Certificate Logs；2）Certificate Monitors；3）Certificate Auditors。

而我们这里搭建的就是第一部分 Certificate Logs ，也就是我说的CT日志服务。

[CT的开源项目](https://github.com/google/certificate-transparency)除了包含了CT日志服务(ct-server)，还有一个日志的只读服务(ct-mirror)以及一些日志的管理维护日志服务。这里我们主要搭建的是ct-server，当然也会用到一些工具。

在[Deploying a CT Log](https://github.com/google/certificate-transparency/blob/master/docs/Deployment.md)指明了两种搭建方法，这里我用docker搭建，docker-compose编排。

其中主要需要的相关服务：

* ct-server  (CT日志的主体服务)
* prom (监控服务)
* etcd (数据同步服务)

就像官方的部署图

![](https://st.razeen.me/essay/img/ct/SystemDiagram.png)

拟部署CT三台日志服务，三台etcd组成集群，负载的负载均衡就是后话了。



#### 2）编译代码

在构建之前，我们先需要编译代码。这里就得注意一下编译的环境了。由于一开始傻傻的文档都没看，直接在我的Mac(os x 10.13)上编译，结果各种C库问题。

在文档中已经明确指出：

The supported platforms are:

- **Linux**: tested on Ubuntu 14.04; other variants (Fedora 22, CentOS 7) may require tweaking of [compiler options](https://github.com/google/certificate-transparency#build-troubleshooting).
- **OS X**: version 10.10
- **FreeBSD**: version 10.*

我这里采用的是Ubuntu14.04平台，在docker内编译，Dockerfile如下:

```dockerfile
FROM ubuntu:14.04

# 安装基本环境
RUN apt-get update \
        && apt-get upgrade -y \
        && apt-get install --no-install-recommends --no-install-suggests -y \
                autoconf \
                automake \
                libtool \
                shtool \
                clang \
                git \
                make \
                tcl \
                pkg-config \
                python \
                curl \
                ca-certificates
                
# 由于depot_tools资源在墙外，docker内下载很慢，我就直接下的COPY进去了
# git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
COPY depot_tools /root/depot_tools

# 由于ubuntu上的cmake版本还停留在 需要手动升级下cmake，同上的原因，我也就copy进来了
# curl http://www.cmake.org/files/v3.4/cmake-3.4.1.tar.gz
COPY cmake-3.4.1 /root/cmake-3.4.1
RUN  apt-get install -y build-essential \
        && cd /root/cmake-3.4.1 \
        && ./configure \
        && make \
        && apt-get install -y checkinstall \
        && checkinstall \
        && make install \
        && cmake --version 

WORKDIR /root

# 编译
RUN export PATH=$PATH:/root/depot_tools \
        && export CXX=clang++ CC=clang  \
        && mkdir ct && cd ct \
        && gclient config --name="certificate-transparency" https://github.com/google/certificate-transparency.git@master \
        && gclient sync --disable-syntax-validation \
        && make -C certificate-transparency check

```

直接`docker build -t ctlog .` 

然后你就可以去喝杯茶了。不出意外，大概1个小时左右，你会看到

```bash
Testsuite summary for certificate-transparency 0.9
============================================================================
# TOTAL: 41
# PASS:  41
# SKIP:  0
# XFAIL: 0
# FAIL:  0
# XPASS: 0
# ERROR: 0
============================================================================
...
```

之后，我们进docker将编译好的文件映射出来即可。

将`ct/certificate-transparency` 文件夹拷出后，我们大概可以看到：

```bash
# certificate-transparency git:(master) tree
.
├── AUTHORS
├── Dockerfile
├── ...
├── cloud
│   ├── etcd
│   │   └── Dockerfile
│   └── prometheus
│       ├── Dockerfile
│       └── prometheus.conf
├── cpp
│   ├── server
│   │   ├── ct-mirror
│   │   ├── ct-server
│   ├── tools
│   │   ├── ct-clustertool
│   │   └── prepare_etcd.sh
└── ...

```

这里的`ct-server`就是我们要的可执行文件了。除了该文件外，我们还需要一些工具，脚本，如：etcd初始化脚本`prepare_etcd.sh`和CT集群工具`ct-clustertool`。到这里，我们的编译工作就完成了。



#### 3）构建与编排

文档上说的很清楚，编排之前我们还需要一些文件，至于具体需要哪些，我们结合ct-server参数做一个大概了解。

1. 必须参数
   * `--key=<pemfile>` 秘钥PEM文件，ct日志服务用来加密和签名的。无需密码保护。
   * `--trusted_cert_file=<pemfile>` 可信CA PEM文件，你的日志可接收的可信CA。
   * `--leveldb_db=<file>.ldb` 日志文件数据库。
   * `--etcd_servers=<host>:<port>,<host>:<port>,...` etcd服务。
   * `--server=<hostname>` 主机名。（可解析 可路由）
   * `--port=<port>` 端口。
2. 可选参数
   * `-log_dir=<dir>` 日志文件夹
   * `--v=<num>` 日志输出等级 （像debug一样）
   * `--monitoring=<prometheus|gcm>` 监控
   * `--tree_signing_frequency_seconds=<secs>` STH树的刷新时间  << MMD
   * `--guard_window_seconds=<secs>`  表示在对日志的新条目进行排序之前要拖延多长时间.
   * `--etcd_delete_concurrency=<num>` 表示可以同时删除多少个etcd条目。
   * `--num_http_server_threads=<num>` 表示有多少线程用于服务传入的HTTP请求。

从参数可以看出，我们需要

**私钥**

  ```bash
 # openssl 生成
 openssl ecparam -name prime256v1 > privkey.pem # 生成参数文件
 openssl ecparam -in privkey.pem -genkey -noout >> privkey.pem # 生成key
 openssl ec -in privkey.pem -noout -text # 查看key
 openssl ec -in privkey.pem -pubout -out pubkey.pem # 生成公钥
  ```

**CA证书**

文档上提供的是从Ubuntn的根证书库拿证书，我们也这么做，不过如果你想向Google提交你的日志服务，你还需要内置一章[Google的测试证书](https://www.chromium.org/Home/chromium-security/certificate-transparency/log-policy)，供Google测试使用。

```bash
sudo apt-get install -qy ca-certificates
sudo update-ca-certificates
cat /etc/ssl/certs/* > ca-roots.pem
```

**etcd**

etcd我用的`quay.io/coreos/etcd:v3.2.0`镜像，用DISCOVERY模式。

**prometheus**

刚开始我也用的是最新版本的prometheus，但当我启动后，发现ct_server中`/mertic`获取到的数据居然无法兼容，我最后还是用了`v1.0.0`版。

在这些都开始后我们就开始构建镜像，编排docker了，相关的Dockerfile及文件我都上传到了我的[GitHub](),其中为了方便操作，我用`Makefile`编排了一下。 

```makefile
CURRENT_DIR=`pwd`

help:
	@echo "docker build help..."
	@docker build -f Dockerfile-help -t ct_help .

# 用于日志的key
pre_key:
	@openssl ecparam -name prime256v1 > server-key.pem  && \
	    openssl ecparam -in server-key.pem -genkey -noout >> server-key.pem  && \
	    openssl ec -in server-key.pem -noout -text  && \
	    openssl ec -in server-key.pem -pubout -out server-pub.pem 

# 根证书
pre_cacerts:
	@docker run --rm -v $(CURRENT_DIR):/tmp -it ct_help bash -c '\
	    cat /etc/ssl/certs/* /tmp/google_test.pem > /tmp/ca-cert.pem'

prom:  
	@echo "docker build promtheus..."
	@docker build -f Dockerfile-prom -t ct_prom .
	
ct_log:
	@echo "docker build ct log..."
	@docker build -f Dockerfile-log -t ct_log .

etcd:
	@echo "docker build etcd ..."
	@docker build -f Dockerfile-etcd -t ct_etcd .
	
up:
	@export ETCD_DISCOVERY=`curl -s -w "\n" 'https://discovery.etcd.io/new?size=3'` && \
	    printf "\033[92m[%-14s]\033[0m %s\n" "etcd discovery" $$ETCD_DISCOVERY && \
	    docker-compose up -d

# 启动后需要初始化etcd内的内容
init_etcd:
	@docker run --rm -v $(CURRENT_DIR):/tmp \
	    --add-host "etcdhost:192.168.11.65" -t ct_help bash -c '\
	    cd /tmp && ./prepare_etcd.sh etcdhost 14001 server-key.pem'

# 停止
down:
	@docker-compose down
	
# 清除日志文件
clean_data:
	@rm -rf /mnt/data/ct

# 测试
test:
	curl -s 127.0.0.1:18081/ct/v1/get-sth 
	#
	curl -s 127.0.0.1:18082/ct/v1/get-sth 
	#
	curl -s 127.0.0.1:18083/ct/v1/get-sth 

submit:
	@docker run --rm -v $(CURRENT_DIR):/tmp \
	    --add-host "host:192.168.11.65" -t ct_help bash -c '\
	    cd /tmp && ./ct-submit host:18081 < test_full_chain.pem > test.sct'

check_etcd:
	curl -s -L http://127.0.0.1:14001/health
	#
	curl -s -L http://127.0.0.1:14002/health
	#
	curl -s -L http://127.0.0.1:14003/health

pre: help pre_key pre_cacerts

build: prom ct_log etcd

run: up init_etcd
```

只需要简单的`make pre build run`你就可以搭建起一个CT日志服务了，不过在此之前不要忘了将`Makefile`,`prometheus.yaml`,`docker-compose.yaml`中的IP改成你的哦。





#### 4）部署与测试 

其实按照上面操作你已经搭建起了一个CT日志服务。

* ` make pre` 准备了一个后面需要的Ubuntu docker，生成秘钥以及根证书。
* `make build` 将需要的容器构建。
* `make run`就是启动以及向ETCD写入一些日志相关的Key以及CT集群的一些初始化工作，具体内容可看`prepare_etcd.sh`脚本。

在这之后，`make test`我们可以看到：

```bash
$ curl -s 127.0.0.1:18081/ct/v1/get-sth
{ "tree_size": 0, "timestamp": 1515742224849, "sha256_root_hash": "47DEQpj8HBSa+\/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", "tree_head_signature": "BAMARzBFAiEAimYSepMbRdR5cTCo9OwW3m3w7fQPIuO1L0LPC+7NaUgCIGNcLLwehMMckj\/\/tGAJfEFPOYiWTGuM+jno87XK6RwT" }#
$ curl -s 127.0.0.1:18082/ct/v1/get-sth
{ "tree_size": 0, "timestamp": 1515742224849, "sha256_root_hash": "47DEQpj8HBSa+\/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", "tree_head_signature": "BAMARzBFAiEAimYSepMbRdR5cTCo9OwW3m3w7fQPIuO1L0LPC+7NaUgCIGNcLLwehMMckj\/\/tGAJfEFPOYiWTGuM+jno87XK6RwT" }#
$ curl -s 127.0.0.1:18083/ct/v1/get-sth
{ "tree_size": 0, "timestamp": 1515742224849, "sha256_root_hash": "47DEQpj8HBSa+\/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", "tree_head_signature": "BAMARzBFAiEAimYSepMbRdR5cTCo9OwW3m3w7fQPIuO1L0LPC+7NaUgCIGNcLLwehMMckj\/\/tGAJfEFPOYiWTGuM+jno87XK6RwT" }% 
```

说明第一棵大小为0，时间戳为1515742224849的树已经建好了，CT等着我们去提交了。

接下来，我们提交一张证书测试一下。

`make submit` 提交了一张我已经准备好的证书，返回的SCT写入到了test.sct文件。

```bash
$ xxd test.sct
00000000: 00e8 03a0 42ca d5c6 8b75 dd99 7618 a739  ....B....u..v..9
00000010: b365 a64b 1bc3 4fa3 6f10 1169 dd0b 4c48  .e.K..O.o..i..LH
00000020: 9400 0001 60e9 4672 9f00 0004 0300 4830  ....`.Fr......H0
00000030: 4602 2100 a6c2 3520 9cd0 c5cc 9549 7db3  F.!...5 .....I}.
00000040: 97a1 702a c2f9 8c7c 566d 3f2a 0124 a5c6  ..p*...|Vm?*.$..
00000050: edfa 709a 0221 00da 9fb9 b301 6bf1 873f  ..p..!......k..?
00000060: bc75 7c5a f25c 13f7 f3ad dddd ec5a 017b  .u|Z.\.......Z.{
00000070: 25de 4de2 452f 44                        %.M.E/D
```

我们的一张证书已经成功提交到自己CT日志服务。大概在40s之后，也就是`--tree_signing_frequency_seconds`加上`--guard_window_seconds`的时间过后，一个新树就生成了。再次`make test`

```bash
$ curl -s 127.0.0.1:18081/ct/v1/get-sth
{ "tree_size": 1, "timestamp": 1515742344849, "sha256_root_hash": "pI7dv4Bi3dyBvx83s13fuWbNwGQQmafY344Wyf0m7OI=", "tree_head_signature": "BAMASDBGAiEAmVi6bsH3+NMxaiapBXA80Ygolc1kGLgPAhSMUEXcCzoCIQDdB4YdxH08lmeIZ8DDttjPtm5NtZV8CCNZ1+xyT0d05A==" }#
$ curl -s 127.0.0.1:18082/ct/v1/get-sth
{ "tree_size": 1, "timestamp": 1515742344849, "sha256_root_hash": "pI7dv4Bi3dyBvx83s13fuWbNwGQQmafY344Wyf0m7OI=", "tree_head_signature": "BAMASDBGAiEAmVi6bsH3+NMxaiapBXA80Ygolc1kGLgPAhSMUEXcCzoCIQDdB4YdxH08lmeIZ8DDttjPtm5NtZV8CCNZ1+xyT0d05A==" }#
$ curl -s 127.0.0.1:18083/ct/v1/get-sth
{ "tree_size": 1, "timestamp": 1515742344849, "sha256_root_hash": "pI7dv4Bi3dyBvx83s13fuWbNwGQQmafY344Wyf0m7OI=", "tree_head_signature": "BAMASDBGAiEAmVi6bsH3+NMxaiapBXA80Ygolc1kGLgPAhSMUEXcCzoCIQDdB4YdxH08lmeIZ8DDttjPtm5NtZV8CCNZ1+xyT0d05A==" }% 
```

这颗 Merkle树已经包含了我提交的证书。

哦，还漏了一点，我们可以从prometheus看到所有的服务，也可以制造一些数据报表，设置报警规则等。



### 问题

一切似乎进展的很顺利，但，当我上云时，问题出现了。

三台机器，私网全部流量互通，每个机器一个CT已经etcd服务，节点三多跑一个Prometheus服务。当我将一切搭建好后，向其中一个节点提交日志，我们会发现除主简单外，其他两个节点日志打印错误如下：

```
I1228 09:30:09.295418     8 fetcher.cc:225] error fetching entries at index 0: UNKNOWN:
I1228 09:30:09.295658    10 fetcher.cc:225] error fetching entries at index 0: UNKNOWN:
I1228 09:30:09.332808    13 fetcher.cc:225] error fetching entries at index 0: UNKNOWN:
I1228 09:30:09.333170    14 fetcher.cc:225] error fetching entries at index 0: UNKNOWN:
I1228 09:30:09.333434    12 fetcher.cc:225] error fetching entries at index 0: UNKNOWN:
I1228 09:30:09.333684     9 fetcher.cc:225] error fetching entries at index 0: UNKNOWN:
I1228 09:30:09.333931    11 fetcher.cc:225] error fetching entries at index 0: UNKNOWN:
I1228 09:30:09.334175    15 fetcher.cc:225] error fetching entries at index 0: UNKNOWN:
I1228 09:30:09.334420     8 fetcher.cc:225] error fetching entries at index 0: UNKNOWN:
I1228 09:30:09.334666    10 fetcher.cc:225] error fetching entries at index 0: UNKNOWN:
I1228 09:30:09.334946    13 fetcher.cc:225] error fetching entries at index 0: UNKNOWN:
```

同时，这两个节点CPU用量会飙升。

当然，在CT项目的Issues里我们发现了有人遇到了[几乎同样的问题](https://github.com/google/certificate-transparency/issues/1091)。在最后一句大神的回复中，我们或了解到，他们正在开发一个通用的透明化项目[Trillian](https://github.com/google/trillian)，当然该项目不仅仅可以用于证书透明化。借助于Merkle树的快速查询，不可修改等特性未来或许我们会在更多地方看到他。

这让我想到区块链，想到前几天图大发的一个推

![](https://st.razeen.me/essay/img/ct/IMG_4388.jpg)

emmmmm... 扯远了，到这里全部的搭建过程完成了，最后虽未成功，但发现了一个新的方向~

当然，如果你解决了这个问题，或者发现了我的错误，还忘不吝指教~

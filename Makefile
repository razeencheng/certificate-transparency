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


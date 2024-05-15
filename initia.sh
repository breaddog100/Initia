#!/bin/bash

# 节点安装功能
function install_node() {

	read -p "节点名称:" NODE_MONIKER
	
    sudo apt update
    sudo apt install -y make build-essential snap jq
    sudo snap install lz4

	# 安装 Go
    if ! go version >/dev/null 2>&1; then
        sudo rm -rf /usr/local/go
        curl -L https://go.dev/dl/go1.22.0.linux-amd64.tar.gz | sudo tar -xzf - -C /usr/local
        echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> $HOME/.bash_profile
        source $HOME/.bash_profile
        go version
    fi
    
    # 检查/etc/security/limits.conf文件是否已经包含了所需的条目
	if grep -q "nofile 65535" /etc/security/limits.conf; then
	    echo "Limits already set in /etc/security/limits.conf"
	else
	    # 如果没有找到，添加到文件中
	    echo "* soft nofile 65535" | sudo tee -a /etc/security/limits.conf > /dev/null
		echo "* hard nofile 65535" | sudo tee -a /etc/security/limits.conf > /dev/null
	    echo "Limits added to /etc/security/limits.conf"
	fi
    
    cd $HOME
    git clone https://github.com/initia-labs/initia
	cd initia
	TAG=v0.2.12
	git checkout $TAG # Tag the desired version
	make install
	initiad version
	
	initiad init $NODE_MONIKER
	curl -Ls https://initia.s3.ap-southeast-1.amazonaws.com/initiation-1/genesis.json > $HOME/.initia/config/genesis.json
	wget -O $HOME/.initia/config/addrbook.json https://rpc-initia-testnet.trusted-point.com/addrbook.json
	PEERS="04f0d493cb02a43d85b4fcd4bafd171500a433a0@162.55.27.107:46656,636cc23537e7af9a1bf90df9c4b3ab4e2776ec64@118.249.191.174:53456,f63ee4568a92aa3a1d9032433fc5e63d288aa68a@207.180.243.37:17956,954c327509c0c1f458a75416b56b0c7e4d762f5b@194.163.174.193:17956,c79eeb5902e8d17877e01bce2803806a5d01c673@23.88.125.99:39656"
	seeds="2eaa272622d1ba6796100ab39f58c75d458b9dbc@34.142.181.82:26656,c28827cb96c14c905b127b92065a3fb4cd77d7f6@testnet-seeds.whispernode.com:25756,ade4d8bc8cbe014af6ebdf3cb7b1e9ad36f412c0@testnet-seeds.polkachu.com:25756"

    sed -i -e "s|^minimum-gas-prices *=.*|minimum-gas-prices = \"0.15uinit,0.01uusdc\"|" $HOME/.initia/config/app.toml
    sed -i -e 's|^seeds *=.*|seeds = $seeds|' $HOME/.initia/config/config.toml
    sed -i 's|^persistent_peers *=.*|persistent_peers = "'"$PEERS"'"|' "$HOME/.initia/config/config.toml"
	#sed -i -e 's/external_address = \"\"/external_address = \"'$(curl httpbin.org/ip | jq -r .origin)':26656\"/g' ~/.initia/config/config.toml
	
	sudo tee /etc/systemd/system/initiad.service > /dev/null <<EOF
[Unit]
Description=initiad

[Service]
Type=simple
User=$USER
ExecStart=$(which initiad) start
Restart=on-abort
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=initiad
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable initiad
    systemctl daemon-reload
	systemctl restart initiad
    
    # Oracle
    git clone https://github.com/skip-mev/slinky.git
	cd slinky
	# checkout proper version
	git checkout v0.4.3
	
	# Build the Slinky binary in the repo.
	make build
	sed -i -e 's/^enabled = "false"/enabled = "true"/' \
       -e 's/^oracle_address = ""/oracle_address = "127.0.0.1:8080"/' \
       -e 's/^client_timeout = "2s"/client_timeout = "500ms"/' \
       -e 's/^metrics_enabled = "false"/metrics_enabled = "false"/' $HOME/.initia/config/app.toml
       
       sudo tee /etc/systemd/system/slinkyd.service > /dev/null <<EOF
[Unit]
Description=Slinky Service

[Service]
ExecStart=$HOME/initia/slinky/build/slinky --oracle-config-path $HOME/initia/slinky/config/core/oracle.json --market-map-endpoint 0.0.0.0:9090
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF
	systemctl enable slinkyd
    systemctl daemon-reload
	systemctl restart slinkyd
       
	# Run with the core oracle config from the repo.
	#./build/slinky --oracle-config-path ./config/core/oracle.json --market-map-endpoint 0.0.0.0:9090
    
	echo "部署完成"
}

# 下载快照
function download_snap(){
	echo "快照文件较大，下载需要较长时间，请保持电脑屏幕不要熄灭"
    read -p "浏览器打开https://polkachu.com/testnets/initia/snapshots选择最新快照文件，输入[ initia_数字.tar.lz4 ]具体名称: " filename
    
    # 下载快照
    if wget -P $HOME/ https://snapshots.polkachu.com/testnet-snapshots/initia/$filename ;
    then
        systemctl stop initiad
    	initiad tendermint unsafe-reset-all --home $HOME/.initia --keep-addr-book
    	lz4 -c -d $filename | tar -x -C $HOME/.initia
        # 启动节点进程
        systemctl start initiad
    else
        echo "下载失败。"
        exit 1
    fi
}

# 创建钱包
function create_wallet(){
    # 创建钱包
    read -p "钱包名称:" wallet_name
    initiad keys add $wallet_name
}

# 导入钱包
function import_wallet() {
	read -p "钱包名称:" wallet_name
    initiad keys add $wallet_name --recover
}

# 创建验证者
function add_validator() {
    #echo "钱包余额需大于20000ubbn，否则创建失败..."
    read -p "验证者名称:" validator_name
    read -r -p "请输入你的钱包名称: " wallet_name
    
    initiad tx mstaking create-validator \
    --amount="1000000uinit" \
    --pubkey=$(initiad tendermint show-validator) \
    --moniker="$validator_name" \
    --identity="" \
    --chain-id="initiation-1" \
    --from="$wallet_name" \
    --commission-rate="0.10" \
    --commission-max-rate="0.20" \
    --commission-max-change-rate="0.01"
}

# 查看验证者公钥
function show_validator_key(){
	initiad tendermint show-validator
}

# 申请出狱
function unjail(){
	read -p "节点名称:" NODE_MONIKER
	#initiad tx slashing unjail <validator address>
}

# 查看节点同步进度
function check_sync_status() {
    initiad status | jq .sync_info
}

# 查看日志
function view_logs(){
	journalctl -t initiad -f
}

# 查看余额
function check_balance(){
    read -p "钱包地址:" wallet_addr
    initiad query bank balances "$wallet_addr"
}

# 质押代币
function delegate_self_validator() {
    read -p "钱包名称: " wallet_name
    read -p "质押数量: " math
    initiad tx mstaking delegate $(initiad keys show wallet --bech val -a) ${math}000000uinit --from $wallet_name --chain-id initiation-1 --gas=2000000 --fees=300000uinit -y
}

# 卸载节点功能
function uninstall_node() {
    echo "确定要卸载initia节点吗？这将会删除所有相关的数据。[Y/N]"
    read -r -p "请确认: " response

    case "$response" in
        [yY][eE][sS]|[yY]) 
            echo "开始卸载节点程序..."
            systemctl stop initiad
            systemctl stop slinkyd
            rm -rf $HOME/.initiad && rm -rf $HOME/initia $(which initiad) && rm -rf $HOME/.initia
            echo "节点程序卸载完成。"
            ;;
        *)
            echo "取消卸载操作。"
            ;;
    esac
}

# 主菜单
function main_menu() {
	while true; do
	    clear
	    echo "===================Initia 一键部署脚本==================="
		echo "沟通电报群：https://t.me/lumaogogogo"
		echo "推荐配置：4C16G1T"
	    echo "请选择要执行的操作:"
	    echo "1. 部署节点 install_node"
	    echo "2. 下载快照 download_snap"
	    echo "3. 创建钱包 create_wallet"
	    echo "4. 导入钱包 import_wallet"
	    echo "5. 创建验证者 add_validator"
	    echo "6. 验证者公钥 show_validator_key"
	    echo "7. 申请出狱 unjail"
	    echo "8. 同步进度 check_sync_status"
	    echo "9. 查看日志 view_logs"
	    echo "10. 查看余额 check_balance"
	    echo "11. 质押代币 delegate_self_validator"
	    echo "12. 卸载节点 uninstall_node"
	    echo "0. 退出脚本exit"
	    read -p "请输入选项: " OPTION
	
	    case $OPTION in
	    1) install_node ;;
	    2) download_snap ;;
	    3) create_wallet ;;
	    4) import_wallet ;;
	    5) add_validator ;;
	    6) show_validator_key ;;
	    7) unjail ;;
	    8) check_sync_status ;;
	    9) view_logs ;;
	    10) check_balance ;;
	    11) delegate_self_validator ;;
	    12) uninstall_node ;;
	    0) echo "退出脚本。"; exit 0 ;;
	    *) echo "无效选项，请重新输入。"; sleep 3 ;;
	    esac
	    echo "按任意键返回主菜单..."
        read -n 1
    done
}

main_menu
#!/bin/bash

# 节点安装功能
function install_node() {

	read -p "节点名称:" NODE_MONIKER
	
    sudo apt update
    sudo apt install -y make build-essential snap jq git
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
	TAG=v0.2.14
	git checkout $TAG # Tag the desired version
	make install
	initiad version
	source $HOME/.bash_profile
	
	initiad init $NODE_MONIKER
	curl -Ls https://initia.s3.ap-southeast-1.amazonaws.com/initiation-1/genesis.json > $HOME/.initia/config/genesis.json
	wget -O $HOME/.initia/config/addrbook.json https://rpc-initia-testnet.trusted-point.com/addrbook.json
	PEERS="40d3f977d97d3c02bd5835070cc139f289e774da@168.119.10.134:26313,841c6a4b2a3d5d59bb116cc549565c8a16b7fae1@23.88.49.233:26656,e6a35b95ec73e511ef352085cb300e257536e075@37.252.186.213:26656,2a574706e4a1eba0e5e46733c232849778faf93b@84.247.137.184:53456,ff9dbc6bb53227ef94dc75ab1ddcaeb2404e1b0b@178.170.47.171:26656,edcc2c7098c42ee348e50ac2242ff897f51405e9@65.109.34.205:36656,07632ab562028c3394ee8e78823069bfc8de7b4c@37.27.52.25:19656,028999a1696b45863ff84df12ebf2aebc5d40c2d@37.27.48.77:26656,140c332230ac19f118e5882deaf00906a1dba467@185.219.142.119:53456,1f6633bc18eb06b6c0cab97d72c585a6d7a207bc@65.109.59.22:25756,065f64fab28cb0d06a7841887d5b469ec58a0116@84.247.137.200:53456,767fdcfdb0998209834b929c59a2b57d474cc496@207.148.114.112:26656,093e1b89a498b6a8760ad2188fbda30a05e4f300@35.240.207.217:26656,12526b1e95e7ef07a3eb874465662885a586e095@95.216.78.111:26656"
	seeds="2eaa272622d1ba6796100ab39f58c75d458b9dbc@34.142.181.82:26656,c28827cb96c14c905b127b92065a3fb4cd77d7f6@testnet-seeds.whispernode.com:25756,ade4d8bc8cbe014af6ebdf3cb7b1e9ad36f412c0@testnet-seeds.polkachu.com:25756"

    sed -i -e "s|^minimum-gas-prices *=.*|minimum-gas-prices = \"0.15uinit,0.01uusdc\"|" $HOME/.initia/config/app.toml
    sed -i 's|^seeds *=.*|seeds = "'$seeds'"|' $HOME/.initia/config/config.toml
    sed -i 's|^persistent_peers *=.*|persistent_peers = "'$PEERS'"|' $HOME/.initia/config/config.toml
	
	sudo tee /etc/systemd/system/initiad.service > /dev/null <<EOF
[Unit]
Description=initiad

[Service]
Type=simple
User=$USER
ExecStart=$(which initiad) start
Restart=on-abort
StandardOutput=journal
StandardError=journal
SyslogIdentifier=initiad
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl enable initiad
    sudo systemctl daemon-reload
	sudo systemctl restart initiad
    
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
	sudo systemctl enable slinkyd
    sudo systemctl daemon-reload
	sudo systemctl restart slinkyd
       
	# Run with the core oracle config from the repo.
	#./build/slinky --oracle-config-path ./config/core/oracle.json --market-map-endpoint 0.0.0.0:9090
    
	echo "部署完成"
}

# 下载快照
function download_snap(){
	echo "快照文件较大，下载需要较长时间，请保持电脑屏幕不要熄灭"
    read -p "浏览器打开https://polkachu.com/testnets/initia/snapshots选择最新快照文件，输入[ initia_数字.tar.lz4 ]具体名称: " filename
    source $HOME/.bash_profile
    # 下载快照
    if wget -P $HOME/ https://snapshots.polkachu.com/testnet-snapshots/initia/$filename ;
    then
        sudo systemctl stop initiad
    	initiad tendermint unsafe-reset-all --home $HOME/.initia --keep-addr-book
    	lz4 -c -d $filename | tar -x -C $HOME/.initia
        # 启动节点进程
        sudo systemctl start initiad
    else
        echo "下载失败。"
        exit 1
    fi
}

# 创建钱包
function create_wallet(){
    # 创建钱包
    source $HOME/.bash_profile
    read -p "钱包名称:" wallet_name
    initiad keys add $wallet_name
}

# 导入钱包
function import_wallet() {
	source $HOME/.bash_profile
	read -p "钱包名称:" wallet_name
    initiad keys add $wallet_name --recover
}

# 创建验证者
function add_validator() {
	source $HOME/.bash_profile
    echo "先填表：https://forms.gle/LtxqGcJPNYXwwkxP9，不然官方不通过"
    read -p "验证者名称:" validator_name
    read -r -p "请输入你的钱包名称: " wallet_name
    
    initiad tx mstaking create-validator --amount="1000000uinit" --pubkey=$(initiad tendermint show-validator) --moniker="$validator_name" --identity="" --chain-id="initiation-1" --from="$wallet_name" --commission-rate="0.10" --commission-max-rate="0.20" --commission-max-change-rate="0.01"
}

# 查看验证者公钥
function show_validator_key(){
	source $HOME/.bash_profile
	initiad tendermint show-validator
}

# 申请出狱
function unjail(){
	source $HOME/.bash_profile
	read -p "节点名称:" NODE_MONIKER
	#initiad tx slashing unjail <validator address>
}

# 查看节点同步进度
function check_sync_status() {
	source $HOME/.bash_profile
    initiad status | jq .sync_info
}

# 查看日志
function view_logs(){
	journalctl -t initiad -f
}

# 查看余额
function check_balance(){
	source $HOME/.bash_profile
    read -p "钱包地址:" wallet_addr
    initiad query bank balances "$wallet_addr"
}

# 质押代币
function delegate_self_validator() {
	source $HOME/.bash_profile
    read -p "钱包名称: " wallet_name
    read -p "质押数量: " input
    math=$((input * 1000000))
    initiad tx mstaking delegate $(initiad keys show $wallet_name --bech val -a) ${math}uinit --from $wallet_name --chain-id initiation-1 --gas=2000000 --fees=300000uinit -y
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
		echo "感谢以下无私的分享者："
    	echo "langzishu.eth 提供了验证者申请链接"
    	echo "===============桃花潭水深千尺，不及汪伦送我情================="
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
#!/bin/bash

# 一键安装 Shadowsocks-rust 服务端脚本（CentOS 7）
# 作者：Anonymous
# 最后更新：2023-10

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo "错误：本脚本需要以 root 权限运行！" 
   exit 1
fi

# 配置参数（可修改）
SS_PORT="4430"
SS_PASSWORD="vOFWNdmpkFFaBxTILNW5XzEeWu0/W2ZIwNsblH688CA="
SS_METHOD="aes-256-gcm"
SS_BINARY_PATH="/usr/local/bin/ssserver"
CONFIG_FILE="/etc/shadowsocks-rust/config.json"
SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"

# 安装依赖
echo "安装系统依赖..."
yum install -y wget firewalld

# 下载最新版 Shadowsocks-rust
echo "下载 Shadowsocks-rust..."
LATEST_RELEASE=$(wget -qO- "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | grep "tag_name" | cut -d '"' -f 4)
RELEASE_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_RELEASE}/shadowsocks-${LATEST_RELEASE}.x86_64-unknown-linux-gnu.tar.xz"

wget -O /tmp/ss.tar.xz $RELEASE_URL
tar -xvf /tmp/ss.tar.xz -C /tmp

# 安装二进制文件
echo "安装到 ${SS_BINARY_PATH}..."
mv "/tmp/ssserver" $SS_BINARY_PATH
chmod +x $SS_BINARY_PATH

# 创建配置文件目录
mkdir -p /etc/shadowsocks-rust

# 生成配置文件
echo "生成配置文件 ${CONFIG_FILE}..."
cat > $CONFIG_FILE << EOF
{
    "server": "0.0.0.0",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "method": "${SS_METHOD}",
    "fast_open": true
}
EOF

# 创建 systemd 服务
echo "创建 systemd 服务..."
cat > $SERVICE_FILE << EOF
[Unit]
Description=Shadowsocks-rust Server
After=network.target

[Service]
ExecStart=${SS_BINARY_PATH} --config ${CONFIG_FILE}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# 防火墙设置
echo "配置防火墙..."
systemctl start firewalld
firewall-cmd --permanent --add-port=${SS_PORT}/tcp
firewall-cmd --permanent --add-port=${SS_PORT}/udp
firewall-cmd --reload

# 启动服务
echo "启动服务..."
systemctl daemon-reload
systemctl enable shadowsocks-rust
systemctl start shadowsocks-rust

# 检查状态
echo "检查服务状态..."
systemctl status shadowsocks-rust --no-pager

# 输出配置信息
echo "========================================================"
echo "Shadowsocks-rust 安装完成！"
echo "连接信息："
echo "服务器IP  : $(curl -s 4.ipw.cn)"
echo "端口      : ${SS_PORT}"
echo "密码      : ${SS_PASSWORD}"
echo "加密方式  : ${SS_METHOD}"
echo "========================================================"
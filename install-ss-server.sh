yum -y install tar
yum -y install wget
cd ~
mkdir ss-rust
cd ss-rust
wget https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.23.0/shadowsocks-v1.23.0.x86_64-unknown-linux-gnu.tar.xz
tar -xvf shadowsocks-v1.23.0.x86_64-unknown-linux-gnu.tar.xz
rm -f shadowsocks-v1.23.0.x86_64-unknown-linux-gnu.tar.xz
echo $'{"server": "0.0.0.0","server_port": 4430,"password": "vOFWNdmpkFFaBxTILNW5XzEeWu0/W2ZIwNsblH688CA=","method": "aes-256-gcm"}' >> config.json
chmod +x /etc/rc.d/rc.local
echo "nohup /root/ss-rust/ssserver -c /root/ss-rust/config.json &" >> /etc/rc.d/rc.local
/root/ss-rust/ssserver -c /root/ss-rust/config.json
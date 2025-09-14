## 1. 前置条件

* 系统已安装：`bash`、`curl`、`openssl`、`jq`
* 80 端口可从公网直连到本机（用于 ​**HTTP 文件校验**​）
* 你已获取 ​**ZeroSSL access\_key**​（控制台 → Developer）

## 2. 安装

```
cd /usr/local/bin
```

```
git clone https://github.com/soybeanAdmin/zerossl-ipcert.git
```

## 3. 初始化

### 3.1 放置脚本与配置

​**脚本**​（`/usr/local/bin/zerossl-ipcert/zerossl-ipcert.sh`）确保可执行：

```bash
sudo chmod +x /usr/local/bin/zerossl-ipcert/zerossl-ipcert.sh
```

​**同目录 `.env` 示例**​（`/usr/local/bin/.env`）：

```.env
# ZeroSSL 访问密钥（控制台 Developer 里拿）
ZEROSSL_KEY="你的_access_key"

# 目标公网 IP（要签发证书的那个 IP）
IP="1.2.3.4"

# 有付费年证书配额就设 365；否则用 90
VALID_DAYS=90

# Web 根（校验文件会写在 $WEBROOT/.well-known/pki-validation/）, 参考服务器上的 Caddy/Nginx 配置
WEBROOT="/usr/share/caddy"

# 证书安装目录（会自动创建），参考服务器上的 Caddy/Nginx 配置
INSTALL_DIR="/usr/share/caddy/zerossl"

# 证书到期前多少天开始续期
RENEW_BEFORE_DAYS=30

# 是否每次续期更换私钥（1=每次换新；0=沿用原私钥）
ROTATE_KEY=0

# 成功后执行的重载命令（按你的环境二选一）
POST_RELOAD_CMD="systemctl reload nginx"
# POST_RELOAD_CMD="systemctl reload caddy"    # 如果用 Caddy
```

> 说明：脚本已内置 `SCRIPT_DIR/.env` 加载逻辑，无需再在 service 里指定 `EnvironmentFile`。

---

## 4. 参考 Caddy 配置

​**Caddyfile**​（最小可用）：

```
:443 {
    # HTTPS: 使用你已经下发的 IP 证书
    tls /usr/share/caddy/zerossl/fullchain.pem /usr/share/caddy/zerossl/privkey.key

    root * /usr/share/caddy
    file_server
    @api path /api/*

    handle @api {
        reverse_proxy https://board.suyou.org {
            header_up Host {upstream_hostport}
            header_up X-Forwarded-Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            header_up Referer "https://board.suyou.org"
            header_up Origin "https://board.suyou.org"
        }
    }
}
# 用户验证文件 
:80 {
 #验证文件位置可根据证书申请脚本 .env 自定义
  handle /.well-known/pki-validation/* {
	root * /usr/share/caddy
    	file_server
   }
   root * /usr/share/caddy
   file_server
}
```

## 5. 首次安装

```
sudo /usr/local/bin/zerossl-ipcert/zerossl-ipcert.sh run
```

## 6. 自动续期

### 6.1 Service（`/etc/systemd/system/zerossl-ipcert.service`）

```ini
[Unit]
Description=ZeroSSL IP certificate issue/renew
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zerossl-ipcert/zerossl-ipcert.sh run
```

### 6.2 Timer（`/etc/systemd/system/zerossl-ipcert.timer`）

```
[Unit]
Description=Run ZeroSSL IP cert renew daily

[Timer]
# 每天本地时间 00:00 执行，随机抖动 0-5 分钟；错过会补跑
OnCalendar=daily
RandomizedDelaySec=5m
Persistent=true

[Install]
WantedBy=timers.target
```

### 6.3 启用自动续签定时任务

```
sudo systemctl daemon-reload
# 启动定时器
sudo systemctl enable --now zerossl-ipcert.timer
# 参看运行状态
systemctl status zerossl-ipcert.timer --no-pager
# 执行时间
systemctl list-timers | grep zerossl-ipcert

```

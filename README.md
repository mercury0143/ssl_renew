# SSL 证书自动续期 & 多服务器分发

一键续期 Let's Encrypt 泛域名证书，并自动分发到多台服务器。

## 目录结构

```
ssl_reload/
├── renew-cert.sh      # 主脚本：续期 + 分发
├── dns-auth.py        # DNS 验证钩子（添加 TXT 记录）
├── dns-cleanup.py     # DNS 清理钩子（删除 TXT 记录）
├── notify-feishu.py   # 飞书通知脚本（可选）
├── config.env         # 阿里云 DNS API 配置
└── requirements.txt   # Python 依赖
```
 
---

## 快速开始

### 1. 安装依赖

```bash
# 安装 certbot
apt update && apt install -y certbot

# 安装 Python 依赖
pip3 install alibabacloud-alidns20150109
```

### 2. 配置阿里云 DNS API

编辑 `config.env`：

```bash
ALICLOUD_ACCESS_KEY="你的AccessKey"
ALICLOUD_SECRET_KEY="你的SecretKey"
ALICLOUD_REGION="cn-shenzhen"
DNS_PROPAGATION_WAIT=60
```

### 3. 配置目标服务器

编辑 `renew-cert.sh` 中的 `SERVERS` 数组（约第 24 行）：

```bash
SERVERS=(
    "192.168.1.1"
    "192.168.1.2"
    "192.168.1.3"
)
```

### 4. 配置 SSH 免密登录

确保控制机可以免密 SSH 到所有目标服务器：

```bash
# 生成密钥（如果没有）
ssh-keygen -t rsa -b 4096

# 复制到目标服务器
ssh-copy-id root@192.168.1.1
ssh-copy-id root@192.168.1.2
ssh-copy-id root@192.168.1.3

# 测试连接
ssh -o BatchMode=yes root@192.168.1.1 "echo ok"
```

### 5. 设置权限

```bash
chmod +x *.py *.sh
chmod 600 config.env
```

---

## 使用方式

### 测试模式（不实际申请证书）

```bash
./renew-cert.sh --dry-run
```

### 首次申请 / 强制续期

```bash
./renew-cert.sh --force
```

### 正常续期（证书快过期时才续期）

```bash
./renew-cert.sh
```

### 设置定时任务

```bash
# 编辑 crontab
crontab -e

# 添加以下行（每天凌晨 3 点执行）
0 3 * * * /opt/ssl_reload/renew-cert.sh >> /var/log/certbot-renew.log 2>&1

# 每小时执行，日志按天轮转
0 * * * * /path/to/renew-cert.sh >> /var/log/cert-renew-$(date +\%Y\%m\%d).log 2>&1
```

---

## 失败策略

### 默认行为

- **部署失败**：跳过失败服务器，继续处理剩余服务器
- **日志输出**：失败信息打印到 stderr
- **退出码**：有失败时返回非 0

### 日志示例

```
[2025-12-06 03:00:00] [INFO] 开始证书续期: *.cloudacre.cn
[2025-12-06 03:00:30] [INFO] 证书续期成功，开始分发到 3 台服务器...
[2025-12-06 03:00:31] [INFO] 开始部署到 192.168.1.1 ...
[2025-12-06 03:00:32] [SUCCESS] 192.168.1.1: 部署成功
[2025-12-06 03:00:33] [INFO] 开始部署到 192.168.1.2 ...
[2025-12-06 03:00:43] [ERROR] 192.168.1.2: SCP fullchain.pem 失败
[2025-12-06 03:00:44] [INFO] 开始部署到 192.168.1.3 ...
[2025-12-06 03:00:45] [SUCCESS] 192.168.1.3: 部署成功
[2025-12-06 03:00:45] [INFO] ========== 部署汇总 ==========
[2025-12-06 03:00:45] [INFO] 成功: 2 台 [192.168.1.1,192.168.1.3]
[2025-12-06 03:00:45] [INFO] 失败: 1 台 [192.168.1.2]
[2025-12-06 03:00:45] [ERROR] 以下服务器部署失败:
[2025-12-06 03:00:45] [ERROR]   - 192.168.1.2
```

---

## 扩展：飞书通知

### 配置 Webhook

1. 在飞书群中添加自定义机器人，获取 Webhook URL
2. 编辑 `renew-cert.sh`，填入 Webhook URL（约第 37 行）：

```bash
# 飞书通知配置（留空则不发送）
FEISHU_WEBHOOK_URL="https://open.feishu.cn/open-apis/bot/v2/hook/你的HOOK_ID"
```

> **留空则跳过通知**，不影响主流程。

### 手动测试通知

```bash
python3 notify-feishu.py \
    --webhook "https://open.feishu.cn/open-apis/bot/v2/hook/你的HOOK_ID" \
    --success "192.168.1.1,192.168.1.3" \
    --failed "192.168.1.2" \
    --domain "*.cloudacre.cn"
```

### 通知效果

飞书卡片消息：

```
🔐 SSL 证书部署报告
━━━━━━━━━━━━━━━━━━━━━
域名: *.cloudacre.cn

✅ 成功: 2 台    ❌ 失败: 1 台
━━━━━━━━━━━━━━━━━━━━━
成功列表: 192.168.1.1, 192.168.1.3
失败列表: 192.168.1.2
```

---

## 故障排查

### SSH 连接失败

```bash
# 检查 SSH 连接
ssh -v -o BatchMode=yes root@目标IP "echo ok"

# 常见原因：
# 1. 未配置 SSH 密钥
# 2. 防火墙阻止 22 端口
# 3. 服务器宕机
```

### certbot 失败

```bash
# 查看 certbot 日志
tail -f /var/log/letsencrypt/letsencrypt.log

# 常见原因：
# 1. DNS API 配置错误
# 2. 域名不属于你
# 3. 速率限制（一周最多 5 次）
```

### nginx 重启失败

```bash
# SSH 到目标服务器检查
ssh root@目标IP "nginx -t"

# 常见原因：
# 1. nginx 配置语法错误
# 2. 证书路径不对
```

---

## 配置说明

### renew-cert.sh 关键配置

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `DOMAIN` | 主域名 | `cloudacre.cn` |
| `WILDCARD_DOMAIN` | 泛域名 | `*.cloudacre.cn` |
| `CERT_DEST_DIR` | 证书目标目录 | `/opt/cert` |
| `SSH_USER` | SSH 用户名 | `root` |
| `SERVERS` | 服务器 IP 列表 | 需要修改 |

### SSH 选项说明

| 选项 | 说明 |
|------|------|
| `ConnectTimeout=10` | 连接超时 10 秒 |
| `StrictHostKeyChecking=no` | 跳过首次指纹确认 |
| `BatchMode=yes` | 非交互模式 |


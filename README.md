# EwoMail Docker（Ubuntu 22.04 优化版）

把只支持 CentOS 7/8 的 [EwoMail](http://doc.ewomail.com/docs/ewomail/install) 迁移到 **Ubuntu + Docker Compose**，并修复原版在安全性与投递可靠性上的问题。

组件：Postfix + Dovecot + Amavis + ClamAV + SpamAssassin + Nginx + PHP 8.1 + MariaDB 10.11 + SnappyMail。

---

## 一、相对原版的优化

### 1. 不再绑定 CentOS

原版 `install/start.sh` 第一步就读取 `/etc/redhat-release`、调用 `yum`、`firewalld`、`service mysqld`，在 Ubuntu 上必然失败。本方案改为 Docker Compose 三容器编排：

| 容器 | 内容 | 内存上限 |
| --- | --- | --- |
| `ewomail-app` | Postfix / Dovecot / Amavis / Nginx / PHP-FPM | 800M |
| `ewomail-db` | MariaDB 10.11 | 320M |
| `ewomail-clamav` | ClamAV 病毒库 | 650M |

数据全部落在 `./data`，`docker compose down` 不会丢邮件。

### 2. 修复“发出去但对方收不到”的根因

原版 `main.cf`：

```
maximal_queue_lifetime = 300s
bounce_queue_lifetime  = 300s
```

只要对方服务器临时性拒信（4xx、灰名单、限流），5 分钟后邮件就被**永久退信删除**。本方案改为：

```
maximal_queue_lifetime = 3d
bounce_queue_lifetime  = 3d
queue_run_delay        = 60s
minimal_backoff_time   = 300s
maximal_backoff_time   = 1h
```

### 3. TLS 基线提升

| 项目 | 原版 | 本方案 |
| --- | --- | --- |
| SMTP 协议 | `TLSv1.1,TLSv1.2` | `>=TLSv1.2` |
| 明文认证 | `smtpd_tls_auth_only = no` | `yes`（必须加密后才允许 AUTH） |
| 后台/邮箱 | 8010、8000 明文 HTTP | 强制跳转 7010 / 7000 HTTPS |
| Nginx | phpMyAdmin 站点开启 `SSLv2 SSLv3` | 删除 phpMyAdmin，仅 `TLSv1.2 TLSv1.3` |

### 4. 密码存储从 MD5 升级为 bcrypt

原版管理员与邮箱密码均为无盐 `md5()`。本方案：

- PHP 端统一使用 `ew_hash_password()` / `ew_verify_password()`，新密码写入 bcrypt；
- 仍兼容历史 32 位 MD5（Dovecot 按 `$2y$` 前缀自动识别 bcrypt 哈希）；
- 启动脚本只在密码仍是安装默认值时写入 `.env` 中的密码，**不会覆盖后台已修改的密码**。

### 5. SQL 注入收敛

原版 `Db.class.php` 的 `insert()` / `update()` 直接把数组拼进 SQL。本方案在 `Db` 中新增 `quote()`，写入路径全部转义；登录与 API 模块的 `username` / `email` 查询同样改为转义拼接。

### 6. 修复后台 fatal error

原版 `module/Center/Domain.php`（DKIM 页）与 `Users.php`（系统设置保存）会 `new Server()`，但仓库里**没有 `Server` 类**，点击即 500。本方案补齐 `api/Server.class.php`，通过 sudo 白名单调用容器内脚本，不再依赖 SSH。

### 7. DKIM 覆盖全部域名

原版只为主域写死一个密钥。本方案：

- `bin/dkim.sh` 按域名生成 2048 位密钥，公钥可直接复制到 DNS；
- `bin/sync-dkim.sh` 每分钟同步数据库中的全部启用域名，生成 Amavis 签名配置并热加载；
- 后台“域名管理 → DKIM”会同时显示记录值与本机对 DNS 的校验结果。

### 8. 其他

- 附件上限由 `message_size_limit = 0`（无限制）改为 50MB，防止被大附件拖垮队列；
- 增加发信频率限制（连接 30/分钟、单连接 20、收件人 200），降低账号被盗后群发风险；
- `smtpd_helo_required = yes`、`disable_vrfy_command = yes`；
- 用 **SnappyMail 2.38** 替代已停止维护的 RainLoop 1.10（兼容 PHP 8）；
- 移除 phpMyAdmin 5.0.2（已 EOL 且有未修复 CVE）；
- 数据库、PHP-FPM、Amavis 均按 1C/1G 小机器调优；`clamav` 独立容器，避免扫描时拖垮 MTA。

### 9. 容器化过程中额外修复的运行时问题

| 问题 | 现象 | 处理 |
| --- | --- | --- |
| `i_admin.password` 为 `varchar(32)` | 写入 bcrypt 报 `Data too long` | 表结构改为 `varchar(255)`，启动时幂等 `ALTER` |
| `mysqladmin ping` 在鉴权失败时仍返回成功 | 启动脚本误判数据库就绪，反复重启 | 改为 `mysql -e "SELECT 1"` 真实查询并失败退出 |
| Dovecot `protocols = ... sieve` | `Unknown protocol: sieve` | 从 `protocols` 移除 sieve，仅作为 LMTP 插件使用 |
| `amavisd-new -f` | `Error in parsing command line options: -f` | 改用 `amavisd-new foreground` |
| `/var/log` 为宿主机挂载目录 | rsyslog 无写权限，日志为空 | 启动时创建并授权 `mail.log` / `syslog` / `nginx` |
| ClamAV 首次加载特征库 | 650M 上限下被 OOM Kill | 上限提到 1400M，并要求 1G 机器加 swap |
| `$childs_per_interval` | Amavis 2.13 已移除该变量，启动报 `requires explicit package name` | 从 `50-user` 模板删除 |
| Amavis 配置文件属主 | `60-ewomail-dkim should be owned by root` | 改为 `root:amavis 640` |
| Dovecot SQL 认证 | `Unknown database driver 'mysql'`，IMAP/SMTP 认证全失败 | 镜像增加 `dovecot-mysql` 包 |

---

## 二、快速部署

### 环境要求

- Ubuntu 22.04 / 24.04
- **建议 2 核 2G 内存**。1 核 1G 也能跑，但必须加 swap：
  - ClamAV 加载约 360 万条特征时内存峰值约 1.2G，1G 机器不加 swap 会被 OOM Kill（表现为容器反复重启、SSH 卡死）；
  - `deploy.sh` 会在内存不足 3G 且 swap 不足 1G 时自动创建 3G swap，也可以手动执行：
    ```bash
    fallocate -l 3G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ```
- 已有 Docker 与 `docker compose`；没有的话 `deploy.sh` 会自动安装
- 25 / 465 / 587 / 143 / 993 / 110 / 995 / 7000 / 7010 端口可用
- 云厂商安全组需放行上述端口，并申请 **25 端口解封**（多数云默认封禁）

### 步骤

```bash
cp .env.example .env
vi .env          # 修改 DOMAIN、MAIL_HOSTNAME、各类密码

sudo bash deploy.sh          # 自动装 compose 插件、按需建 swap、构建并启动
# 或手动：
sudo docker compose up -d --build
```

启动后：

- 后台管理：`https://mail.example.com:7010`，账号 `admin`，密码为 `.env` 中的 `ADMIN_PASSWORD`
- 网页邮箱：`https://mail.example.com:7000`

首次启动会自签一张证书保证可用；换成正式证书只需把 `fullchain.pem` 与 `privkey.pem` 放入 `./data/ssl/` 后 `docker compose restart app`。

---

## 三、DNS 记录

以 `DOMAIN=example.com`、`MAIL_HOSTNAME=mail.example.com` 为例：

| 类型 | 主机记录 | 值 |
| --- | --- | --- |
| A | `mail` | 服务器公网 IP |
| MX | `@` | `mail.example.com`（优先级 10） |
| TXT | `@` | `v=spf1 mx -all` |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com` |
| TXT | `dkim._domainkey` | 后台“域名管理 → DKIM”复制 |
| PTR | 服务器 IP 反向解析 | `mail.example.com`（由云厂商设置） |

> PTR 与 `MAIL_HOSTNAME` 必须一致，否则 Gmail / Outlook 大概率判垃圾。

---

## 四、端口

| 端口 | 用途 |
| --- | --- |
| 25 | SMTP（服务器之间投递） |
| 465 | SMTPS（客户端推荐） |
| 587 | Submission + STARTTLS |
| 143 / 993 | IMAP / IMAPS |
| 110 / 995 | POP3 / POP3S |
| 7010 | 后台管理（HTTPS，8010 仅跳转） |
| 7000 | 网页邮箱（HTTPS，8000 仅跳转） |

---

## 五、日常使用

1. 登录后台 → **域名管理 → 添加域名**（填 `example.com`）。
2. **邮箱管理 → 添加邮箱**，密码 8–20 位。
3. 打开该域名的 **DKIM**，复制 TXT 记录到 DNS，等待生效后刷新页面应显示 `pass`。
4. 网页邮箱用同一个邮箱地址与密码登录。

### 目录说明

```
data/mail      邮件原文（Maildir）
data/dkim      DKIM 私钥（每域名一个目录）
data/ssl       TLS 证书
data/mysql     数据库
data/log       Postfix / Dovecot / Nginx 日志
```

### 常用命令

```bash
docker compose ps
docker compose logs -f app
docker exec ewomail-app postqueue -p        # 查看队列
docker exec ewomail-app postqueue -f        # 立即重试队列
docker exec ewomail-app supervisorctl status
```

### 备份

```bash
tar czf ewomail-$(date +%F).tar.gz data/mail data/dkim data/ssl data/mysql
```

---

## 六、已知限制

- 单机部署，未包含高可用与多节点队列；
- 未内置配额强制（后台容量字段仅记录，Dovecot 未启用 quota 插件）；
- 首次构建需从 GitHub 下载 SnappyMail，国内网络可能较慢，可先改 `app/Dockerfile` 中的 `SNAPPYMAIL_VERSION` 或用代理；
- 后台前端沿用 EwoMail 原版 Bootstrap 风格，未做 UI 重构。

## 许可

EwoMail 后台代码版权归原项目作者所有；本仓库仅提供容器化与安全加固改动。

#!/usr/bin/env bash
# 一键部署脚本（Ubuntu 22.04 / 24.04）
# 用法: sudo bash deploy.sh
set -euo pipefail

cd "$(dirname "$0")"

log() { echo -e "\033[32m[deploy]\033[0m $*"; }
warn() { echo -e "\033[33m[deploy]\033[0m $*"; }

if [ "$(id -u)" != "0" ]; then
    echo "请用 root 运行：sudo bash deploy.sh"
    exit 1
fi

# ---------- Docker ----------
if ! command -v docker >/dev/null 2>&1; then
    log "安装 Docker"
    apt-get update
    apt-get install -y docker.io
    systemctl enable --now docker
fi

if ! docker compose version >/dev/null 2>&1; then
    log "安装 docker compose 插件"
    apt-get update
    apt-get install -y docker-compose-plugin 2>/dev/null \
        || apt-get install -y docker-compose-v2 2>/dev/null \
        || apt-get install -y docker-compose
fi

if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    echo "未能安装 docker compose，请手动安装后重试"
    exit 1
fi

# ---------- Swap（EwoMail + ClamAV 建议至少 2G 内存 + 2G swap） ----------
MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
SWAP_MB="$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)"
if [ "$SWAP_MB" -lt 1024 ] && [ "$MEM_MB" -lt 3072 ]; then
    log "创建 3G swap（当前内存 ${MEM_MB}MB，swap ${SWAP_MB}MB）"
    if [ ! -f /swapfile ]; then
        fallocate -l 3G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=3072
        chmod 600 /swapfile
        mkswap /swapfile
    fi
    swapon /swapfile 2>/dev/null || true
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=20 >/dev/null
fi

# ---------- .env ----------
if [ ! -f .env ]; then
    cp .env.example .env
    RAND1="$(openssl rand -hex 12)"
    RAND2="$(openssl rand -hex 12)"
    sed -i "s|^DB_ROOT_PASSWORD=.*|DB_ROOT_PASSWORD=${RAND1}|" .env
    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${RAND2}|" .env
    warn "已生成 .env，请修改 DOMAIN / MAIL_HOSTNAME / ADMIN_PASSWORD 后重新运行"
    exit 0
fi

for key in DOMAIN MAIL_HOSTNAME DB_PASSWORD ADMIN_PASSWORD; do
    value="$(grep -E "^${key}=" .env | head -n1 | cut -d= -f2- || true)"
    if [ -z "$value" ]; then
        echo ".env 缺少 $key"
        exit 1
    fi
done

# ---------- 防火墙 ----------
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    log "放行邮件与 Web 端口"
    for p in 25 465 587 143 993 110 995 7000 7010; do ufw allow "$p"/tcp >/dev/null || true; done
fi

# ---------- 启动 ----------
log "构建并启动服务（首次构建需要下载依赖）"
"${COMPOSE[@]}" up -d --build

log "等待容器就绪"
sleep 15
"${COMPOSE[@]}" ps

cat <<EOF

部署完成：
  后台管理   https://$(grep -E '^MAIL_HOSTNAME=' .env | cut -d= -f2-):7010
  网页邮箱   https://$(grep -E '^MAIL_HOSTNAME=' .env | cut -d= -f2-):7000
  管理员     admin
  管理员密码 见 .env 中的 ADMIN_PASSWORD

请确认以下 DNS 记录已生效：
  A      $(grep -E '^MAIL_HOSTNAME=' .env | cut -d= -f2-)      <服务器公网 IP>
  MX     $(grep -E '^DOMAIN=' .env | cut -d= -f2-)              $(grep -E '^MAIL_HOSTNAME=' .env | cut -d= -f2-)
  TXT    $(grep -E '^DOMAIN=' .env | cut -d= -f2-)              v=spf1 mx -all
  TXT    _dmarc   v=DMARC1; p=quarantine; rua=mailto:postmaster@$(grep -E '^DOMAIN=' .env | cut -d= -f2-)
  TXT    dkim._domainkey   （在后台“域名管理 - DKIM”中复制）

EOF

#!/usr/bin/env bash
# 遍历数据库中的所有启用域名，生成/复用 DKIM 密钥，并刷新 amavis 签名配置
# 由 entrypoint 与 cron 每分钟调用，可重复执行
set -uo pipefail

: "${DB_HOST:?}"
: "${DB_NAME:?}"
: "${DB_USER:?}"
: "${DB_PASSWORD:?}"

BIN_DIR="/opt/ewomail/bin"
CONF="/ewomail/dkim/amavis-dkim.conf"
TMP="$(mktemp)"

MYSQL=(mysql -N -B -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" --default-character-set=utf8mb4)

DOMAINS="$("${MYSQL[@]}" -e "SELECT name FROM i_domains WHERE active=1" 2>/dev/null || true)"

{
    echo "# 由 /opt/ewomail/bin/sync-dkim.sh 自动生成，请勿手工修改"
    echo "\$enable_dkim_signing = 1;"
    echo "\$enable_dkim_verification = 1;"
    for d in $DOMAINS; do
        [ -z "$d" ] && continue
        printf '%s' "$d" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || continue
        "$BIN_DIR/dkim.sh" getkey "$d" >/dev/null 2>&1 || true
        if [ -s "/ewomail/dkim/$d/dkim.key" ]; then
            echo "dkim_key('$d', 'dkim', '/ewomail/dkim/$d/dkim.key');"
        fi
    done
    echo "@dkim_signature_options_bysender_maps = ( { '.' => { ttl => 172800, c => 'relaxed/simple', a => 'rsa-sha256' } } );"
} > "$TMP"

if ! cmp -s "$TMP" "$CONF" 2>/dev/null; then
    mv "$TMP" "$CONF"
    # amavis 要求配置文件属主为 root
    chown root:amavis "$CONF" 2>/dev/null || true
    chmod 640 "$CONF"
    echo "[sync-dkim] config updated"
    # amavis 只在运行中才需要重载；-o 只对最老的进程（master）发信号
    if pgrep -u amavis -f amavisd >/dev/null 2>&1; then
        pkill -HUP -o -u amavis -f amavisd >/dev/null 2>&1 || true
        echo "[sync-dkim] amavis reloaded"
    fi
else
    rm -f "$TMP"
fi

#!/usr/bin/env bash
# 为单个域名生成/读取 DKIM 密钥，并输出后台页面需要的 JSON
# 用法: dkim.sh getkey <domain>
set -uo pipefail

ACTION="${1:-getkey}"
DOMAIN="${2:-}"

emit() { printf '{"key":"%s","testkeys":"%s"}\n' "$1" "$2"; }

if [ -z "$DOMAIN" ] || ! printf '%s' "$DOMAIN" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; then
    emit "" "invalid domain"
    exit 0
fi

KEYDIR="/ewomail/dkim/${DOMAIN}"
KEY="${KEYDIR}/dkim.key"
PUB="${KEYDIR}/dkim.pub"
SELECTOR="dkim"

if [ "$ACTION" != "getkey" ]; then
    emit "" "unsupported action"
    exit 0
fi

if [ ! -s "$KEY" ]; then
    install -d -m 2770 "$KEYDIR" 2>/dev/null || true
    chown www-data:amavis "$KEYDIR" 2>/dev/null || true
    if ! openssl genrsa -out "$KEY" 2048 >/dev/null 2>&1; then
        emit "" "failed to generate key"
        exit 0
    fi
    chown root:amavis "$KEY" 2>/dev/null || true
    chmod 640 "$KEY"
fi

if [ ! -s "$PUB" ] || [ "$KEY" -nt "$PUB" ]; then
    if openssl rsa -in "$KEY" -pubout -out "${PUB}.tmp" >/dev/null 2>&1; then
        grep -v -- '-----' "${PUB}.tmp" | tr -d '\n\r ' > "$PUB"
        rm -f "${PUB}.tmp"
        chown www-data:www-data "$PUB" 2>/dev/null || true
        chmod 644 "$PUB"
    fi
fi

BODY="$(cat "$PUB" 2>/dev/null || true)"
RECORD="v=DKIM1; k=rsa; p=${BODY}"

# 用公共 DNS 校验记录是否已经生效
DNS_TXT="$(dig +short +time=3 +tries=1 TXT "${SELECTOR}._domainkey.${DOMAIN}" @223.5.5.5 2>/dev/null | tr -d '"' | tr -d '\n' | tr -s ' ')"
NORM_DNS="$(printf '%s' "$DNS_TXT" | tr -d ' ')"
NORM_REC="$(printf '%s' "$RECORD" | tr -d ' ')"

if [ -z "$BODY" ]; then
    TEST="key not ready"
elif [ -z "$NORM_DNS" ]; then
    TEST="NXDOMAIN: TXT ${SELECTOR}._domainkey.${DOMAIN} not found"
elif [ "$NORM_DNS" = "$NORM_REC" ]; then
    TEST="pass: DNS record matches private key"
else
    TEST="fail: DNS record differs from local public key"
fi

emit "$RECORD" "$TEST"

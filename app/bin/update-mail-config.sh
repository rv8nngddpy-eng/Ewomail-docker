#!/usr/bin/env bash
# 后台“邮件系统设置”保存后调用：同步 Postfix 的主域与主机名
# 用法: update-mail-config.sh <mydomain> <myhostname>
set -euo pipefail

DOMAIN="${1:-}"
HOST="${2:-}"

printf '%s' "$DOMAIN" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || exit 1
printf '%s' "$HOST" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || exit 1

postconf -e "mydomain = ${DOMAIN}"
postconf -e "myhostname = ${HOST}"
postconf -e "myorigin = \$myhostname"
postfix reload >/dev/null 2>&1 || true

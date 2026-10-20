#!/usr/bin/env bash
set -euo pipefail

: "${DOMAIN:?DOMAIN is required}"
: "${MAIL_HOSTNAME:?MAIL_HOSTNAME is required}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"

DB_HOST="${DB_HOST:-db}"
DB_NAME="${DB_NAME:-ewomail}"
DB_USER="${DB_USER:-ewomail}"

log() { echo "[ewomail] $*"; }

export DEBIAN_FRONTEND=noninteractive

# ---------- 用户与目录 ----------
groupadd -g 5000 vmail 2>/dev/null || true
useradd -u 5000 -g vmail -M -s /usr/sbin/nologin vmail 2>/dev/null || true
usermod -aG vmail www-data
usermod -aG amavis www-data

install -d -o vmail -g vmail -m 0770 /ewomail/mail /ewomail/mail/vmail
install -d -o www-data -g amavis -m 2770 /ewomail/dkim
install -d -o root -g root -m 0755 /ewomail/ssl
install -d -o www-data -g www-data -m 0770 \
    /ewomail/www/session/ewomail-admin /ewomail/www/session/webmail
install -d -o amavis -g amavis -m 0755 /run/amavis /var/lib/amavis
install -d -m 0755 /run/dovecot /var/log/nginx /var/log/supervisor
install -d -o postfix -g postfix -m 0700 /var/spool/postfix/private 2>/dev/null || true
# /var/log 由宿主机挂载，需要给 syslog / nginx 用户写权限
touch /var/log/mail.log /var/log/mail.err /var/log/syslog
chown syslog:adm /var/log/mail.log /var/log/mail.err /var/log/syslog 2>/dev/null || true
chmod 640 /var/log/mail.log /var/log/mail.err /var/log/syslog 2>/dev/null || true
chown -R www-data:adm /var/log/nginx 2>/dev/null || true
chown -R amavis:adm /var/log/amavis 2>/dev/null || true
chown -R www-data:www-data /ewomail/www
chmod 600 /ewomail/config.ini 2>/dev/null || true

# ---------- 等待数据库 ----------
log "waiting for database ${DB_HOST} ..."
DB_READY=0
for _ in $(seq 1 90); do
    # mysqladmin ping 在鉴权失败时也会返回成功，这里必须用真实查询判断
    if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
        DB_READY=1
        break
    fi
    sleep 2
done
if [ "$DB_READY" != "1" ]; then
    log "database ${DB_HOST} not reachable or credentials rejected (user=${DB_USER})"
    exit 1
fi

MYSQL=(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" --default-character-set=utf8mb4)

# ---------- 初始化表结构 ----------
if ! "${MYSQL[@]}" -e "SELECT 1 FROM i_users LIMIT 1" >/dev/null 2>&1; then
    log "importing schema"
    "${MYSQL[@]}" < /opt/ewomail/install.sql
fi

ADMIN_HASH="$(php -r 'echo password_hash(getenv("ADMIN_PASSWORD"), PASSWORD_BCRYPT);')"
log "syncing domain=${DOMAIN} host=${MAIL_HOSTNAME}"

SQL_FILE="$(mktemp)"
cat > "$SQL_FILE" <<'SQL'
-- bcrypt 哈希长度 60，旧版 varchar(32) 装不下（幂等迁移）
ALTER TABLE i_admin MODIFY `password` VARCHAR(255) NOT NULL COMMENT '密码';
ALTER TABLE i_users MODIFY `password` VARCHAR(255) NOT NULL;
INSERT INTO i_domains (name, active, ctime) VALUES ('__DOMAIN__', 1, NOW())
    ON DUPLICATE KEY UPDATE active = 1;
UPDATE i_mail_config SET value = '__MAIL_HOSTNAME__' WHERE name = 'imap';
UPDATE i_mail_config SET value = '__MAIL_HOSTNAME__' WHERE name = 'smtp';
UPDATE i_mail_config SET value = '__DOMAIN__' WHERE name = 'mydomain';
UPDATE i_mail_config SET value = '__MAIL_HOSTNAME__' WHERE name = 'myhostname';
-- 只在仍是安装默认密码时写入 .env 中的密码，避免覆盖后台已修改的密码
UPDATE i_admin SET password = '__ADMIN_HASH__'
    WHERE username = 'admin'
      AND (password = '' OR password = '3bb3733de472b226208307ec1e689347');
UPDATE i_admin SET active = 1, is_webmail = 1 WHERE username = 'admin';
SQL
sed -i -e "s|__DOMAIN__|${DOMAIN}|g" \
       -e "s|__MAIL_HOSTNAME__|${MAIL_HOSTNAME}|g" \
       -e "s|__ADMIN_HASH__|${ADMIN_HASH}|g" "$SQL_FILE"
"${MYSQL[@]}" < "$SQL_FILE"
rm -f "$SQL_FILE"

# ---------- TLS 证书（没有 Let's Encrypt 证书时先用自签） ----------
if [ ! -s /ewomail/ssl/fullchain.pem ] || [ ! -s /ewomail/ssl/privkey.pem ]; then
    log "generating self-signed certificate"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/CN=${MAIL_HOSTNAME}" \
        -addext "subjectAltName=DNS:${MAIL_HOSTNAME},DNS:${DOMAIN}" \
        -keyout /ewomail/ssl/privkey.pem -out /ewomail/ssl/fullchain.pem >/dev/null 2>&1
fi
chown root:root /ewomail/ssl/*.pem
chmod 644 /ewomail/ssl/fullchain.pem
chmod 640 /ewomail/ssl/privkey.pem

# ---------- Postfix ----------
log "rendering postfix configuration"
install -d -m 0755 /etc/postfix/mysql

cat > /etc/postfix/mysql/mysql-mailbox-domains.cf <<EOF
user = ${DB_USER}
password = ${DB_PASSWORD}
hosts = ${DB_HOST}
dbname = ${DB_NAME}
query = SELECT name FROM i_domains WHERE name='%s' AND active=1
EOF

cat > /etc/postfix/mysql/mysql-mailbox-maps.cf <<EOF
user = ${DB_USER}
password = ${DB_PASSWORD}
hosts = ${DB_HOST}
dbname = ${DB_NAME}
query = SELECT email FROM i_users WHERE email='%s' AND active=1
EOF

cat > /etc/postfix/mysql/mysql-alias-maps.cf <<EOF
user = ${DB_USER}
password = ${DB_PASSWORD}
hosts = ${DB_HOST}
dbname = ${DB_NAME}
query = SELECT destination FROM i_aliases WHERE source='%s'
EOF

cat > /etc/postfix/mysql/mysql-sender-login-maps.cf <<EOF
user = ${DB_USER}
password = ${DB_PASSWORD}
hosts = ${DB_HOST}
dbname = ${DB_NAME}
query = SELECT email FROM i_users WHERE email='%s' AND active=1
EOF

cat > /etc/postfix/mysql/mysql_bcc_user.cf <<EOF
user = ${DB_USER}
password = ${DB_PASSWORD}
hosts = ${DB_HOST}
dbname = ${DB_NAME}
query = SELECT to_email FROM i_bcc_user WHERE source='%s'
EOF

chmod 640 /etc/postfix/mysql/*.cf
chown root:postfix /etc/postfix/mysql/*.cf

postconf -e "myhostname = ${MAIL_HOSTNAME}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e "myorigin = \$myhostname"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
postconf -e "mynetworks = 127.0.0.0/8"
postconf -e "biff = no"
postconf -e "append_dot_mydomain = no"
postconf -e "compatibility_level = 3.6"
postconf -e "smtpd_banner = \$myhostname ESMTP"
postconf -e "smtpd_helo_required = yes"
postconf -e "disable_vrfy_command = yes"
postconf -e "message_size_limit = 52428800"
postconf -e "mailbox_size_limit = 0"
postconf -e "recipient_delimiter = +"

# TLS：仅允许 TLS1.2+，且认证必须走加密通道
postconf -e "smtpd_tls_cert_file = /ewomail/ssl/fullchain.pem"
postconf -e "smtpd_tls_key_file = /ewomail/ssl/privkey.pem"
postconf -e "smtpd_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtpd_tls_auth_only = yes"
postconf -e "smtpd_tls_protocols = >=TLSv1.2"
postconf -e "smtpd_tls_mandatory_protocols = >=TLSv1.2"
postconf -e "smtp_tls_security_level = may"
postconf -e "smtp_tls_protocols = >=TLSv1.2"
postconf -e "smtp_tls_mandatory_protocols = >=TLSv1.2"
postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
postconf -e "smtpd_tls_received_header = yes"
postconf -e "smtpd_tls_loglevel = 1"

# Dovecot SASL
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_sasl_security_options = noanonymous"
postconf -e "smtpd_sasl_tls_security_options = noanonymous"
postconf -e "broken_sasl_auth_clients = yes"

# 虚拟域 / 邮箱
postconf -e "virtual_mailbox_domains = mysql:/etc/postfix/mysql/mysql-mailbox-domains.cf"
postconf -e "virtual_mailbox_maps = mysql:/etc/postfix/mysql/mysql-mailbox-maps.cf"
postconf -e "virtual_alias_maps = mysql:/etc/postfix/mysql/mysql-alias-maps.cf"
postconf -e "recipient_bcc_maps = mysql:/etc/postfix/mysql/mysql_bcc_user.cf"
postconf -e "smtpd_sender_login_maps = mysql:/etc/postfix/mysql/mysql-sender-login-maps.cf"
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
postconf -e "smtpd_reject_unlisted_sender = yes"

# 反垃圾/反病毒
postconf -e "content_filter = smtp-amavis:[127.0.0.1]:10024"
postconf -e "smtpd_sender_restrictions = permit_mynetworks, reject_sender_login_mismatch, permit_sasl_authenticated"
postconf -e "smtpd_recipient_restrictions = reject_unknown_sender_domain, reject_sender_login_mismatch, permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination, reject_unknown_recipient_domain, check_policy_service unix:private/policy-spf"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"

# 队列寿命：临时退信保留 3 天（上游 300s 会直接丢信）
postconf -e "queue_run_delay = 60s"
postconf -e "minimal_backoff_time = 300s"
postconf -e "maximal_backoff_time = 1h"
postconf -e "maximal_queue_lifetime = 3d"
postconf -e "bounce_queue_lifetime = 3d"

# 连接/发信频率限制，降低账号被盗后的群发风险
postconf -e "smtpd_client_connection_count_limit = 20"
postconf -e "smtpd_client_connection_rate_limit = 30"
postconf -e "smtpd_client_message_rate_limit = 100"
postconf -e "smtpd_client_recipient_rate_limit = 200"
postconf -e "smtpd_client_event_limit_exceptions = \$mynetworks"
postconf -e "smtpd_error_sleep_time = 1s"

# ---------- Dovecot ----------
log "rendering dovecot sql configuration"
cat > /etc/dovecot/dovecot-sql.conf.ext <<EOF
driver = mysql
connect = host=${DB_HOST} dbname=${DB_NAME} user=${DB_USER} password=${DB_PASSWORD}
default_pass_scheme = MD5
password_query = SELECT u.email AS user, u.password FROM i_users u INNER JOIN i_domains d ON u.domain_id = d.id WHERE u.email = '%u' AND u.active = 1 AND d.active = 1
user_query = SELECT u.maildir AS home, 5000 AS uid, 5000 AS gid FROM i_users u WHERE u.email = '%u'
EOF
chown root:dovecot /etc/dovecot/dovecot-sql.conf.ext
chmod 640 /etc/dovecot/dovecot-sql.conf.ext

# ---------- Amavis ----------
log "rendering amavis configuration"
sed -e "s|__DOMAIN__|${DOMAIN}|g" -e "s|__MAIL_HOSTNAME__|${MAIL_HOSTNAME}|g" \
    /opt/ewomail/config/amavis/50-user.tmpl > /etc/amavis/conf.d/50-user

ln -sfn /ewomail/dkim/amavis-dkim.conf /etc/amavis/conf.d/60-ewomail-dkim
touch /ewomail/dkim/amavis-dkim.conf
# amavis 要求配置文件属主为 root，否则拒绝启动
chown root:amavis /ewomail/dkim/amavis-dkim.conf
chmod 640 /ewomail/dkim/amavis-dkim.conf

# ---------- 后台配置 ----------
CFG=/ewomail/www/ewomail-admin/core/config.php
sed -i "s/'dbhost' => '[^']*'/'dbhost' => '${DB_HOST}'/" "$CFG"
sed -i "s/'dbpw' => '[^']*'/'dbpw' => '${DB_PASSWORD}'/" "$CFG"
sed -i "s#'url'=>'[^']*'#'url'=>'https://${MAIL_HOSTNAME}:7010'#" "$CFG"
sed -i "s#'webmail_url'=>'[^']*'#'webmail_url'=>'https://${MAIL_HOSTNAME}:7000'#" "$CFG"

# ---------- DKIM 定时同步 ----------
echo "* * * * * root /opt/ewomail/bin/sync-dkim.sh >> /var/log/ewomail-dkim.log 2>&1" > /etc/cron.d/ewomail
chmod 644 /etc/cron.d/ewomail

export DOMAIN MAIL_HOSTNAME DB_HOST DB_NAME DB_USER DB_PASSWORD
/opt/ewomail/bin/sync-dkim.sh || log "initial dkim sync failed (will retry by cron)"

# ---------- SnappyMail 默认域名 ----------
SM_DATA=/ewomail/www/snappymail/data/_data_/_default_
install -d -o www-data -g www-data -m 0770 "$SM_DATA/domains" 2>/dev/null || true
if [ -d "$SM_DATA/domains" ]; then
    cat > "$SM_DATA/domains/template.ini" <<EOF
[imap]
host = "${MAIL_HOSTNAME}"
port = 993
type = 1
timeout = 300

[smtp]
host = "${MAIL_HOSTNAME}"
port = 465
type = 1
timeout = 300
EOF
    chown www-data:www-data "$SM_DATA/domains/template.ini"
fi
chown -R www-data:www-data /ewomail/www/snappymail/data 2>/dev/null || true

# ---------- 启动 ----------
log "starting services"
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai

# 阻止 apt 在构建阶段尝试启动服务
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d

RUN apt-get update && apt-get install -y --no-install-recommends \
        postfix postfix-mysql postfix-policyd-spf-python \
        dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-sieve \
        amavisd-new spamassassin spamc libmail-dkim-perl libmail-spf-perl \
        libnet-dns-perl \
        nginx php8.1-fpm php8.1-mysql php8.1-curl php8.1-mbstring \
        php8.1-xml php8.1-gd php8.1-zip php8.1-imap \
        supervisor rsyslog cron openssl gettext-base sudo ca-certificates \
        tzdata curl unzip mysql-client procps netcat-openbsd dnsutils \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/sbin/policy-rc.d

# SnappyMail（RainLoop 维护分支）
ARG SNAPPYMAIL_VERSION=2.38.2
RUN curl -fsSL -o /tmp/snappymail.zip \
        "https://github.com/the-djmaze/snappymail/releases/download/v${SNAPPYMAIL_VERSION}/snappymail-${SNAPPYMAIL_VERSION}.zip" \
    && mkdir -p /ewomail/www/snappymail \
    && unzip -q /tmp/snappymail.zip -d /ewomail/www/snappymail \
    && rm -f /tmp/snappymail.zip

COPY app/www/ewomail-admin /ewomail/www/ewomail-admin
COPY app/bin /opt/ewomail/bin
COPY app/config /opt/ewomail/config
COPY install.sql /opt/ewomail/install.sql
COPY app/entrypoint.sh /entrypoint.sh
COPY app/supervisord.conf /etc/supervisor/conf.d/ewomail.conf
COPY app/config/sudoers/ewomail /etc/sudoers.d/ewomail

# Nginx / Dovecot / Postfix / 日志
RUN rm -f /etc/nginx/sites-enabled/default /etc/rsyslog.d/50-default.conf \
    && sed -i -e 's/^!include auth-system.conf.ext/#&/' \
              -e 's/^!include auth-sql.conf.ext/#&/' \
              /etc/dovecot/conf.d/10-auth.conf \
    && cp /opt/ewomail/config/nginx/nginx.conf /etc/nginx/nginx.conf \
    && cp /opt/ewomail/config/nginx/vhost/*.conf /etc/nginx/conf.d/ \
    && cp /opt/ewomail/config/php/www.conf /etc/php/8.1/fpm/pool.d/www.conf \
    && cp /opt/ewomail/config/dovecot/99-ewomail.conf /etc/dovecot/conf.d/99-ewomail.conf \
    && cp /opt/ewomail/config/postfix/master.cf /etc/postfix/master.cf \
    && cp /opt/ewomail/config/rsyslog/ewomail.conf /etc/rsyslog.d/10-ewomail.conf

# 时区与日志目录
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
    && mkdir -p /var/log/nginx /var/log/supervisor /ewomail/mail /ewomail/dkim /ewomail/ssl

RUN chmod +x /opt/ewomail/bin/*.sh /entrypoint.sh \
    && chmod 440 /etc/sudoers.d/ewomail \
    && chown -R www-data:www-data /ewomail/www

VOLUME ["/ewomail/mail", "/ewomail/dkim", "/ewomail/ssl"]
EXPOSE 25 465 587 143 993 110 995 8000 8010 7000 7010

ENTRYPOINT ["/entrypoint.sh"]

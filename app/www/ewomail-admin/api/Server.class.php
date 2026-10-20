<?php
// +----------------------------------------------------------------------
// | EwoMail
// +----------------------------------------------------------------------
// | Copyright (c) 2016 http://ewomail.com All rights reserved.
// +----------------------------------------------------------------------
// | Licensed ( http://ewomail.com/license.html)
// +----------------------------------------------------------------------
// | Author: Jun <gyxuehu@163.com>
// +----------------------------------------------------------------------
/**
 * 服务器操作类
 *
 * 原版 EwoMail 依赖 SSH 远程执行脚本来生成 DKIM 密钥、重载 Postfix，
 * 但仓库中缺少该类，导致「域名管理 - DKIM」与「邮件系统设置」保存时报
 * fatal error。容器化部署中脚本与面板同机，直接通过 sudo 调用即可。
 */
class Server
{
    //允许调用的脚本白名单，避免任意命令执行
    private static $scripts = [
        'dkim'                => '/opt/ewomail/bin/dkim.sh',
        'update_mail_config'  => '/opt/ewomail/bin/update-mail-config.sh',
    ];

    /**
     * 执行一个服务器操作
     * @param string $user 保留参数（原版用于 SSH 用户，容器内固定 root）
     * @param string $action 操作名
     * @param array $data 参数
     * @return array
     */
    public function send($user, $action, $data = [])
    {
        switch ($action) {
            case 'dkim':
                $domain = isset($data['domain']) ? $data['domain'] : '';
                $op = isset($data['op']) ? $data['op'] : 'getkey';
                $out = $this->run('dkim', [$op, $domain]);
                $json = json_decode($out, true);
                if (!is_array($json)) {
                    $json = ['key' => '', 'testkeys' => 'script error'];
                }
                return ['data' => $json];

            case 'update_mail_config':
                $mydomain = isset($data['mydomain']) ? $data['mydomain'] : '';
                $myhostname = isset($data['myhostname']) ? $data['myhostname'] : '';
                $out = $this->run('update_mail_config', [$mydomain, $myhostname]);
                return ['data' => ['result' => $out]];
        }

        return ['data' => ['key' => '', 'testkeys' => 'unsupported action']];
    }

    /**
     * 通过 sudo 执行白名单脚本
     * @param string $action
     * @param array $args
     * @return string
     */
    private function run($action, array $args = [])
    {
        if (!isset(self::$scripts[$action])) {
            return '';
        }

        $cmd = 'sudo -n ' . escapeshellarg(self::$scripts[$action]);
        foreach ($args as $arg) {
            $cmd .= ' ' . escapeshellarg((string)$arg);
        }

        $output = [];
        $code = 0;
        @exec($cmd . ' 2>&1', $output, $code);
        return trim(implode("\n", $output));
    }
}

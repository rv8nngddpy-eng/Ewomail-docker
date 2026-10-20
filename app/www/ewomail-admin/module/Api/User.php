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
if(!defined("PATH")) exit;

/**
 * 修改账号密码
 */
Rout::get('update_password',function(){
    $email = iany('email');
    $password = iany('password');
    $new_password = iany('new_password');
    if(!$email){
        E::error('email domain parameter');
    }
    if(!$password){
        E::error('password domain parameter');
    }
    if(!$password){
        E::error('new_password domain parameter');
    }
    $emailSql = App::$db->quote($email);
    $row = App::$db->getOne("select * from ".table("users")." where email=$emailSql and active=1");
    if(!$row){
        E::error('Data does not exist');
    }

    if(!ew_verify_password($password,$row['password'])){
        E::error('The original password is not correct');
    }
    $newData = [
        'password'=>ew_hash_password($new_password)
    ];
    App::$db->update("users",$newData,"email=$emailSql");

    E::success('');
});
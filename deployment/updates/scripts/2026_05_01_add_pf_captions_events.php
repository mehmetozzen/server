<?php
/**
 * @package deployment
 */
require_once (__DIR__ . '/../../bootstrap.php');

$script = realpath(dirname(__FILE__) . '/../../../') . '/tests/standAloneClient/exec.php';
$pfCaptionsNotifications = realpath(dirname(__FILE__) . "/../../updates/scripts/xml/notifications/2026_05_01_add_kafka_captions_pf_notifications.xml");


if(!file_exists($pfCaptionsNotifications))
{
	KalturaLog::err("Missing update script file");
	return;
}

passthru("php $script $pfCaptionsNotifications");

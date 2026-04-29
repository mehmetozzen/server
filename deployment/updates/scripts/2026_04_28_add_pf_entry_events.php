<?php
/**
 * @package deployment
 */
require_once (__DIR__ . '/../../bootstrap.php');

$script = realpath(dirname(__FILE__) . '/../../../') . '/tests/standAloneClient/exec.php';
$pfEntryNotifications = realpath(dirname(__FILE__) . "/../../updates/scripts/xml/notifications/2026_04_28_add_kafka_entry_pf_notifications.xml");


if(!file_exists($pfEntryNotifications))
{
	KalturaLog::err("Missing update script file");
	return;
}

passthru("php $script $pfEntryNotifications");

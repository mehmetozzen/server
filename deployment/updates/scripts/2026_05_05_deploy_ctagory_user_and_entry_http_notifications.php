<?php
/**
 * @package deployment
 */
require_once (__DIR__ . '/../../bootstrap.php');

$script = realpath(dirname(__FILE__) . '/../../../') . '/tests/standAloneClient/exec.php';

$categoryEntryNotifications = realpath(dirname(__FILE__) . "/../../updates/scripts/xml/notifications/2026_05_05_http_category_entry_notifications.xml");
if(!file_exists($categoryEntryNotifications))
{
	KalturaLog::err("Missing category entry update script file");
	return;
}

passthru("php $script $categoryEntryNotifications");

$categoryUserNotifications = realpath(dirname(__FILE__) . "/../../updates/scripts/xml/notifications/2026_05_05_http_category_user_notifications.xml");
if(!file_exists($categoryUserNotifications))
{
	KalturaLog::err("Missing category user update script file");
	return;
}

passthru("php $script $categoryUserNotifications");


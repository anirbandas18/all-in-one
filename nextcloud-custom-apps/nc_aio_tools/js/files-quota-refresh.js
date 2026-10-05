/**
 * Refreshes the Files sidebar's "X MB of Y MB used" bar when an upload finishes.
 *
 * Stock Nextcloud 33 only re-fetches that figure on files:node:created / deleted /
 * moved / updated, and the uploader emits none of them, so after an upload the
 * bar stayed on the old value until a page reload. Deletes were already fine once
 * nginx stopped the browser caching the stats response (see the
 * /apps/files/api/v1/stats location in nginx-nextcloud.conf.template).
 *
 * Hooks two Files internals, both checked before use so this no-ops if a future
 * Nextcloud renames them: the global uploader's addNotifier() (called once per
 * finished upload), and the NavigationQuota component's own updateStorageStats(),
 * reached through the quota element's __vue__. Calling the component's method
 * rather than emitting a fake files:node:* event keeps other listeners of those
 * events from receiving a node that does not exist.
 *
 * WHY POLLING: the Files bundle creates window._nc_uploader and mounts the quota
 * entry after this script runs. Retries for up to 30s, then gives up.
 */
(function () {
	'use strict'

	if (!document.getElementById('app-navigation-vue')) {
		return
	}

	var tries = 0
	var timer = setInterval(function () {
		var uploader = window._nc_uploader
		if (uploader && typeof uploader.addNotifier === 'function') {
			clearInterval(timer)
			uploader.addNotifier(refresh)
		} else if (++tries > 60) {
			clearInterval(timer)
		}
	}, 500)

	function refresh() {
		var el = document.querySelector('.app-navigation-entry__settings-quota')
		var quota = el && el.__vue__
		while (quota && typeof quota.updateStorageStats !== 'function') {
			quota = quota.$parent
		}
		if (quota) {
			quota.updateStorageStats()
		}
	}
})()

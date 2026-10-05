<?php

declare(strict_types=1);

namespace OCA\NcAioTools\Listener;

use OCP\EventDispatcher\Event;
use OCP\EventDispatcher\IEventListener;
use OCP\Files\Events\Node\AbstractNodeEvent;
use OCP\Files\Events\Node\AbstractNodesEvent;
use OCP\Files\Node;
use OCP\ICache;
use OCP\ICacheFactory;

/**
 * @template-implements IEventListener<AbstractNodeEvent|AbstractNodesEvent>
 *
 * Keeps the Files sidebar's "X MB of Y MB used" figure current. Core's
 * OC_Helper::getStorageInfo() caches each user's usage in the local memcache for
 * 5 minutes, and the only thing that clears it is a quota change
 * (OC\User\User::setQuota). Uploads and deletes never do, so the stats endpoint
 * the sidebar polls kept answering with the old number for up to 5 minutes.
 *
 * Clears the same keys OC_Helper::clearStorageInfo() does, through the public
 * cache API rather than that private class: the 'storage_info' prefix and
 * "/<uid>/files::include|exclude", which is what getStorageInfo('/') builds
 * from the user's normalised root. Both the user the path belongs to and the
 * node's owner are cleared, so a write into a share updates the owner's quota too.
 */
class StorageInfoCacheListener implements IEventListener {
	private ICache $cache;

	public function __construct(ICacheFactory $cacheFactory) {
		$this->cache = $cacheFactory->createLocal('storage_info');
	}

	public function handle(Event $event): void {
		if ($event instanceof AbstractNodesEvent) {
			$this->clearFor($event->getSource());
			$this->clearFor($event->getTarget());
		} elseif ($event instanceof AbstractNodeEvent) {
			$this->clearFor($event->getNode());
		}
	}

	private function clearFor(Node $node): void {
		$uids = [];
		// Node paths are absolute: "/<uid>/files/...".
		$segments = explode('/', ltrim($node->getPath(), '/'), 3);
		if (($segments[1] ?? '') === 'files') {
			$uids[] = $segments[0];
		}
		try {
			$owner = $node->getOwner();
			if ($owner !== null) {
				$uids[] = $owner->getUID();
			}
		} catch (\Throwable) {
			// A node deleted mid-request can fail to resolve its owner; the path
			// segment above already covers the common case.
		}

		foreach (array_unique($uids) as $uid) {
			$this->cache->remove('/' . $uid . '/files::include');
			$this->cache->remove('/' . $uid . '/files::exclude');
		}
	}
}

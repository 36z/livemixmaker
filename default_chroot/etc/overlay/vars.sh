#!/bin/sh

# the upper, writable tmpfs with changes is mounted here
RW_ROOT=/overlay/rw
# the original, lower, on-disk rootfs
RO_ROOT=/overlay/ro
# the maximum size of the overlay filesystem, as percent of VMem
TMPFS_SIZE="70%"
# sync these paths when /sbin/overlay-sync is run with 'sync' argument
DEFAULT_SYNC="/ /home"
# apply this filter when synchronizing
RSYNC_FILTER=/etc/overlay/rsync-filter
# save a log
RSYNC_LOG="$RO_ROOT/var/log/overlay-sync.log"
# only one instance of overlay-sync at a time
LOCKFILE=/var/lock/overlay-sync.lock

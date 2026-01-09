#!/bin/bash

# If incus is installed that is priority, because Incus install is deliberate, while LXD often gets installed as agressive Ubuntu marketing.
if [[ -x /usr/bin/incus ]]; then
	echo "Incus detected" >&2
	TOOL=incus
	TOOLADMIN="incus admin"
	TOOLGROUP="incus-admin"
	LOCALDOMAIN=incus
elif [[ -x /snap/bin/lxc || -x /usr/sbin/lxc ]]; then
	echo "LXD detected" >&2
	TOOL=lxc
	TOOLADMIN=lxd
	TOOLGROUP=lxd
	LOCALDOMAIN=lxd
else
	echo "Neither lxc or incus is available!" >&2
	exit 1
fi

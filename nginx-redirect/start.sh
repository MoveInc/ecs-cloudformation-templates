#!/usr/bin/env sh

set -e
set -x

if [ "${REDIRECT_URL}" == "" ] ; then
	echo "Error: REDIRECT_URL environment variable is not set."
	exit 1
fi

sed -i "s|__REDIRECT_URL__|${REDIRECT_URL}|" /etc/nginx/conf.d/default.conf
exec nginx -g 'daemon off;'

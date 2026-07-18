#!/bin/sh

generate_splash_sequence() {
    authtarget="/opennds_auth/"
    sed -e "s|\$authtarget|$authtarget|g" -e "s|\$tok|$tok|g" /etc/opennds/htdocs/splash.html
}

. /usr/lib/opennds/libopennds.sh

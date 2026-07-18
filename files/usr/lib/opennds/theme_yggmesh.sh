#!/bin/sh

# Override the default header/footer so libopennds.sh does not
# prepend its own <html> document before ours (our splash.html
# is a full standalone document).
header() {
    :
}

footer() {
    exit 0
}

generate_splash_sequence() {
    authtarget="/opennds_preauth/"
    sed -e "s|\$authtarget|$authtarget|g" -e "s|\$fas|$fas|g" /etc/opennds/htdocs/splash.html
    footer
}

. /usr/lib/opennds/libopennds.sh

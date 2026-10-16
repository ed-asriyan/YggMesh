#!/bin/sh
# YggMesh ThemeSpec for openNDS (login_option_enabled=3), sourced by libopennds.sh.
# Serves /etc/opennds/htdocs/splash.html; its "Connect" form sends landing=yes,
# which libopennds.sh routes to landing_page() to authenticate the client.

title="theme_yggmesh"

log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - action: $1" >> /var/log/yggmesh-analytics.log
}

# splash.html is a complete HTML document: no shared header/footer markup
header() {
    :
}

footer() {
    exit 0
}

generate_splash_sequence() {
    # Funnel event beacon from splash.html (?custom=<event>), no page in reply
    if [ -n "$custom" ]; then
        log_action "$custom"
        footer
    fi

    log_action "splash_opened"
    sed -e "s|\$authtarget|/opennds_preauth/|g" -e "s|\$fas|$fas|g" /etc/opennds/htdocs/splash.html
    footer
}

landing_page() {
    configure_log_location
    . "$mountpoint/ndscids/ndsinfo"
    auth_log
    log_action "connect_clicked"

    echo "<!DOCTYPE html>
<html>
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
<title>Connected</title>
</head>
<body style=\"font-family:sans-serif;text-align:center;padding:20vh 1rem;\">
<h2>You are connected</h2>
<p><a href=\"https://yggmesh.com?utm_source=captive_portal&amp;utm_medium=wifi&amp;utm_campaign=yggmesh_router\">Continue to YggMesh</a></p>
</body>
</html>"
    footer
}

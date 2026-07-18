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

# Override openNDS's default landing page renderer after auth
landing_page() {
    originurl=$(printf "${originurl//%/\\x}")
    gatewayurl=$(printf "${gatewayurl//%/\\x}")
    configure_log_location
    . "$mountpoint/ndscids/ndsinfo"

    # Actually authenticate the user in openNDS core
    auth_log

    # Send a clean success response for the form submission
    # (Captive Network Assistants usually close themselves as soon as internet appears,
    # but if they don't, we show a nice message and redirect to the project repo).
    echo "<!DOCTYPE html><html>"
    echo "<head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">"
    echo "<title>Connected</title>"
    echo "<style>body{font-family:sans-serif;background:#000;color:#fff;text-align:center;padding:20vh 1rem;}</style>"
    echo "<meta http-equiv=\"refresh\" content=\"1;url=https://yggmesh.com?utm_source=captive_portal&amp;utm_medium=wifi&amp;utm_campaign=yggmesh_router\">"
    echo "</head><body>"
    echo "<h2>🌐 Connection successful!</h2>"
    echo "<p style=\"color:#aaa;\">You are now online. Redirecting...</p>"
    echo "</body></html>"
    footer
}

generate_splash_sequence() {
    authtarget="/opennds_preauth/"
    sed -e "s|\$authtarget|$authtarget|g" -e "s|\$fas|$fas|g" /etc/opennds/htdocs/splash.html
    footer
}

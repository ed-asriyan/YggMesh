# shellcheck shell=sh disable=SC3043
# YggMesh — helpers for Yggdrasil-ng, sourced by the YggMesh scripts.
#
# Keys: a private key is 128 hex digits, the Ed25519 seed followed by the
# public key, so the public key is its last 64 digits. Nodes and exits are
# known by their public keys: the clearnet (Crypto-Key Routing) maps IPv4
# subnets to them.

YGG_CTL="tcp://127.0.0.1:9001"   # the admin socket, see /etc/init.d/yggdrasil
YGG_DEV="yggdrasil"              # the TUN device
YGG_CONF="/var/etc/yggdrasil.toml"

# Runs the control command $@ against the running daemon, JSON output
ygg_ctl() {
    yggdrasil -e "$YGG_CTL" -j "$@"
}

# Returns 0 if $1 is a public key: 64 hex digits
is_pubkey() {
    case "$1" in
        *[!0-9a-fA-F]*|'') return 1 ;;
    esac
    [ "${#1}" -eq 64 ]
}

# Prints the public key of private key $1, in lower case
pubkey_of() {
    echo "${1#????????????????????????????????????????????????????????????????}" | tr 'A-F' 'a-f'
}

# Prints a new private key
new_private_key() {
    yggdrasil --genconf 2>/dev/null | sed -n 's/^private_key = "\([0-9a-f]*\)"$/\1/p'
}

# Prints the Yggdrasil address (200::/8) of public key $1, as yggdrasil
# derives it: the key is inverted, the number of its leading one bits is the
# second byte, the bits after the first zero bit are the rest.
key_address() {
    echo "$1" | awk '
        {
            hx = "0123456789abcdef"
            k = tolower($0)
            bits = ""
            for (i = 1; i <= 64; i++) {
                v = 15 - (index(hx, substr(k, i, 1)) - 1)
                for (b = 8; b >= 1; b = int(b / 2)) {
                    bits = bits (v >= b ? 1 : 0)
                    if (v >= b) v -= b
                }
            }
            ones = 0
            while (substr(bits, ones + 1, 1) == "1") ones++
            rest = substr(bits, ones + 2)
            s = sprintf("%x", 512 + ones)
            for (i = 0; i < 7; i++) {
                v = 0
                for (j = 1; j <= 16; j++) v = v * 2 + substr(rest, i * 16 + j, 1)
                s = s sprintf(":%x", v)
            }
            print s
        }'
}

# Prints the clearnet IPv4 address of public key $1: 100.64.0.0/10 (CGNAT)
# plus the last 22 bits of the key. The node and every exit derive it from
# the key alone, nothing has to be exchanged. The last bits, not the first:
# vanity keys share their leading bits. Two nodes may get the same address,
# an exit refuses such a pair (YggMesh-exit-node).
key_ipv4() {
    local n
    n=$(printf '%d' "0x$(echo "$1" | cut -c59-64)")
    n=$((n & 0x3fffff))
    echo "100.$((64 + (n >> 16))).$(((n >> 8) & 255)).$((n & 255))"
}

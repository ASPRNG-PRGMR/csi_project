#!/usr/bin/env bash
#
# pi_usb_link.sh — bring up the USB-ethernet-gadget management link to the CSI Pi.
#
# Run it bare, from anywhere, on the laptop (NOT on the Pi):
#
#     ./pi_usb_link.sh            Configure + bring up + verify the link
#     ./pi_usb_link.sh status     Read-only check, changes nothing
#
# No arguments, no prompts. Everything it needs is hardcoded below.
#
# Why this script exists: the Pi side already works out of the box
# (dtoverlay=dwc2,dr_mode=peripheral + modules-load=dwc2,g_ether, and a
# NetworkManager profile on usb0 set to link-local). The laptop side is what
# breaks: NetworkManager grabs the gadget with ipv4.method=auto, hangs forever
# on DHCP that nothing answers, and never falls back — so the host ends up with
# no IPv4 on the link and cannot reach the Pi's link-local address at all.
#
# This fixes that once, persistently, and verifies it end to end.

set -uo pipefail

# ---------------------------------------------------------------- settings ---

PI_HOST="raspberry.local"        # mDNS name. NOT raspberrypi.local — that does not resolve.
PI_USER="pios"
PI_WIFI_IP="10.55.97.201"        # fallback path, only used for the hint at the end
SSH_KEY="$HOME/.ssh/id_pi_csi"

NM_PROFILE="pi-usb"
GADGET_DRIVERS="cdc_ether,cdc_ncm,rndis_host"
GADGET_USB_ID="2e8a:0013"        # Raspberry Pi Ltd. USB gadget

# ------------------------------------------------------------------ output ---

if [[ -t 1 ]]; then
    R=$'\e[0;31m'; G=$'\e[0;32m'; Y=$'\e[1;33m'; B=$'\e[0;34m'; Z=$'\e[0m'
else
    R=''; G=''; Y=''; B=''; Z=''
fi

info() { printf '%s[..]%s   %s\n'   "$B" "$Z" "$*"; }
ok()   { printf '%s[OK]%s   %s\n'   "$G" "$Z" "$*"; }
warn() { printf '%s[WARN]%s %s\n'   "$Y" "$Z" "$*"; }
die()  { printf '%s[FAIL]%s %s\n'   "$R" "$Z" "$*" >&2; exit 1; }

# ------------------------------------------------------------------- checks ---

need() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH. Install it and re-run."
}

# Find the host-side netdev the Pi's gadget shows up as.
#
# The interface name is NOT stable: it is derived from the USB topology
# (enp8s0f0u1, enp8s0f3u1u1, ...), so it changes when the cable moves to a
# different port or through a hub. Match on the driver instead, which doesn't.
find_gadget_iface() {
    local dev driver
    for dev in /sys/class/net/*; do
        [[ -e "$dev/device/driver" ]] || continue
        driver="$(basename "$(readlink -f "$dev/device/driver")")"
        case ",$GADGET_DRIVERS," in
            *",$driver,"*) basename "$dev"; return 0 ;;
        esac
    done
    return 1
}

# ------------------------------------------------------------------- status ---

show_status() {
    echo "=== pi_usb_link.sh status ==="
    echo

    info "USB gadget enumerated?"
    if lsusb 2>/dev/null | grep -q "$GADGET_USB_ID"; then
        ok "$(lsusb | grep "$GADGET_USB_ID")"
    else
        warn "No $GADGET_USB_ID on the USB bus — Pi not plugged in, not booted, or not in peripheral mode."
    fi
    echo

    info "Gadget network interface:"
    local iface
    if iface="$(find_gadget_iface)"; then
        ok "$iface"
        ip -brief addr show "$iface" | sed 's/^/        /'
    else
        warn "none found (drivers tried: $GADGET_DRIVERS)"
    fi
    echo

    info "NetworkManager:"
    nmcli device status 2>/dev/null | awk 'NR==1 || /ethernet/' | sed 's/^/        /'
    echo

    info "mDNS resolution of $PI_HOST:"
    local addr
    if addr="$(getent hosts "$PI_HOST" 2>/dev/null | awk '{print $1; exit}')" && [[ -n "$addr" ]]; then
        ok "$PI_HOST -> $addr"
    else
        warn "does not resolve (is avahi-daemon running on both ends?)"
    fi
    echo

    info "Default route (should stay on Wi-Fi, not the USB link):"
    ip route | grep '^default' | sed 's/^/        /' || warn "no default route"
    echo
    echo "=== end status ==="
}

# -------------------------------------------------------------------- setup ---

do_setup() {
    need nmcli
    need ip
    need lsusb

    # 1. Is the gadget even there?
    info "Looking for the Pi's USB gadget..."
    if ! lsusb 2>/dev/null | grep -q "$GADGET_USB_ID"; then
        warn "USB ID $GADGET_USB_ID not on the bus."
        echo
        echo "  Check, in order:"
        echo "    - USB-C cable goes to the Pi's power/OTG port and is a data cable"
        echo "    - the Pi is booted"
        echo "    - on the Pi, /boot/firmware/config.txt has, under [all]:"
        echo "          dtoverlay=dwc2,dr_mode=peripheral"
        echo "    - on the Pi, /boot/firmware/cmdline.txt contains:"
        echo "          modules-load=dwc2,g_ether"
        echo "    - on the Pi, 'cat /sys/class/udc/*/state' says 'configured'"
        die "Gadget not enumerated — nothing to configure yet."
    fi
    ok "$(lsusb | grep "$GADGET_USB_ID")"

    # 2. Which interface is it?
    local iface
    iface="$(find_gadget_iface)" \
        || die "Gadget is on the USB bus but no netdev bound to it (drivers: $GADGET_DRIVERS). Try: sudo modprobe cdc_ether"
    ok "Gadget interface: $iface"

    # 3. Create or fix the NetworkManager profile.
    #
    #    Bound by match.driver, with interface-name deliberately cleared, so a
    #    different USB port cannot orphan the profile the way a pinned
    #    interface-name does.
    local -a opts=(
        connection.interface-name ""
        match.driver "$GADGET_DRIVERS"
        connection.autoconnect yes
        connection.autoconnect-priority 10
        ipv4.method auto
        ipv4.link-local fallback
        ipv4.dhcp-timeout 15
        ipv4.never-default yes
        ipv6.method link-local
    )

    if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$NM_PROFILE"; then
        info "Updating existing '$NM_PROFILE' profile..."
        nmcli connection modify "$NM_PROFILE" "${opts[@]}" \
            || die "Could not modify '$NM_PROFILE'."
    else
        info "Creating '$NM_PROFILE' profile..."
        nmcli connection add type ethernet con-name "$NM_PROFILE" "${opts[@]}" \
            || die "Could not create '$NM_PROFILE'."
    fi
    ok "Profile '$NM_PROFILE' set: DHCP with link-local fallback, never-default, matched by driver"

    # 4. Bring it up on this interface.
    info "Activating '$NM_PROFILE' on $iface..."
    nmcli connection up "$NM_PROFILE" ifname "$iface" >/dev/null 2>&1 \
        || die "Activation failed. See: nmcli device status"

    # 5. Wait for an address. DHCP has to time out before IPv4LL kicks in,
    #    so allow a little more than ipv4.dhcp-timeout.
    info "Waiting for an IPv4 address on $iface..."
    local host_ip="" i
    for ((i = 0; i < 25; i++)); do
        host_ip="$(ip -4 -brief addr show "$iface" 2>/dev/null | awk '{print $3; exit}')"
        [[ -n "$host_ip" ]] && break
        sleep 1
    done
    [[ -n "$host_ip" ]] || die "No IPv4 on $iface after 25s. See: nmcli device status"
    ok "Host side: $host_ip"

    # 6. Find the Pi. Its link-local address is reassigned on every boot, so
    #    resolve the name rather than trusting any remembered address.
    info "Resolving $PI_HOST over mDNS..."
    local pi_ip=""
    for ((i = 0; i < 10; i++)); do
        pi_ip="$(getent hosts "$PI_HOST" 2>/dev/null | awk '{print $1; exit}')"
        [[ -n "$pi_ip" ]] && break
        sleep 1
    done
    if [[ -z "$pi_ip" ]]; then
        warn "$PI_HOST did not resolve."
        echo "        The link is up on the host side, but the Pi is not announcing itself."
        echo "        On the Pi:  systemctl is-active avahi-daemon"
        echo "        On here:    systemctl is-active avahi-daemon; getent hosts $PI_HOST"
        die "Pi not reachable by name."
    fi
    ok "Pi side: $pi_ip"

    # 7. Prove it actually carries traffic.
    info "Pinging the Pi..."
    ping -c 3 -W 2 -I "$iface" "$pi_ip" >/dev/null 2>&1 \
        && ok "Ping OK ($pi_ip via $iface)" \
        || die "Address resolved but the Pi does not answer ICMP on $iface."

    info "Checking SSH on port 22..."
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$pi_ip/22" 2>/dev/null; then
        ok "sshd is listening"
    else
        warn "port 22 closed — is sshd enabled on the Pi?"
    fi

    # 8. Confirm we did not hijack the default route.
    if ip route | grep '^default' | grep -q "$iface"; then
        warn "The USB link took the default route. It is management-only; expected ipv4.never-default=yes."
    else
        ok "Default route untouched (still $(ip route | awk '/^default/{print $5; exit}'))"
    fi

    echo
    ok "USB link is up."
    echo
    echo "  Connect with:   ssh ${PI_USER}@${PI_HOST}"
    if [[ -f "$SSH_KEY" ]]; then
        echo "  Key in place:   $SSH_KEY"
    else
        echo "  No key yet.     ssh-keygen -t ed25519 -f $SSH_KEY -N '' && \\"
        echo "                  ssh-copy-id -i ${SSH_KEY}.pub ${PI_USER}@${PI_HOST}"
    fi
    echo "  Fallback path:  ssh ${PI_USER}@${PI_WIFI_IP}  (Wi-Fi; do NOT use during captures)"
    echo
    echo "  Addresses are IPv4 link-local and change on every Pi reboot — always"
    echo "  use the name '${PI_HOST}', never a remembered address."
}

# --------------------------------------------------------------------- main ---

case "${1:-setup}" in
    setup)  do_setup ;;
    status) show_status ;;
    -h|--help|help)
        sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "Unknown command '${1}'. Use: $(basename "$0") [setup|status]"
        ;;
esac

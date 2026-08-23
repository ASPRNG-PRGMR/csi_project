#!/bin/bash
#
# csi_setup.sh — interactive Nexmon CSI runbook automation (RPi 4B / BCM43455C0)
#
# Usage:
#   ./csi_setup.sh start      Run the full startup sequence up through `unmanage`
#   ./csi_setup.sh capture    tcpdump on udp port 5500 (wlan0, fallback to any)
#   ./csi_setup.sh status     Print current CSI/wlan0/usb0 state, no changes made
#   ./csi_setup.sh restore    Restore normal Wi-Fi (Makefile.rpi restore-wifi)
#
# Assumes the one-time Nexmon build/install (ARMHF libs, Python 2.7, firmware
# build, nexutil, makecsiparams) has already been completed. This script only
# automates the repeatable every-boot procedure.

set -u

NEXMON_DIR="/home/pios/nexmon"
CSI_DIR="${NEXMON_DIR}/patches/bcm43455c0/7_45_189/nexmon_csi"
MAKECSIPARAMS_DIR="${CSI_DIR}/utils/makecsiparams"
MAKECSIPARAMS_BIN="${MAKECSIPARAMS_DIR}/makecsiparams"
IFACE="wlan0"
UDP_PORT=5500

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[FAIL]${NC} $*"; }
info()  { echo -e "${BLUE}[..]${NC}   $*"; }
die()   { err "$*"; exit 1; }

confirm() {
    # confirm "prompt text"
    local prompt="$1"
    local reply
    read -r -p "$(echo -e "${YELLOW}?${NC} ${prompt} [y/N]: ")" reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

need_root_hint() {
    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root — some commands below will use sudo individually."
    fi
}

ensure_radio_unblocked() {
    # Cheap and idempotent — always run before bringing wlan0 up. NetworkManager
    # has been observed to soft-block the radio after it stops managing an
    # interface, so this is run defensively even when nothing looks blocked.
    sudo rfkill unblock wifi 2>/dev/null
    sudo rfkill unblock all 2>/dev/null
}

# ---------------------------------------------------------------------------
# Verification steps (read-only, safe to call repeatedly)
# ---------------------------------------------------------------------------

check_pi_arch() {
    info "Checking hardware/architecture..."
    local arch
    arch="$(uname -m)"
    if [[ "$arch" != "aarch64" ]]; then
        warn "Architecture is '$arch', expected 'aarch64'. Continuing, but this doesn't match the known-good state."
    else
        ok "Architecture: $arch"
    fi
    if [[ -f /proc/device-tree/model ]]; then
        local model
        model="$(tr -d '\0' < /proc/device-tree/model)"
        echo "        Model: $model"
    fi
}

check_usb0() {
    info "Checking usb0 (management link)..."
    if ! ip addr show usb0 &>/dev/null; then
        die "usb0 not found. Do NOT proceed — you have no non-wlan0 management path. Fix USB Ethernet gadget mode first."
    fi
    local usb0_state
    usb0_state="$(ip addr show usb0 | grep -oP 'inet \K[\d.]+')"
    if [[ -z "$usb0_state" ]]; then
        warn "usb0 exists but has no IPv4 address yet. Confirm it's actually reachable before continuing."
    else
        ok "usb0 is up with IP $usb0_state"
    fi
}

check_nexmon_dir() {
    info "Checking Nexmon directory..."
    [[ -d "$NEXMON_DIR" ]] || die "Nexmon directory not found at $NEXMON_DIR"
    [[ -f "$NEXMON_DIR/setup_env.sh" ]] || die "setup_env.sh not found in $NEXMON_DIR"
    [[ -d "$CSI_DIR" ]] || die "nexmon_csi patch dir not found at $CSI_DIR"
    [[ -f "$CSI_DIR/Makefile.rpi" ]] || die "Makefile.rpi not found in $CSI_DIR"
    ok "Nexmon dir, setup_env.sh, and Makefile.rpi all present"
}

source_env() {
    info "Sourcing setup_env.sh..."
    pushd "$NEXMON_DIR" >/dev/null || die "Could not cd to $NEXMON_DIR"
    # shellcheck disable=SC1091
    source setup_env.sh
    popd >/dev/null
    ok "setup_env.sh sourced"
}

NEXMON_FW_PATH="/lib/firmware/nexmon/brcmfmac43455-sdio.bin"
EXPECTED_FW_VERSION="7.45.189"

select_firmware() {
    info "Selecting Nexmon firmware alternative..."

    if [[ ! -e "$NEXMON_FW_PATH" ]]; then
        die "Nexmon firmware not found at $NEXMON_FW_PATH — check the one-time Nexmon build/install."
    fi

    # Do NOT use --auto: on this system the stock Cypress build has a higher
    # alternatives priority (50) than the Nexmon build (30), so --auto always
    # picks stock and silently defeats the whole pipeline. Pin explicitly.
    sudo update-alternatives --set cyfmac43455-sdio.bin "$NEXMON_FW_PATH"

    local current
    current="$(update-alternatives --display cyfmac43455-sdio.bin | grep 'currently points to')"
    echo "        $current"

    if ! echo "$current" | grep -q "$NEXMON_FW_PATH"; then
        die "Firmware alternative did not pin to Nexmon build. Currently: $current"
    fi
    ok "Nexmon firmware alternative selected (pinned, not auto)"
}

verify_loaded_firmware() {
    info "Verifying loaded firmware version via dmesg..."
    local fw_line
    fw_line="$(dmesg -T | grep -a 'Firmware: BCM4345' | tail -n1)"
    if [[ -z "$fw_line" ]]; then
        warn "No 'Firmware: BCM4345...' line found in dmesg yet — driver may not have reloaded far enough. Check manually with: dmesg -T | grep 'Firmware: BCM4345'"
        return
    fi
    echo "        $fw_line"
    if echo "$fw_line" | grep -q "$EXPECTED_FW_VERSION"; then
        ok "Loaded firmware is $EXPECTED_FW_VERSION (Nexmon-patched)"
    else
        die "Loaded firmware does NOT match expected $EXPECTED_FW_VERSION. This is the stock/wrong firmware — nexutil's custom ioctls will hang or fail. Reboot after re-pinning the alternative, then retry: sudo reboot"
    fi
}

reload_driver() {
    info "Reloading brcmfmac_wcc driver..."
    # Clear the kernel ring buffer first so the firmware-version check below
    # can't match a stale line from an earlier boot/session. modprobe -r/-e
    # alone doesn't always force the SDIO card to re-fetch firmware (no bus
    # power-cycle) — if no fresh "Firmware: BCM4345" line appears after this,
    # that itself is meaningful and is treated as fail-fast below.
    sudo dmesg -C
    sudo modprobe -r brcmfmac_wcc 2>/dev/null
    sleep 1
    sudo modprobe brcmfmac_wcc
    sleep 2
    ok "Driver reloaded"
    verify_loaded_firmware
}

check_wlan0() {
    info "Checking for wlan0 interface..."
    if ! iw dev | grep -q "Interface ${IFACE}"; then
        die "Interface ${IFACE} not found in 'iw dev' output. Driver/firmware reload likely failed."
    fi
    ok "${IFACE} present"
}

nexutil_k() {
    nexutil -I"${IFACE}" -k 2>&1
}

nexutil_m() {
    nexutil -I"${IFACE}" -m 2>&1
}

show_chanspec() {
    info "Current chanspec:"
    local out
    out="$(nexutil_k)"
    echo "        $out"
    echo "$out"
}

show_monitor_state() {
    info "Current monitor/CSI mode:"
    local out
    out="$(nexutil_m)"
    echo "        $out"
    echo "$out"
}

# ---------------------------------------------------------------------------
# status command
# ---------------------------------------------------------------------------

cmd_status() {
    echo "=== csi_setup.sh status ==="
    check_pi_arch
    echo
    info "usb0:"
    ip addr show usb0 2>/dev/null | sed 's/^/        /' || warn "usb0 not present"
    echo
    info "wlan0:"
    ip link show "$IFACE" 2>/dev/null | sed 's/^/        /' || warn "${IFACE} not present"
    echo
    info "rfkill state:"
    rfkill list 2>/dev/null | sed 's/^/        /' || warn "rfkill not available"
    echo
    if command -v nexutil &>/dev/null; then
        show_chanspec
        show_monitor_state
    else
        warn "nexutil not found on PATH"
    fi
    echo
    info "Is wlan0 NetworkManager-managed?"
    if command -v nmcli &>/dev/null; then
        nmcli dev status | grep -E "DEVICE|${IFACE}" | sed 's/^/        /'
    else
        warn "nmcli not available"
    fi
    echo
    info "Listening for existing UDP :$UDP_PORT traffic would require 'capture' — not run automatically by 'status'."
    echo "=== end status ==="
}

# ---------------------------------------------------------------------------
# start command
# ---------------------------------------------------------------------------

cmd_start() {
    echo "=== csi_setup.sh start ==="
    need_root_hint

    check_pi_arch
    check_usb0
    check_nexmon_dir
    source_env
    select_firmware
    reload_driver
    check_wlan0

    echo
    show_chanspec

    echo
    read -r -p "$(echo -e "${YELLOW}?${NC} Transmitter's actual Wi-Fi channel (check AP/hotspot, don't assume): ")" TX_CHANNEL
    [[ -n "$TX_CHANNEL" ]] || die "No channel entered. Aborting."

    read -r -p "$(echo -e "${YELLOW}?${NC} Transmitter MAC address (optional, press enter to skip): ")" TX_MAC

    [[ -x "$MAKECSIPARAMS_BIN" ]] || die "makecsiparams binary not found/executable at $MAKECSIPARAMS_BIN"

    info "Generating CSI params for channel ${TX_CHANNEL}..."
    local CSI_PARAM_STRING
    if [[ -n "$TX_MAC" ]]; then
        CSI_PARAM_STRING="$("$MAKECSIPARAMS_BIN" -c "${TX_CHANNEL}/20" -C 1 -N 1 -m "$TX_MAC")"
    else
        CSI_PARAM_STRING="$("$MAKECSIPARAMS_BIN" -c "${TX_CHANNEL}/20" -C 1 -N 1)"
    fi

    [[ -n "$CSI_PARAM_STRING" ]] || die "makecsiparams returned no output. Check channel/MAC arguments."
    ok "Generated param string: $CSI_PARAM_STRING"

    info "Applying CSI configuration..."
    nexutil -I"${IFACE}" -s500 -b -l34 -v"${CSI_PARAM_STRING}"

    echo
    local post_apply
    post_apply="$(show_chanspec)"
    if ! echo "$post_apply" | grep -q "$TX_CHANNEL"; then
        warn "Applied chanspec does not obviously mention channel ${TX_CHANNEL} — double-check output above before proceeding."
        confirm "Continue anyway?" || die "Aborted by user after chanspec mismatch."
    else
        ok "Chanspec reflects requested channel"
    fi

    info "Enabling Nexmon CSI/monitor mode..."
    nexutil -I"${IFACE}" -m1
    echo
    local mon_state
    mon_state="$(show_monitor_state)"
    if ! echo "$mon_state" | grep -qE "1|on|enabled"; then
        warn "Monitor mode output doesn't clearly show enabled. Review above."
    fi

    echo
    warn "Next step hands ${IFACE} to Nexmon via 'unmanage'. If SSH is currently over ${IFACE} instead of usb0, you WILL lose this session."
    check_usb0
    ensure_radio_unblocked
    if ! confirm "usb0 confirmed above. Proceed with 'make -f Makefile.rpi unmanage'?"; then
        die "Aborted before unmanage. Wi-Fi/wlan0 left untouched by Nexmon at this point."
    fi

    pushd "$CSI_DIR" >/dev/null || die "Could not cd to $CSI_DIR"
    local unmanage_output
    unmanage_output="$(make -f Makefile.rpi unmanage 2>&1)"
    local unmanage_status=$?
    echo "$unmanage_output"
    popd >/dev/null

    if [[ $unmanage_status -ne 0 ]]; then
        # Known benign case: wlan0 was never associated to an AP (expected —
        # it's used for CSI, not networking), so the Makefile's leading
        # `nmcli device disconnect wlan0` errors with "not all devices
        # disconnected" / device not active, and make aborts before the
        # actual `managed no` step runs. Work around it directly.
        if echo "$unmanage_output" | grep -qiE "not all devices disconnected|is not active"; then
            warn "unmanage target failed at the nmcli-disconnect step because wlan0 was never associated to an AP (expected). Falling back to setting it unmanaged directly."
            sudo nmcli device set "$IFACE" managed no
            sleep 1
            ensure_radio_unblocked
            sudo ip link set "$IFACE" up
            sleep 1
            local mgmt_state
            mgmt_state="$(nmcli dev status | grep -E "^${IFACE}\s")"
            echo "        $mgmt_state"
            if echo "$mgmt_state" | grep -qi "unmanaged"; then
                ok "wlan0 confirmed unmanaged via fallback"
            else
                die "Fallback did not result in wlan0 being unmanaged. Current state: $mgmt_state"
            fi
        else
            die "make -f Makefile.rpi unmanage exited non-zero ($unmanage_status) for an unrecognized reason. Check output above."
        fi
    else
        ok "wlan0 handed to Nexmon"
    fi

    echo
    ok "Startup sequence complete."
    echo "        Next: start your transmitter (ESP32 / phone hotspot) on channel ${TX_CHANNEL},"
    echo "        then run: ./csi_setup.sh capture"
    echo "=== end start ==="
}

# ---------------------------------------------------------------------------
# capture command
# ---------------------------------------------------------------------------

cmd_capture() {
    echo "=== csi_setup.sh capture ==="
    info "Listening for CSI UDP traffic on port ${UDP_PORT}."
    info "Trying interface '${IFACE}' first; if nothing shows, Ctrl+C and re-run with ANY=1 ./csi_setup.sh capture"
    echo

    local target_iface="$IFACE"
    if [[ "${ANY:-0}" == "1" ]]; then
        target_iface="any"
        info "ANY=1 set — capturing on 'any' interface instead."
    fi

    if ! ip link show "$IFACE" &>/dev/null; then
        warn "${IFACE} not present — has 'start' been run yet?"
    elif ! ip link show "$IFACE" | grep -q "state UP"; then
        warn "${IFACE} exists but is administratively down — bringing it up."
        ensure_radio_unblocked
        sudo ip link set "$IFACE" up
        sleep 1
    fi

    sudo tcpdump -ni "$target_iface" udp port "$UDP_PORT"
    echo "=== end capture ==="
}

# ---------------------------------------------------------------------------
# restore command
# ---------------------------------------------------------------------------

cmd_restore() {
    echo "=== csi_setup.sh restore ==="
    check_nexmon_dir

    if ! confirm "This will run 'make -f Makefile.rpi restore-wifi' and return ${IFACE} to normal Wi-Fi. Continue?"; then
        die "Aborted by user."
    fi

    pushd "$CSI_DIR" >/dev/null || die "Could not cd to $CSI_DIR"
    if make -f Makefile.rpi restore-wifi; then
        popd >/dev/null
        ok "restore-wifi target completed"
    else
        popd >/dev/null
        warn "restore-wifi target failed or is unavailable — falling back to manual restore sequence"
        update-alternatives --auto cyfmac43455-sdio.bin
        sudo modprobe -r brcmfmac_wcc
        sudo modprobe brcmfmac_wcc
        ensure_radio_unblocked
        sudo ifconfig "$IFACE" up
        sudo nmcli dev set "$IFACE" managed yes
        sudo nmcli radio wifi on
        sudo nmcli dev connect "$IFACE"
        ok "Manual restore sequence completed"
    fi

    echo
    info "Post-restore state:"
    nmcli dev status | grep -E "DEVICE|${IFACE}" | sed 's/^/        /'
    echo "=== end restore ==="
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 {start|capture|status|restore}

  start     Full startup: verify env, select firmware, reload driver,
            set CSI params for a channel you specify, enable monitor mode,
            confirm usb0, then unmanage wlan0.
  capture   tcpdump on udp port ${UDP_PORT} (wlan0 by default; ANY=1 $0 capture for 'any').
  status    Read-only snapshot of usb0/wlan0/nexutil state. Makes no changes.
  restore   Run Makefile.rpi restore-wifi (or manual fallback) to return
            wlan0 to normal NetworkManager-managed Wi-Fi.
EOF
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        start)   cmd_start ;;
        capture) cmd_capture ;;
        status)  cmd_status ;;
        restore) cmd_restore ;;
        *)       usage; exit 1 ;;
    esac
}

main "$@"


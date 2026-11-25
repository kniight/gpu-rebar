#!/usr/bin/env bash
#
# gpu-rebar.sh - PCIe BAR resize (Resizable BAR) via sysfs
#
# Usage:
#   gpu-rebar.sh [-b BAR|auto] [-s SIZE|max] [-r] [-n] [DEVICE ...]
#
# Options:
#   -b BAR     BAR index (0-5) or "auto" (default): picks the resizable BAR
#              that supports the largest size (the VRAM aperture)
#   -s SIZE    new BAR size: "max" (default) = largest size supported by the
#              card; or e.g. 256M, 4G, 16G, 32G.
#              A plain number without suffix = sysfs exponent (size = 2^n MB,
#              e.g. 14 = 16G)
#   -r         rebind the previous driver after resizing
#   -n         dry-run, writes nothing, only prints what it would do
#   -h         help
#
# In "max" mode, if the largest size does not fit into the bridge window, the
# script automatically tries the next smaller supported size, down to the
# current size.
#
# DEVICE: PCI address, e.g. 0000:3b:00.0 (if omitted, the list below is used)
#
# Examples:
#   gpu-rebar.sh                                  # auto BAR, max size, both cards
#   gpu-rebar.sh -n                               # dry run
#   gpu-rebar.sh -s 8G -b 1 0000:3b:00.0 0000:af:00.0
#
set -u

# ---- Defaults (edit these for your machine) -------------------------------
DEFAULT_DEVICES=("0000:3b:00.0" "0000:af:00.0")
DEFAULT_BAR="auto"
DEFAULT_SIZE="max"
# ---------------------------------------------------------------------------

SYSFS_DEV=/sys/bus/pci/devices
SYSFS_DRV=/sys/bus/pci/drivers

log()  { printf '[%s] %s\n' "$1" "${*:2}"; }
info() { log INFO "$@"; }
warn() { log WARN "$@" >&2; }
err()  { log ERR  "$@" >&2; }

usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; }

# Size -> sysfs exponent (2^n MB). Prints to stdout, returns 1 on error.
size_to_exp() {
    local s=${1^^} n unit_mb exp=0
    if [[ $s =~ ^([0-9]+)([MG])$ ]]; then
        n=${BASH_REMATCH[1]}
        [[ ${BASH_REMATCH[2]} == G ]] && unit_mb=1024 || unit_mb=1
        n=$(( n * unit_mb ))
        (( n >= 1 )) || return 1
        (( (n & (n - 1)) == 0 )) || return 1   # must be a power of two
        while (( n > 1 )); do n=$(( n >> 1 )); exp=$(( exp + 1 )); done
        echo "$exp"
    elif [[ $s =~ ^[0-9]+$ ]]; then
        echo "$s"
    else
        return 1
    fi
}

# Human-readable size from bytes
human() {
    local b=$1
    if   (( b >= 1<<30 )); then echo "$(( b >> 30 )) GB"
    elif (( b >= 1<<20 )); then echo "$(( b >> 20 )) MB"
    elif (( b > 0 ));      then echo "${b} B"
    else echo "unassigned"; fi
}

# Device description: class, vendor, model and [vendor:device] ID.
# Uses lspci if available, otherwise falls back to sysfs IDs.
dev_desc() {
    local dev=$1 d="" ven="" did=""
    if command -v lspci >/dev/null 2>&1; then
        d=$(lspci -nn -s "$dev" 2>/dev/null | head -n1)
        d=${d#* }                      # strip the leading PCI address
        d=${d%% (rev *}                # strip the trailing "(rev xx)"
    fi
    if [[ -z $d ]]; then
        [[ -r $SYSFS_DEV/$dev/vendor ]] && ven=$(<"$SYSFS_DEV/$dev/vendor")
        [[ -r $SYSFS_DEV/$dev/device ]] && did=$(<"$SYSFS_DEV/$dev/device")
        if [[ -n $ven && -n $did ]]; then d="[${ven#0x}:${did#0x}]"; else d="unknown device"; fi
    fi
    echo "$d"
}

# Exponent -> bytes (2^n MB)
exp_to_bytes() { echo $(( (1 << $1) << 20 )); }

# Supported-size bitmask of a resourceN_resize file as a number
read_mask() {
    local v
    v=$(<"$1") || return 1
    echo $(( 16#${v#0x} ))
}

# Bitmask -> largest supported exponent (-1 if empty)
mask_max_exp() {
    local mask=$1 i max=-1
    for i in $(seq 0 31); do (( (mask >> i) & 1 )) && max=$i; done
    echo "$max"
}

# Bitmask -> supported sizes as text
mask_list() {
    local mask=$1 i out=""
    for i in $(seq 0 31); do
        (( (mask >> i) & 1 )) && out+="$(human "$(exp_to_bytes "$i")") "
    done
    echo "$out"
}

# Current BAR size in bytes, from the sysfs "resource" file
bar_size_bytes() {
    local dev=$1 bar=$2 start end flags
    read -r start end flags < <(sed -n "$(( bar + 1 ))p" "$SYSFS_DEV/$dev/resource")
    if [[ -z ${start:-} ]] || (( start == 0 && end == 0 )); then
        echo 0
    else
        echo $(( end - start + 1 ))
    fi
}

# Finds the resizable BAR of the device that supports the largest size.
# Prints the BAR index; returns 1 if there is no resizable BAR.
find_best_bar() {
    local dev=$1 b mask mx best=-1 best_exp=-1
    for b in 0 1 2 3 4 5; do
        [[ -e $SYSFS_DEV/$dev/resource${b}_resize ]] || continue
        mask=$(read_mask "$SYSFS_DEV/$dev/resource${b}_resize") || continue
        mx=$(mask_max_exp "$mask")
        if (( mx > best_exp )); then best_exp=$mx; best=$b; fi
    done
    (( best >= 0 )) || return 1
    echo "$best"
}

# Resize the BAR of one device.
#   $1 = PCI address
#   $2 = BAR index or "auto"
#   $3 = new exponent (2^n MB) or "max"
#   $4 = rebind (0/1), $5 = dry-run (0/1)
resize_gpu_bar() {
    local dev=$1 bar=$2 exp=$3 rebind=$4 dry=$5
    local devpath="$SYSFS_DEV/$dev" rfile drv="" cur mask target_bytes
    local use_max=0 i c ok=0 new
    local cur_drv="none" numa="?" iommu="none"
    local -a cands=()

    [[ -d $devpath ]] || { err "$dev: no such PCI device"; return 1; }
    info "=== $dev | $(dev_desc "$dev") ==="
    [[ -L $devpath/driver ]] && cur_drv=$(basename "$(readlink -f "$devpath/driver")")
    [[ -r $devpath/numa_node ]] && numa=$(<"$devpath/numa_node")
    [[ -L $devpath/iommu_group ]] && iommu=$(basename "$(readlink -f "$devpath/iommu_group")")
    info "$dev: driver: $cur_drv, NUMA node: $numa, IOMMU group: $iommu"

    # BAR selection
    if [[ $bar == auto ]]; then
        bar=$(find_best_bar "$dev") || { err "$dev: no Resizable BAR capable BAR found"; return 1; }
        info "$dev: automatically selected BAR: $bar"
    fi
    rfile="$devpath/resource${bar}_resize"
    if [[ ! -e $rfile ]]; then
        err "$dev: BAR$bar does not support Resizable BAR (no $(basename "$rfile"))"
        return 1
    fi

    mask=$(read_mask "$rfile") || { err "$dev: cannot read supported sizes"; return 1; }
    info "$dev: BAR$bar supported sizes: $(mask_list "$mask")"

    # Determine the target size
    if [[ $exp == max ]]; then
        use_max=1
        exp=$(mask_max_exp "$mask")
        (( exp >= 0 )) || { err "$dev: list of supported sizes is empty"; return 1; }
    elif (( ! ((mask >> exp) & 1) )); then
        err "$dev: requested size ($(human "$(exp_to_bytes "$exp")")) is not supported"
        return 1
    fi

    cur=$(bar_size_bytes "$dev" "$bar")
    target_bytes=$(exp_to_bytes "$exp")
    info "$dev: current size: $(human "$cur"), target: $(human "$target_bytes")"

    if (( cur == target_bytes || (use_max && cur > target_bytes) )); then
        info "$dev: already at the requested (or larger) size, nothing to do"
        return 0
    fi

    # Candidates: in max mode every supported size from the largest downward
    # that is larger than the current one; otherwise only the requested size
    if (( use_max )); then
        for (( i = exp; i >= 0; i-- )); do
            (( (mask >> i) & 1 )) || continue
            (( $(exp_to_bytes "$i") > cur )) && cands+=("$i")
        done
    else
        cands=("$exp")
    fi

    # Check for a bound driver, unbind if needed
    if [[ -L $devpath/driver ]]; then
        drv=$cur_drv
        info "$dev: driver bound: $drv -> unbinding"
        if (( dry )); then
            info "(dry-run) echo $dev > $SYSFS_DRV/$drv/unbind"
        elif ! echo "$dev" > "$devpath/driver/unbind" 2>/dev/null; then
            err "$dev: unbind failed (in use? stop the VM/service first)"
            return 1
        fi
    else
        info "$dev: no driver bound"
    fi

    # Resize (in max mode with fallback to smaller sizes)
    if (( dry )); then
        info "(dry-run) echo ${cands[0]} > $rfile"
        ok=1
    else
        for c in "${cands[@]}"; do
            if echo "$c" > "$rfile" 2>/dev/null; then ok=1; break; fi
            warn "$dev: $(human "$(exp_to_bytes "$c")") failed, trying the next smaller size"
        done
        if (( ok )); then
            new=$(bar_size_bytes "$dev" "$bar")
            info "$dev: new size: $(human "$new")"
        else
            err "$dev: resize failed (probably not enough room in the bridge window; try the 'pci=realloc' kernel parameter and enable 'Memory Mapped I/O Above 4GB' in the BIOS)"
        fi
    fi

    # Rebind the driver if requested
    if [[ -n $drv ]]; then
        if (( rebind )); then
            info "$dev: rebinding $drv"
            if (( dry )); then
                info "(dry-run) echo $dev > $SYSFS_DRV/$drv/bind"
            else
                echo "$dev" > "$SYSFS_DRV/$drv/bind" 2>/dev/null \
                    || warn "$dev: rebinding $drv failed"
            fi
        else
            info "$dev: driver ($drv) left unbound (use -r to rebind)"
        fi
    fi
    (( ok ))
}

main() {
    local bar=$DEFAULT_BAR size=$DEFAULT_SIZE rebind=0 dry=0 opt exp rc=0 dev
    local -a devices

    while getopts ":b:s:rnh" opt; do
        case $opt in
            b) bar=$OPTARG ;;
            s) size=$OPTARG ;;
            r) rebind=1 ;;
            n) dry=1 ;;
            h) usage; return 0 ;;
            :) err "Option -$OPTARG requires a value"; return 2 ;;
            *) err "Unknown option: -$OPTARG"; usage; return 2 ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    if (( $# > 0 )); then devices=("$@"); else devices=("${DEFAULT_DEVICES[@]}"); fi

    [[ $bar == auto || $bar =~ ^[0-5]$ ]] || { err "Invalid BAR: $bar (0-5 or auto)"; return 2; }
    if [[ ${size,,} == max ]]; then
        exp=max
    else
        exp=$(size_to_exp "$size") || { err "Invalid size: $size (examples: max, 256M, 4G, 16G)"; return 2; }
    fi
    (( EUID == 0 )) || { err "Must be run as root"; return 2; }

    for dev in "${devices[@]}"; do
        resize_gpu_bar "$dev" "$bar" "$exp" "$rebind" "$dry" || rc=1
    done
    return $rc
}

main "$@"

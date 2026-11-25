# gpu-rebar
A quick script for resizing BAR to the maximum available for linux and Proxmox via sysfs.

# BIG FAT Warning: 
The script was built with help of Claude AI. I have read through the code and everything makes sense. 
It works for me, it might for you too. Still, it may contain bugs!

# Usage:
gpu-rebar.sh [-b BAR|auto] [-s SIZE|max] [-r] [-n] [DEVICE ...]

# Options:
   -b BAR     BAR index (0-5) or "auto" (default): picks the resizable BAR
              that supports the largest size (the VRAM aperture)
   -s SIZE    new BAR size: "max" (default) = largest size supported by the
              card; or e.g. 256M, 4G, 16G, 32G.
              A plain number without suffix = sysfs exponent (size = 2^n MB,
              e.g. 14 = 16G)
   -r         rebind the previous driver after resizing
   -n         dry-run, writes nothing, only prints what it would do
   -h         help

In "max" mode, if the largest size does not fit into the bridge window, the script automatically tries the next smaller supported size, down to the
current size. 

# Examples:
   gpu-rebar.sh                                  # auto BAR, max size, both cards
   gpu-rebar.sh -n                               # dry run
   gpu-rebar.sh -s 8G -b 1 0000:3b:00.0 0000:af:00.0

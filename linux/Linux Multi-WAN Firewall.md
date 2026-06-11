# Linux Multi-WAN Firewall

> **nbux notes**  
> Technical things, boring logic, predictable failures.  
> Nothing But Unix — mostly by accident.

> **Anonymization note**  
> Some values have intentionally been replaced with `XXX`, `xxxx`, `<>`, or `<something-like-this>`.  
> This mostly concerns public IP addresses, prefixes, hostnames, secrets, provider-specific values and a few local details that do not need to become Internet folklore.  
> The nftables logic, chains, sets, meters, hooks, priorities and comments are otherwise kept close to the real configuration.

## Why this version exists

This is the more faithful version of the firewall article.

The previous write-up tried to reorganize the rules by packet path (`INPUT`, `FORWARD`, `OUTPUT`, `PREROUTING`, `POSTROUTING`). That is useful pedagogically, but it does not match the way this ruleset is actually maintained.

This version follows the real layout:

```text
main nft entry point
definitions
netdev
raw
mangle
custom multi-WAN policy
nat
filter
protect
dynamic set persistence helpers
boot/interface helpers
```

In other words: less textbook, more actual router. The packets approve. The blog editor is still recovering.

## Publication and sanitization note

This article intentionally avoids publishing public IPv4 and IPv6 literals.

The code blocks below are copied from the source files and sanitized so that globally routable IPv4/IPv6 literals are replaced by placeholders such as:

```text
<public-v4-addr-01>
<public-v4-prefix-02>
<public-v6-addr-01>
<public-v6-prefix-02>
<>
XXX
xxx
```

Private addresses, local roles, variables, interface groups, comments, nftables structure and operational logic are kept because they are the useful parts.

This is still not meant to be a copy-paste firewall for someone else. It is documentation of a design.

A firewall copied without understanding is just a very confident outage.

## Design overview

The system is a Linux router/firewall using:

- **nftables** as the firewall engine;
- **conntrack marks** to make multi-WAN decisions persistent per flow;
- **packet marks** for policy routing;
- **dynamic nftables sets** for DDoS, scan, brute-force and live-drop handling;
- **netdev ingress filtering** to drop known-bad or obviously broken packets early;
- **raw / mangle / nat / filter / protect** tables split by responsibility;
- **flowtable fastpath** for established forwarded TCP/UDP traffic;
- helper files to persist dynamic sets across reloads.

The mental model is:

```text
netdev  → drop obvious garbage as early as possible
raw     → very early local hygiene
mangle  → mark flows for multi-WAN routing
nat     → DNS policy, DNAT, SNAT, masquerade
filter  → normal policy enforcement
protect → dynamic abuse detection and early security layer
```

```
new flow
  │
  ├─ protect: scan / brute / DDoS / spoof checks
  ├─ mangle : ct mark / meta mark / multi-WAN
  ├─ nat    : DNAT / DNS policy / SNAT mapping
  └─ filter : zone policy

accepted + established TCP/UDP
  │
  └─ flow offload @fastpath
       later packets avoid most of the slow path
```

The order in the include file is not accidental. With nftables, hook priority is the contract. Comments are just the part written for humans.

```
                         Internet / Upstreams
            ┌──────────────────┬──────────────────┬──────────────────┐
            │                  │                  │                  │
          WAN1               WAN2               WAN3              VPN/Tunnel
      primary ISP        secondary ISP       backup/link       routed tunnel
            │                  │                  │                  │
            └──────────┬───────┴───────┬──────────┴───────┬──────────┘
                       │               │                  │
                       ▼               ▼                  ▼
              ┌────────────────────────────────────────────────┐
              │                Linux Router / Firewall         │
              │                                                │
              │  nftables                                      │
              │  ├─ netdev  : early ingress drop               │
              │  ├─ raw     : early hygiene / ether drop       │
              │  ├─ mangle  : conntrack marks / multi-WAN      │
              │  ├─ nat     : DNS policy / DNAT / masquerade   │
              │  ├─ filter  : zone policy / stateful firewall  │
              │  └─ protect : DDoS / scan / brute / live drop  │
              │                                                │
              │  ip rule + route tables                        │
              │  ├─ mark 0x100 → WAN1 table                    │
              │  ├─ mark 0x200 → WAN2 table                    │
              │  ├─ mark 0x300 → WAN3 table                    │
              │  └─ mark 0x400 → tunnel table                  │
              └───────────────────────┬────────────────────────┘
                                      │
                                      │ VLAN-aware bridge / trunks
                                      │
              ┌───────────────────────┴────────────────────────┐
              │                    LAN side                    │
              └───────┬──────────────┬──────────────┬──────────┘
                      │              │              │
                    VLAN 1         VLAN 40         VLAN 9
                     LAN            DOMO           GUEST
                trusted clients     IoT/HA       guest devices
                      │              │              │
                      │              │              │
                    VLAN 88       services       containers
                    MANAGE       DNS / MQTT      nspawn / apps
                infra/admin       monitoring      isolated roles
```


```
                   ┌──────── Internet / WANs ────────┐
                   │        WAN1 / WAN2 / WAN3        │
                   └───────────────┬──────────────────┘
                                   │
                            netdev ingress
                                   │
                         raw / protect / mangle
                                   │
                              nat / filter
                                   │
                       ┌───────────┴───────────┐
                       │ Linux router/firewall │
                       └───────────┬───────────┘
                                   │
                       VLAN-aware LAN fabric
                                   │
        ┌──────────────┬───────────┼───────────┬──────────────┐
        │              │           │           │              │
      LAN            DOMO        GUEST       MANAGE        SERVICES
 trusted             IoT       untrusted     infra        DNS/MQTT/etc.
```

### Packet Path

```
                         WAN ingress packet
                                │
                                ▼
                         ┌────────────┐
                         │  netdev    │
                         │ ingress    │
                         └─────┬──────┘
                               │
          early drop: fragments / bad TCP flags / known DDoS
                               │
                               ▼
                         ┌────────────┐
                         │    raw     │
                         │ prerouting │
                         └─────┬──────┘
                               │
          early hygiene / ether drop / interface sanity
                               │
                               ▼
                         ┌────────────┐
                         │  protect   │
                         │ prerouting │
                         └─────┬──────┘
                               │
        scan / brute / DDoS meters → dynamic sets → early drops
                               │
                               ▼
                         ┌────────────┐
                         │  mangle    │
                         │ marks      │
                         └─────┬──────┘
                               │
            ct mark ⇄ meta mark / multi-WAN classification
                               │
                               ▼
                         ┌────────────┐
                         │    nat     │
                         │ DNAT/DNS   │
                         └─────┬──────┘
                               │
            DNS redirection / service DNAT / policy NAT
                               │
                               ▼
                         ┌────────────┐
                         │  filter    │
                         │ policy     │
                         └─────┬──────┘
                               │
             stateful firewall / zone policy / fastpath
                               │
                               ▼
                         route / forward / local delivery
```

### Multi LAN / WAN

```
                              Linux Router
                         VLAN-aware bridge / L3 SVIs
                                      │
          ┌───────────────────────────┼───────────────────────────┐
          │                           │                           │
          ▼                           ▼                           ▼

┌──────────────────┐        ┌──────────────────┐        ┌──────────────────┐
│ VLAN 1 / LAN     │        │ VLAN 40 / DOMO   │        │ VLAN 9 / GUEST   │
│                  │        │                  │        │                  │
│ Trusted clients  │        │ Home Assistant   │        │ Guest Wi-Fi      │
│ Workstations     │        │ IPX800           │        │ Untrusted hosts  │
│ Phones           │        │ Zigbee/MQTT      │        │ Internet only    │
│ NAS access       │        │ IoT devices      │        │ DNS redirected   │
└────────┬─────────┘        └────────┬─────────┘        └────────┬─────────┘
         │                           │                           │
         │ allowed to selected       │ restricted access          │ WAN only
         │ services / WAN            │ to LAN/services            │ no LAN reach
         │                           │                           │
         └───────────────┬───────────┴───────────────┬───────────┘
                         │                           │
                         ▼                           ▼

              ┌──────────────────┐        ┌──────────────────┐
              │ VLAN 88 / MANAGE │        │ SERVICES / CT    │
              │                  │        │                  │
              │ switches         │        │ DNS              │
              │ APs              │        │ MQTT             │
              │ hypervisors      │        │ monitoring       │
              │ router admin     │        │ local apps       │
              └──────────────────┘        └──────────────────┘
```


## The important security idea

The protection logic is not “one big drop list”.

It is a feedback loop:

```text
observe suspicious new traffic
→ classify the behavior
→ insert source into a dynamic set
→ drop later packets earlier and cheaper
→ expire the entry after timeout
```

That is visible in the `protect` table through sets such as:

```text
SCAN4 / SCAN6
BRUTE4 / BRUTE6
DDOS4 / DDOS6
DDOSNET4 / DDOSNET6
BLACKLIST4 / BLACKLIST6
LIVEDROP4 / LIVEDROP6
TRUSTED4 / TRUSTED6
```

The result is not an IDS. It is a fast, kernel-native, low-drama abuse filter.

It does not identify malware families. It identifies annoying behavior and makes it go away. Sometimes that is enough. Sometimes that is exactly enough.

## Flowtable fastpath: making accepted traffic boring

The ruleset defines a `flowtable fastpath` in the forwarding path.

The key pattern is:

```nft
flowtable fastpath {
    hook ingress priority filter; devices = { $iface_offload };
    counter;
}

ct state established meta l4proto { tcp, udp } flow offload @fastpath counter
```

The important parts are:

### 1. Fastpath is not a bypass for new traffic

Only established TCP/UDP flows are offloaded.

That means the first packets still go through:

```text
conntrack
protect
scan/brute/ddos checks
multi-WAN marking
filter policy
NAT decisions
```

Only after the flow is accepted and established can later packets use the faster path.

That is the sane model:

```text
inspect the decision
fastpath the boring continuation
```

Not:

```text
YOLO packets into hardware/software offload and hope policy happened somewhere
```

Hope is not a firewall primitive.

```
                         First packets of a flow
                                  │
                                  ▼
                        full nftables path
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
        ▼                         ▼                         ▼
   protect checks           mangle marks              filter policy
 scan/brute/ddos           ct mark/meta mark          zone decision
        │                         │                         │
        └─────────────────────────┴─────────────────────────┘
                                  │
                                  ▼
                           flow accepted
                                  │
                                  ▼
                         conntrack established
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │ flow offload @fastpath  │
                    └────────────┬────────────┘
                                 │
                                 ▼
                  later TCP/UDP packets use faster path
```


### 2. It matters for multi-WAN

This firewall relies on connection marks:

```text
ct mark 0x100 → WAN1
ct mark 0x200 → WAN2
ct mark 0x300 → WAN3
ct mark 0x400 → WAN4 / tunnel path
```

```
                         New connection
                               │
                               ▼
                        ┌─────────────┐
                        │ nft mangle  │
                        │ PREROUTING  │
                        └──────┬──────┘
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                    │
          ▼                    ▼                    ▼
   match WAN1 policy    match WAN2 policy    match WAN3 policy
          │                    │                    │
          ▼                    ▼                    ▼
   ct mark 0x100        ct mark 0x200        ct mark 0x300
          │                    │                    │
          └────────────────────┼────────────────────┘
                               │
                               ▼
                   meta mark set from ct mark
                               │
                               ▼
                         Linux ip rules
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                    │
          ▼                    ▼                    ▼
   table WAN1           table WAN2           table WAN3
   gateway WAN1         gateway WAN2         gateway WAN3

```


The multi-WAN logic classifies the connection, stores the decision in `ct mark`, then copies it to `meta mark` so Linux policy routing can select the right routing table.

Fastpath is safe only once that flow identity is already known.

If the mark is not stable, a connection can start on one WAN and continue on another. TCP does not enjoy existential routing crises.

### 3. It matters for NAT

The NAT decision must already exist before offload:

```text
DNAT / SNAT / masquerade decision
→ conntrack NAT mapping
→ established flow
→ flow offload
```

That is especially relevant here because the NAT table is used for:

- WAN masquerading;
- tunnel masquerading;
- DNS redirection;
- router-local DNS redirection;
- hairpin cases.

Fastpath should accelerate the result, not skip the decision.

### 4. It matters for `protect`

Known bad or suspicious sources should be dropped before they can benefit from fastpath.

That is why the protection logic sits early and why known bad sources are checked in both `netdev` and `protect`.

The intended path is:

```text
WAN ingress
→ netdev known DDoS/fragment/TCP flag checks
→ protect dynamic scan/brute/ddos checks
→ filter allow decision
→ established flow
→ fastpath
```

Fastpath is not a VIP lane for attackers. It is a boring lane for already accepted flows.

```
                         WAN packet
                             │
                             ▼
                    ┌─────────────────┐
                    │ Already listed? │
                    └───────┬─────────┘
                            │
        ┌───────────────────┴───────────────────┐
        │                                       │
       yes                                      no
        │                                       │
        ▼                                       ▼
  drop early                         evaluate behavior
        │                                       │
        │                    ┌──────────────────┼──────────────────┐
        │                    │                  │                  │
        ▼                    ▼                  ▼                  ▼
    DDOS set             scan meter        brute meter       flood meter
 @DDOS4/@DDOS6        @SCAN4/@SCAN6    @BRUTE4/@BRUTE6   @DDOSNET4/6
                             │                  │                  │
                             └──────────┬───────┴──────────┬───────┘
                                        │                  │
                                        ▼                  ▼
                               update dynamic set     log/rate-limit
                                        │
                                        ▼
                                  drop / reject
```

### 5. Kernel / interface caveat

The config contains this note:

```text
since kernel 6.19.x flowtable (offloading) must contain physical interfaces
```

That is why `$iface_offload` is defined separately and includes the interfaces intended for flowtable offload.

Flowtables are sensitive to topology. Bridges, VLANs, physical ports and virtual interfaces can change what “offloadable” really means. When in doubt, test counters, traces and actual throughput.

Packets are honest. Diagrams sometimes embellish.

## How to read the rest of this article

Each section below follows one source file.

For each file:

1. I explain its role.
2. I highlight the important technical choices.
3. I include the sanitized code block.

The code blocks are intentionally large. This is not a minimalist blog post. It is firewall archaeology with comments.


## Main entry point

The main file flushes the current ruleset and includes all modules in a deterministic order.

That order is part of the design:

```text
define first
netdev early ingress
filter/nat/mangle/raw/protect modules
persisted dynamic sets
```

The dynamic set include files are loaded after the table definitions so runtime-learned entries can survive reloads.

### Source: `main.nft`

```nft
#!/usr/sbin/nft -f

#
# Filter nft.definition
#

# flush all rules
flush ruleset

# definition (which already include predefine.nft)
include "/etc/nft.d/define.inc"

# tables
include "/etc/nft.d/netdev.inc"
include "/etc/nft.d/filter.inc"
include "/etc/nft.d/dnat.inc"
include "/etc/nft.d/mangle.inc"
include "/etc/nft.d/raw.inc"

# protect
include "/etc/nft.d/protect.inc"
include "/etc/nft.d/set-inet-protect-DDOS4.inc"
include "/etc/nft.d/set-inet-protect-SCAN4.inc"
include "/etc/nft.d/set-inet-protect-BRUTE4.inc"
include "/etc/nft.d/set-inet-protect-LIVEDROP4.inc"
include "/etc/nft.d/set-inet-protect-BLACKLIST4.inc"
include "/etc/nft.d/set-inet-protect-DDOS6.inc"
include "/etc/nft.d/set-inet-protect-SCAN6.inc"
include "/etc/nft.d/set-inet-protect-BRUTE6.inc"
include "/etc/nft.d/set-inet-protect-LIVEDROP6.inc"
include "/etc/nft.d/set-inet-protect-BLACKLIST6.inc"
```


## Predefine file

This tiny file exists so generated or external variables can be loaded before the main definitions.

Small files like this are boring. Boring is good. Boring means fewer side effects.

### Source: `predefine.def`

```sh
#!/usr/bin/nft -f
# generated from /etc/nft.d/predefine.cfg ( /etc/nft.d/predefine.var)
```


## Runtime configuration file

This file is not an nftables table by itself. It carries operational parameters used by the firewall scripts: host identity, selected interface names, reload behavior, metrics path, set persistence configuration and operational toggles.

This is the line between firewall policy and firewall machinery.


## Definitions and variable model

This is the vocabulary of the firewall.

It defines interface groups, address groups, services, ports, trusted lists, martians, offload interfaces and higher-level policy variables.

The important design choice is that later rules mostly use roles:

```text
$iface_lan
$iface_wan
$iface_private
$addr_private
$port_svc_vpn
$port_scan_wan
$iface_offload
```

instead of hardcoding every interface or address everywhere.

That makes the actual rules readable and keeps topology changes mostly localized.

### Source: `define.inc`

```nft
#!/usr/sbin/nft -f

#
# lan networks
#
# 192.168.0.0/17 (192.168.0.0/24-192.168.127.0/24) fd11::/17 (fd11:0:0:0::/64-fd11:7fff:ffff:ffff::/64)
# manage        192.168.88.0/24         192.168.88.1-254        fd11:0:0:88::0/64       fd11:0:0:88::1-ffff
# guest         192.168.9.0/24          192.168.9.1-254         fd11:0:0:9::0/64        fd11:0:0:9::1-ffff
# domo          192.168.40.0/24         192.168.40.1-254        fd11:0:0:40::0/64       fd11:0:0:40::1-ffff
# services      192.168.42.0/25         192.168.42.1-126        fd11:0:0:42::0/120      fd11:0:0:42::1-fe
# noads         192.168.42.128/27       192.168.42.129-158      fd11:0:0:42::120/123    fd11:0:0:42::121-13e
# kids          192.168.42.160/27       192.168.42.161-190      fd11:0:0:42::160/123    fd11:0:0:42::161-17e
# unknown       192.168.42.192/27       192.168.42.193-222      fd11:0:0:42::200/123    fd11:0:0:42::201-21e
# reserved      192.168.42.224/27       192.168.42.225-254      fd11:0:0:42::240/123    fd11:0:0:42::241-25e
# vpn1 (ovpn)   192.168.43.0/24         192.168.43.1-254        fd11:0:0:43::0/64       fd11:0:0:43::1-ffff
# vpn2 (ovpn)   192.168.44.0/24         192.168.44.1-254        fd11:0:0:44::0/64       fd11:0:0:44::1-ffff
# vpn3 (wg)     192.168.47.0/24         192.168.47.1-254        fd11:0:0:47::0/64       fd11:0:0:47::1-ffff
#
# 192.168.128.0/17 (192.168.128.0/24-192.168.255.0/24) fd11:8000::/17 (fd11:8000::/64-fd11:ffff:ffff:ffff::/64)
# vpn4 (job/tunnel) 192.168.200.0/24        192.168.200.1-254       fd11:9000:0:200::0/64      fd11:9000:0:200::1-ffff


# version 20250701

# this file auto-generated from .def by firewall itself
include "/etc/nft.d/predefine.def"


#
# WAN
#

# ipv6 private prefixes
###define addr6_private_wan = { fd11:0:0:2::/64, fd11:0:0:4::/64, fd11:0:0:6::/64, fd11:9000:0:200::/64, $addr6_private_wan1_prefix }
define addr6_lan_ula_prefix = fd11:0:0:42::/64
define addr6_guest_ula_prefix = fd11:0:0:9::/64 
define addr6_manage_ula_prefix = fd11:0:0:88::/64 
define addr6_domo_ula_prefix = fd11:0:0:40::/64 

# wan interfaces
define iface_wan1 = wan1
#define iface_wan1 = orange1 # bridge
define iface_private_wan1 = wan1 # used to access ONT
define iface_wan2 = wan2
define iface_private_wan2 = wan2
define iface_wan3 = mlkw0
define iface_private_wan3 = mlkw0

# ipv4 wan ip
#define addr_wan1 = 192.168.2.254
define addr_wan2 = 192.168.6.254
define addr_wan1_ext = XXX20260608XXXXX20260608XXX
define addr_wan2_ext = { <public-v4-prefix-04>, <public-v4-prefix-05>, <public-v4-prefix-06> }
define addr_wan3 = 192.168.200.4

# trusted
define addr_evian = { <public-v4-addr-07> } 
define addr6_evian = { XXX20260608XXX:1bc:2b00::/56 }
define addr_job = { <public-v4-addr-08>, <public-v4-addr-09>, <public-v4-addr-10>, <public-v4-addr-11>, <public-v4-addr-12>, <public-v4-addr-13>, <public-v4-prefix-14>, <public-v4-prefix-15>, <public-v4-prefix-16>, <public-v4-prefix-17>, <public-v4-prefix-18> }
define addr6_job = { <public-v6-addr-05> }
define addr_opm = { <public-v4-prefix-19>, <public-v4-prefix-20>, <public-v4-prefix-04> }
define addr_mlkw = { <public-v4-addr-21> } 
define addr_trusted = { $addr_job, $addr_bouygtel, $addr_mlkw, $addr_evian }
define addr6_opm = { <public-v6-prefix-06>, <public-v6-prefix-07> }
define addr6_mlkw = { <public-v6-addr-08> }
define addr6_trusted = { $addr6_opm, $addr6_job, $addr6_mlkw, $addr6_evian } 

# wan ports (scan/brute defender)
define port_allow_wan = { <> }
define port_scan_wan = { <> }
define port_brute_wan = { <> }



#
# LAN
#

# lan
# WARNING : iface_lan and addr_lan MUST BE DEFINED IN <host>.nft FILE
# you can override it here (but not recommended)
# NOTE : since kernel 6.19.x flowtable (offloading) must contain physical interfaces
#
define iface_lan_phy = lan1 
define iface_lan_trunk = brlan1 

define iface_lan = lan 
define addr_lan = 192.168.42.0/24
define addr6_lan = { $addr6_lan_ula_prefix }
define bcast_lan = 192.168.42.255

define addr_lan_full = $addr_lan
define addr_lan_svc = 192.168.42.0/25
define addr_lan_noads = 192.168.42.128/27
define addr_lan_kids = 192.168.42.160/27
define addr_lan_unknown = 192.168.42.192/27
define addr_lan_reserved = 192.168.42.224/27

define addr6_lan_ula_full = $addr6_lan_ula_prefix
define addr6_lan_ula_svc = fd11:0:0:42::0/120
define addr6_lan_ula_noads = fd11:0:0:42::120/123
define addr6_lan_ula_kids = fd11:0:0:42::160/123
define addr6_lan_ula_unknown = fd11:0:0:42::200/123
define addr6_lan_ula_reserved = fd11:0:0:42::240/123

# guest
define iface_guest = guest
define addr_guest = 192.168.9.0/24
define addr6_guest = { fd11::/17, $addr6_guest_ula_prefix }
define bcast_guest = 192.168.9.255

# manage
define iface_manage = manage
define addr_manage = 192.168.88.0/24
define addr6_manage = fd11:0:0:88::/64
define bcast_manage = 192.168.88.255

# domo iot
define iface_domo = domo
define addr_domo = 192.168.40.0/24
define addr6_domo = fd11:0:0:40::/64
define bcast_domo = 192.168.40.255



#
# VPN
#

# vpn form border router (private wan)
define addr_vpn_prvwan = 192.168.57.0/24
define addr6_vpn_prvwan = fd11:0:0:57::/64

# openvpn
define iface_vpn_nbux_opn = { tun0, tun1 }
define addr_vpn_nbux_opn = { 192.168.43.0/24, 192.168.44.0/24 }
define addr6_vpn_nbux_opn = { fd11:0:0:43::/64, fd11:0:0:44::/64 }
define gw_vpn_nbux_opn = { 192.168.43.1, 192.168.44.1 }
define gw6_vpn_nbux_opn = { fd11:0:0:43::1, fd11:0:0:47::1 }

# wireguard
define iface_vpn_nbux_wg = nbux0 
define addr_vpn_nbux_wg = 192.168.47.0/24
define addr6_vpn_nbux_wg = fd11:0:0:47::/64
define gw_vpn_nbux_wg = 192.168.47.1
define gw6_vpn_nbux_wg = fd11:0:0:47::1

# use tunnel to output to internet via vpn interface (zero-trust or CGNAT bypass)
# NOTE: NAT from this interface must be SNAT (not masquerade) due to public endpoints
#define iface_tunnel = { job0, mlkw0 }
define iface_tunnel = { mlkw0 }
define addr_tunnel = <public-v4-prefix-22>
define addr6_tunnel = <public-v6-prefix-09> 
define snat_tunnel = <public-v4-addr-23>
define snat6_tunnel = <public-v6-addr-10>



#
# GLOBALS
#


# addresses
define addr_private_wan = { 192.168.2.0/24, 192.168.4.0/24, 192.168.6.0/24, 192.168.200.0/24, $addr_vpn_prvwan }
define addr6_private_wan = { fd11:0:0:2::/64, fd11:0:0:4::/64, fd11:0:0:6::/64, fd11:9000:0:200::/64, $addr6_vpn_prvwan }

#define addr_private = 192.168.0.0/16
define addr_private = 192.168.0.0/17
define addr6_private = { fd11::/17 }

# interfaces
define iface_private_wan = { $iface_private_wan1, $iface_private_wan2 }
define iface_wan = { $iface_wan1, $iface_wan2, $iface_wan3 }
define iface_private = { $iface_lan_trunk, $iface_lan, $iface_guest, $iface_manage, $iface_domo }

# vpn job
define iface_vpn_job = job0
define addr_vpn_job = 192.168.200.0/24
define addr6_vpn_job = fd11:9000:0:200::/64
define gw_vpn_job = 192.168.200.1
define gw6_vpn_job = fd11:9000:0:200::1

# vpn globals
define iface_vpn_nbux = { $iface_vpn_nbux_opn, $iface_vpn_nbux_wg }
define addr_vpn_nbux = { $addr_vpn_nbux_opn, $addr_vpn_nbux_wg, $addr_vpn_prvwan }
define gw_vpn_nbux = { $gw_vpn_nbux_opn, $gw_vpn_nbux_wg }
define addr6_vpn_nbux = { $addr6_vpn_nbux_opn, $addr6_vpn_nbux_wg, $addr6_vpn_prvwan }
define gw6_vpn_nbux = { $gw6_vpn_nbux_opn, $gw6_vpn_nbux_wg }




#
# SERVICES & HOSTS DEF
#

# external exposed lan hosts	 
define addr_svc_ssh = 192.168.42.254 # ssh
define addr6_svc_ssh = fd11:0:0:42::254 # ssh
define addr_svc_http = 192.168.42.254 # reverse-proxy
define addr6_svc_http = fd11:0:0:42::254  # reverse-proxy
define port_svc_ssh = 22
define port_svc_http = { 443, 444 }

# lan hosts definitions
define addr_svc_aurora = 192.168.42.53 
define addr6_svc_aurora = fd11:0:0:42::53
define addr_svc_aurora_vanisher = $addr_svc_aurora
define addr6_svc_aurora_vanisher = $addr6_svc_aurora
define port_svc_aurora_vanisher = { <> } # wg
define addr_svc_monit = 192.168.42.54
define addr6_svc_monit = fd11:0:0:42::54
define port_svc_monit = { <> } 

# DNS
define addr_svc_dns = 192.168.42.251
define addr6_svc_dns = fd11:0:0:42::251
define port_svc_dns = 53
define addr_svc_dns_cast = 192.168.42.251
define addr6_svc_dns_cast = fd11:0:0:42::251
define port_svc_dns_cast = 53
define addr_svc_dns_kids = 192.168.42.253
define addr6_svc_dns_kids = fd11:0:0:42::253
define port_svc_dns_kids = 54
define addr_svc_dns_noads = 192.168.42.252
define addr6_svc_dns_noads = fd11:0:0:42::252
define port_svc_dns_noads = 54
define addr_svc_dns_unknown = 192.168.42.253
define addr6_svc_dns_unknown = fd11:0:0:42::253
define port_svc_dns_unknown = 54
define addr_svc_dns_gw = 192.168.42.254
define addr6_svc_dns_gw = fd11:0:0:42::254
define port_svc_dns_gw = 54
define addr_svc_dns_guest = 192.168.9.251
define addr6_svc_dns_guest = fd11:0:0:9::251
define port_svc_dns_guest = 54

# VPN
define addr_svc_vpn = 192.168.42.242
define addr6_svc_vpn = fd11:0:0:42::242
define port_svc_vpn = { 1194,1195,9545 }



# various devices
define addr_dev_tv = { <> }  # tv media devices
define addr6_dev_tv = { <>}  # tv media devices
define ether_dev_kids = { <> } # kids devices
define addr_dev_cast = { <> } # cast devices
define addr6_dev_cast = { <> } # cast devices
define ether_dev_cast = {<> } # cast devices
define addr_dev_domo = { <> } # oit devices
define addr6_dev_domo = { <> } # oit devices



#
# SERVICES DEF
# mainly used by mwan

# vanisher svc
# pp_xxxx are updated from .def file
define iface_vanisher = { vanisher0 }

# wan specific svc
# pp_xxxx are updated from .def file
#define svc_wan1 = { $svc_orange, $addr_wan1_ext, $pp_ip }
#define svc_wan1 = { $addr_wan1_ext, $pp_ip }
#define svc_wan1 = { $addr_wan1_ext }
#define svc_wan2 = { $svc_bouygtel, $addr_wan2_ext }
#define svc_wan2 = { $addr_wan2_ext }
#define svc_wan3 = { $pp_svc }
#define svc6_wan1 = { $svc6_orange, $addr6_wan1_prefix }
#define svc6_wan1 = { $addr6_wan1_prefix }

# wan hash (persist hash src/dst/ip/port)
#define svc_hash_mwan1 = { $svc_csc }


#
# DO NOT MODIFY !!!
#

# wan martians (DO NOT MODIFY)
define addr_wan_martians = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/3, 255.255.255.255/32 }
define addr6_wan_martians = { ::/128, ::/96, ::1/128, ::ffff:0:0/96, 100::/64, 2001:10::/28, 2001:2::/48, 2001:db8::/32, 3ffe::/16, fec0::/10, fc00::/7 }


#
# FASTPATH OFFLOAD
# NOTE : since kernel 6.19.x flowtable (offloading) must contain physical interfaces
define iface_offload = { $iface_lan_phy, $iface_lan, $iface_guest, $iface_manage, $iface_domo, $iface_wan1, $iface_wan2, $iface_wan3 }
```


## netdev table: earliest ingress protection

The `netdev` table is the earliest protection layer.

It attaches directly to ingress on WAN-facing devices and drops traffic before it reaches the normal inet hooks.

This is where the firewall handles:

- IPv6 exceptions required before filtering;
- fragments;
- already-known DDoS sources;
- already-known DDoS networks;
- malformed TCP flag combinations;
- TCP destination port zero;
- rate-limited logging for early drops.

This is cheap rejection. Packets that are obviously broken or already listed should not be allowed to tour the rest of the kernel just for cultural reasons.

### Source: `netdev.inc`

```nft
#!/usr/sbin/nft -f

#
# Netdev NFT definition
#

table netdev filter {

	set DDOS4 {
		type ipv4_addr
		#flags interval, timeout
		flags timeout
		size 131072
		gc-interval 10m
		#auto-merge
	}

	set DDOS6 {
		type ipv6_addr
		#flags interval, timeout
		flags timeout
		size 131072
		gc-interval 10m
		#auto-merge
	}

	set DDOSNET4 {
		type ipv4_addr
		#flags interval, timeout
		flags timeout
		size 131072
		gc-interval 10m
		#auto-merge
	}

	set DDOSNET6 {
		type ipv6_addr
		#flags interval, timeout
		flags timeout
		size 131072
		gc-interval 10m
		#auto-merge
	}


	chain ingress {
		type filter hook ingress devices = { $iface_wan } priority -500; 

   		# ipv6 exceptions before protect
		ip6 saddr fe80::/10 udp sport { 546, 547 } udp dport { 546, 547 } counter accept comment "ingress6_DHCP6"
		ip6 saddr fe80::/10 ip6 nexthdr ipv6-icmp icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, mld-listener-reduction, mld-listener-query, mld-listener-report, mld2-listener-report, mld-listener-done } counter accept comment "ingress6_NDMLD"
    	ip6 nexthdr ipv6-icmp icmpv6 type packet-too-big counter accept comment "ingress6_PMTU"
		ip6 saddr fe80::/10 ip6 nexthdr ipv6-frag counter accept comment "ingress6_FRAG"
		ip6 daddr { <public-v6-prefix-16>, <public-v6-prefix-17> } counter accept comment "ingress6_MCAST"

		# FRAG
		# ipv6 frag protection could have issues with wireguard tunnel (for IPv6 over IPv6, use MTU=1400 or lower)
		ip6 nexthdr ipv6-frag counter jump FRAG comment "ingress6_FRAG_#protect"
		ip frag-off & 0x1fff != 0 counter jump FRAG comment "ingress4_FRAG_#protect"

		# DDOS
		(ip saddr & 255.255.255.0) @DDOSNET4 counter jump DDOS comment "ingress4_DDOSNET_WAN_#protect"
		ip saddr @DDOS4 counter jump DDOS comment "ingress4_DDOS_WAN_#protect"
		(ip6 saddr & <public-v6-addr-18>) @DDOSNET6 counter jump DDOS comment "ingress6_DDOSNET_WAN_#protect"
		ip6 saddr @DDOS6 counter jump DDOS comment "ingress6_DDOS_WAN_#protect"

		# stateless FLAGS
        meta l4proto tcp tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0 counter jump FLAG comment "ingress_NULL_#protect"
        meta l4proto tcp tcp flags & (fin|syn|rst|psh|ack|urg) == (fin|psh|urg) counter jump FLAG comment "ingress_XMAS_#protect"
        meta l4proto tcp tcp flags & (syn|fin) == (syn|fin) counter jump FLAG comment "ingress_SYNFIN_#protect"
        meta l4proto tcp tcp flags & (syn|rst) == (syn|rst) counter jump FLAG comment "ingress_SYNRST_#protect"
        meta l4proto tcp tcp dport 0 counter jump FLAG comment "ingress_TCP0_#protect"
	}


	# change prio/pcp/dscp for orange authentication
	# WARNING: these rules also need to be loaded BEFORE very first dhcp client requests !
	# use prio_orange_phy to apply on physical interface (parent of vlan 832 interface - wan1)
	# use prio_orange_vlan to apply on vlan interface (already in vlan 832 - orange1)
	# note1: it is recommended to use and apply params on physical interface (wan1)
	# note2: 'meta priority set 0:6' should NOT be required if phy version ('vlan pcp set 6' replace it) 
	#chain prio_orange_phy {
	#	icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } vlan pcp set 6 meta priority set 0:6 ip6 dscp set cs6 counter comment "prio_orange_ICMP6"
	#	udp dport 547 vlan pcp set 6 meta priority set 0:6 ip6 dscp set cs6 counter comment "prio_orange_DHCP6"
	#	udp dport 67 vlan pcp set 6 meta priority set 0:6 ip dscp set cs6 counter comment "prio_orange_DHCP4"
	#	vlan type arp vlan pcp set 6 counter comment "prio_orange_ARP"
	#}
	##chain prio_orange_vlan {
	#	#icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } meta priority set 0:6 ip6 dscp set cs6 counter comment "prio_orange_ICMP6"
	#	#udp dport 547 meta priority set 0:6 ip6 dscp set cs6 counter comment "prio_orange_DHCP6"
	#	#udp dport 67 meta priority set 0:6 ip dscp set cs6 counter comment "prio_orange_DHCP4"
	#	#ether type arp meta priority set 0:6 counter comment "prio_orange_ARP"
	#}

	# call here the right prio_orange version (vlan or phy)
	# change $iface_wan1 as required : 
	# devices = orange1 (iface_wan1) -> jump prio_orange
	# devices = wan1 (iface_private_wan1) -> vlan id 832 jump prio_orange
	# note1: it is always better to use physical interface instead of vlan interface, you should use : 'devices = wan1' + 'vlan id 832 jump prio_orange_phy'
	# note2: '^vlan id 832' is NOT mandatory in netdev (low level)
	#chain egress {
	#	type filter hook egress devices = $iface_private_wan1 priority filter; policy accept;
	#	#jump prio_orange_vlan comment "egress-prio_orange_vlan"
	#	vlan id 832 jump prio_orange_phy comment "egress-prio_orange_phy"
	#}

	chain FLAG {
		#log prefix "netfilter:netdev_FLAG" group 0
		limit rate 30/minute log prefix "netfilter:netdev_FLAG" group 0
		counter drop
	}

	chain FRAG {
		#log prefix "netfilter:netdev_FRAG" group 0
		limit rate 30/minute log prefix "netfilter:netdev_FRAG" group 0
		counter drop
	}

	chain DDOS {
		#log prefix "netfilter:netdev_DDOS" group 0
		limit rate 30/minute log prefix "netfilter:netdev_DDOS" group 0
		counter drop
	}

	chain DEBUG {
		log prefix "netfilter:netdev_DEBUG" group 0
		counter accept
	}

}
```


## raw table: very early inet hygiene

The `raw` table is used for very early inet prerouting decisions.

In this setup it is intentionally limited. It handles local bypasses, private interface allowance and the Ethernet drop set.

The `ETHERDROP` set is useful when a local MAC address must be muted without rewriting zone policy. This is operationally handy: sets are easier to modify than rule logic.

### Source: `raw.inc`

```nft
#!/usr/sbin/nft -f

#
# Filter NFT definition
#


table inet raw {

	set ETHERDROP {
		type ether_addr
		#flags interval, timeout
		flags timeout
		size 131072
		gc-interval 10m
		#auto-merge
	}


	#
	# PREROUTING
	#

	chain PREROUTING {

		# headers
		type filter hook prerouting priority raw;
		iifname "lo" counter accept
		icmp type echo-request counter accept comment "prerouting4_ICMP"
		# ISP - DO NOT REMOVE
	    iifname $iface_wan ip6 saddr fe80::/10 udp dport 547 th sport 546 counter accept comment "prerouting6_dhclient_ISP_WAN"
	    iifname $iface_wan ip6 saddr fe80::/10 ip6 nexthdr ipv6-icmp counter accept comment "prerouting6_ICMP_ISP_WAN"
	    ip6 nexthdr ipv6-icmp counter accept comment "prerouting6_ICMP"


		# lan basics
		iifname { $iface_private } ether saddr @ETHERDROP counter jump ETHERDROP comment "prerouting_ETHERDROP"


		# allowed
		iifname { $iface_lan } counter accept comment "prerouting_LAN"
		iifname { $iface_tunnel } counter accept comment "prerouting_TUNNEL"
		iifname { $iface_vpn_nbux } counter accept comment "prerouting_VPN"
		iifname { $iface_guest } counter accept comment "prerouting_GUEST"
		iifname { $iface_domo } counter accept comment "prerouting_DOMO"
		iifname { $iface_manage } counter accept comment "prerouting_MANAGE"
		iifname { $iface_private } counter accept comment "prerouting_PRV"
		iifname { $iface_wan } ip saddr { $addr_trusted } counter accept comment "prerouting_TRUSTED"
		iifname { $iface_wan } counter accept comment "prerouting_WAN"
		iifname { $iface_vanisher } counter accept comment "prerouting_VANISHER"


		# trash
		counter jump TRASH comment "prerouting_TRASH"
		counter comment "prerouting_COUNT"
	}


	#
	# Logging chains
	#


	chain ETHERDROP {
		log prefix "netfilter:raw_ETHERDROP" group 0
		counter drop
	}

	chain TRASH {
		log prefix "netfilter:raw_TRASH" group 0
		counter drop
	}

}
```


## mangle table: multi-WAN marking

The `mangle` table is where flow identity is assigned.

This is the core idea:

```text
incoming flow from WAN1 → ct mark 0x100
incoming flow from WAN2 → ct mark 0x200
incoming flow from WAN3 → ct mark 0x300
vanisher/tunnel flow     → ct mark 0x400
```

The mark is stored in `ct mark` so it survives across packets in the same connection. It is copied to `meta mark` so Linux policy routing can select the right routing table.

This is where nftables and `ip rule` shake hands. Firm handshake. No YAML.

### Source: `mangle.inc`

```nft
#!/usr/sbin/nft -f

#
# Mangle NFT definition
#



table inet mangle {

	# TO BE REMOVED
	# this is no more necessary, see netdev/egress rules (remove POSTROUTING jump rules too)
	# note the notrack set, it should be better to untrack mangled packet (not tested)
	# <public-v6-prefix-19> = fe80::/10 + <public-v6-prefix-17>
	#chain prio_orange {
		##meta nfproto ipv4 udp sport 68 udp dport 67 meta priority set 0:6 ip dscp set cs6 counter comment "mangle4-prio_orange_DHCP4"
		#meta nfproto ipv4 udp sport 68 udp dport 67 meta priority set 0:6 ip dscp set cs6 notrack counter comment "mangle4-prio_orange_DHCP4"
        ##ip6 daddr { <public-v6-prefix-19> } icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } meta priority set 0:6 ip6 dscp set cs6 counter comment "mangle6-prio_orange_ICMP6"
        #ip6 daddr { <public-v6-prefix-19> } icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } meta priority set 0:6 ip6 dscp set cs6 notrack counter comment "mangle6-prio_orange_ICMP6"
        ##ip6 daddr { <public-v6-prefix-19> } udp sport 546 udp dport 547 meta priority set 0:6 ip6 dscp set cs6 counter comment "mangle6-prio_orange_DHCP6"
        #ip6 daddr { <public-v6-prefix-19> } udp sport 546 udp dport 547 meta priority set 0:6 ip6 dscp set cs6 notrack counter comment "mangle6-prio_orange_DHCP6"
		#}


	chain PREROUTING {
		type filter hook prerouting priority mangle; policy accept;
		ct mark != 0x0 counter meta mark set ct mark counter return comment "mangle-prerouting_MARKED"
		iifname $iface_wan1 ct state new counter jump MWAN1 comment "mangle-prerouting_WAN1"
		iifname $iface_wan2 ct state new counter jump MWAN2 comment "mangle-prerouting_WAN2"
		iifname $iface_wan3 ct state new counter jump MWAN3 comment "mangle-prerouting_WAN3"
		#iifname $iface_wan4 ct state new counter jump MWAN4 comment "mangle-prerouting_WAN4"
		iifname $iface_vanisher ct state new counter jump MWAN4 comment "mangle-prerouting_VANISHER"
		ct state new counter jump MWAN comment "mangle-prerouting_MWAN"
		ct mark != 0x0 counter meta mark set ct mark
	}


	chain INPUT {
		type filter hook input priority mangle; policy accept;
	}


	chain FORWARD {
		type filter hook forward priority mangle; policy accept;
	}


	chain OUTPUT {
		type route hook output priority mangle; policy accept;
		# necessary for local services (ovpn,wg,https,...)
		ct mark != 0x0 counter meta mark set ct mark
	}


	chain POSTROUTING {
		type filter hook postrouting priority mangle; policy accept;

		# TO BE REMOVED
		# uncomment this to change cos/dscp dhcp for orange (<public-v6-prefix-19> = fe80::/10 + <public-v6-prefix-17>)
		#oifname $iface_wan1 meta nfproto ipv4 udp sport 68 udp dport 67 jump prio_orange comment "mangle4-postrouting_orange"
		#oifname $iface_wan1 ip6 daddr { <public-v6-prefix-19> } jump prio_orange comment "mangle6-postrouting_orange"

		ct mark set mark counter
	}


	chain MWAN {
		ip daddr { 127.0.0.0/8, 192.168.0.0/16, 172.16.0.0/12, 10.0.0.0/8, 224.0.0.0/3, 239.192.0.0/14, 239.255.255.250 } counter return comment "mangle4-mwan_LAN"
		ip6 daddr { ::1/128, fe80::/10, ff00::/8, fc00::/7, $addr6_private } counter return comment "mangle6-mwan_LAN"
		ct mark != 0x0 counter return comment "mangle-mwan_MARKED"
		ct state established,related counter return comment "mangle-mwan_RELATED"

		# global default load-balancing
		#ip protocol { tcp, udp } numgen random mod 100 < 0 counter jump MWAN2 comment "mangle4-mwan_WAN2"
        #ip6 nexthdr { tcp, udp } numgen random mod 100 < 0 counter jump MWAN1 comment "mangle6-mwan_WAN2"
		#ct mark 0x0 counter jump MWAN1 comment "mangle-mwan_WAN1"
		# alternative example
		#ip protocol { tcp, udp } numgen random mod 100 vmap { 0-70: jump MWAN1 , 71-100: jump MWAN2 } counter comment "mangle-mwan_WAN1-2"


		# include custom mwan rules
		#include "/etc/nft.d/mwan.inc"


		# OVERRIDE IN CASE OF DURATION LINK INCIDENT
		#ct mark 0x100 counter jump MWAN2 comment "mangle-output_FORCE_WAN1-2"
		#ct mark 0x200 counter jump MWAN1 comment "mangle-output_FORCE_WAN2-1"
		#ct mark 0x300 counter jump MWAN1 comment "mangle-output_FORCE_WAN3-1"
		#ct mark 0x300 counter jump MWAN2 comment "mangle-output_FORCE_WAN3-2"

	}

	#
	# MWAN Chain
	#


	chain MWAN1 { 
		counter ct mark set 0x100 
		#log prefix "netfilter:mangle_MWAN1" group 0
	}

	chain MWAN2 {
		counter ct mark set 0x200
		#log prefix "netfilter:mangle_MWAN2" group 0
	}

	chain MWAN3 {
		counter ct mark set 0x300
		#log prefix "netfilter:mangle_MWAN3" group 0
	}

	chain MWAN4 {
		counter ct mark set 0x400
		#log prefix "netfilter:mangle_MWAN4" group 0
	}

	#chain MWAN1_META {
	#	counter	meta mark set 0x100
	#	log prefix "netfilter:mangle_MWAN1_META" group 0
	#}

	#chain MWAN2_META {
	#	counter	meta mark set 0x200
	#	log prefix "netfilter:mangle_MWAN2_META" group 0
	#}

	#chain MWAN3_META {
	#	counter	meta mark set 0x300
	#	log prefix "netfilter:mangle_MWAN3_META" group 0
	#}

	#chain MWAN12_PT {
	#	jhash ip protocol . ip saddr . tcp sport . ip daddr . tcp dport mod 2 vmap { 0 : jump MWAN1, 1 : jump MWAN2 } counter 
	#	log prefix "netfilter:mangle_MWAN12_PT" group 0
	#}

	#chain MWAN123_PT {
	#	jhash ip protocol . ip saddr . tcp sport . ip daddr . tcp dport mod 3 vmap { 0 : jump MWAN1, 1 : jump MWAN2, 2 : jump MWAN3 } counter 
	#	log prefix "netfilter:mangle_MWAN123_PT" group 0
	#}

}
```


## custom MWAN policy

This file contains policy overrides and examples for multi-WAN selection.

It is intentionally separate from the generic mangle logic. The generic file provides the mechanism; this file provides local choices.

That split matters because WAN policy changes more often than the packet-marking mechanism.

### Source: `mwan.inc`

```nft
# custom mwan rules

# vanisher test me.gandi.net
# ip daddr <public-v4-addr-35> counter jump MWAN4

#
# http/s load-balancing
#
#tcp dport { 80, 443 } counter jump MWAN1 comment "mwanlb_http"
#tcp dport { 80, 443 } numgen random mod 100 < 30 counter jump MWAN2 comment "mwanlb_http"
#udp dport { 443 } counter jump MWAN1 comment "mwanlb_http3"
#udp dport { 443 } numgen random mod 100 < 30 counter jump MWAN2 comment "mwanlb_http3"
# alternatives
#tcp dport { 80, 443 } numgen random mod 100 vmap { 0-60: jump MWAN1 , 61-99: jump MWAN2 } counter comment "mwanlb_http"
#tcp dport { 80, 443 } numgen random mod 100 vmap { 0-40: jump MWAN1 , 41-60: jump MWAN2 , 61-99: jump MWAN3 } counter comment "mwanlb_http"


#
# persist / jhash some destination (svc which do not support multiple output ips)
#
#ip daddr { $svc_hash_mwan12 } jhash ip protocol . ip saddr . tcp sport . ip daddr . tcp dport mod 2 vmap { 0 : jump MWAN1, 1 : jump MWAN2 } counter comment "mwan12_svc_hash"
#ip daddr { eu.api.kimsufi.com, www.kimsufi.com } counter jump MWAN12_PT comment "mwan12pt_kimsufi"
#ip daddr { eu.api.kimsufi.com, www.kimsufi.com } counter jump MWAN123_PT comment "mwan123pt_kimsufi"


#
# wan's svc definitions
#
#ip daddr $svc_wan3 counter jump MWAN3 comment "mwan3_svc"
#ip daddr $svc_wan2 counter jump MWAN2 comment "mwan2_svc"
#ip daddr $svc_wan1 counter jump MWAN1 comment "mwan1_svc"
#ip6 daddr $svc6_wan3 counter jump MWAN3 comment "mwan3_svc6"
#ip6 daddr $svc6_wan2 counter jump MWAN2 comment "mwan2_svc6"
#ip6 daddr $svc6_wan1 counter jump MWAN1 comment "mwan1_svc6"


#
# tv and media devices
#
#ip saddr $addr_dev_tv counter jump MWAN2 comment "mwan2_tv" # force media via wan2
#ip6 saddr $addr6_dev_tv counter jump MWAN2 comment "mwan2_tv6" # force media via wan2


#
# OVERRIDE DUE TO LINK DURATION INCIDENT
# use only MWAN2 11/02/2022 (orange1 KO)
#
#counter jump MWAN2 comment "MWAN2_OVERRIDE"



#
# torrent / nzb load-balancing
#
#ip saddr $addr_aurora tcp dport != { 563, 25, 587, 465 } counter jump MWAN3 comment "mwan3_torrentsTCP_aurora"
#ip saddr $addr_aurora udp dport { 2048-65535 } counter jump MWAN3 comment "mwan3_torrentsUDP_aurora"
#ip daddr { $svc_newz } counter jump MWAN1 comment "mwan1_newz"
#ip6 saddr $addr6_aurora tcp dport != { 563, 25, 587, 465 } counter jump MWAN3 comment "mwan3_torrentsTCP_aurora6"
#ip6 saddr $addr6_aurora udp dport { 2048-65535 } counter jump MWAN3 comment "mwan3_torrentsUDP_aurora6"
#ip6 daddr { $svc6_newz } counter jump MWAN1 comment "mwan1_newz6"
```


## nat table: DNS policy, DNAT, SNAT and masquerade

The NAT table is doing more than simple Internet masquerade.

It handles:

- DNS interception per zone;
- special DNS paths for kids/noads/guest/unknown devices;
- router-local DNS redirection through `OUTPUT`;
- DNAT to local services;
- masquerade for WAN and tunnel exits;
- selected IPv6 ULA egress behavior;
- loopback/hairpin-style cases.

DNS policy interception is intentionally central here. If clients are allowed to choose arbitrary resolvers, a lot of network policy becomes decorative.


```
                         Client DNS query
                               │
                 tcp/udp dport 53 from VLAN
                               │
                               ▼
                         nft nat PREROUTING
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                    │
          ▼                    ▼                    ▼
      LAN client           kid device          guest client
          │                    │                    │
          ▼                    ▼                    ▼
   default DNS svc        kids DNS svc        guest DNS svc
          │                    │                    │
          └────────────────────┼────────────────────┘
                               │
                               ▼
                      local DNS resolver(s)
                               │
                               ▼
                       recursive / upstream
```


### Source: `nat.inc`

```nft
#!/usr/sbin/nft -f

#
# Network Adress Translation (NAT) NFT definition
#


table inet nat {
	chain PREROUTING {
		type nat hook prerouting priority dstnat; policy accept;

		# dns - SEE OUTPUT + POSTROUTING (only required if final port_svc_xxx != 53)
		iifname $iface_lan ether saddr $ether_dev_kids meta l4proto {tcp, udp} th dport 53 counter dnat ip to $addr_svc_dns_kids:$port_svc_dns_kids comment "nat4-prerouting_ether_kids_svc_dns_PRV"
		iifname $iface_lan ip saddr $addr_dev_cast meta l4proto {tcp, udp} th dport 53 counter dnat ip to $addr_svc_dns_cast:$port_svc_dns_cast comment "nat4-prerouting_cast_svc_dns_PRV"
		iifname $iface_lan ip saddr $addr_lan_unknown meta l4proto {tcp, udp} th dport 53 counter dnat ip to $addr_svc_dns_unknown:$port_svc_dns_unknown comment "nat4-prerouting_unknown_svc_dns_PRV"
		iifname $iface_lan ip daddr $addr_svc_dns_kids meta l4proto {tcp, udp} th dport 53 counter dnat ip to $addr_svc_dns_kids:$port_svc_dns_kids comment "nat4-prerouting_kids_svc_dns_PRV"
		iifname $iface_lan ip daddr $addr_svc_dns_noads meta l4proto {tcp, udp} th dport 53 counter dnat ip to $addr_svc_dns_noads:$port_svc_dns_noads comment "nat4-prerouting_noads_svc_dns_PRV"
		iifname $iface_private ip daddr $addr_svc_dns_guest meta l4proto {tcp, udp} th dport 53 counter dnat ip to $addr_svc_dns_guest:$port_svc_dns_guest comment "nat4-prerouting_guest_svc_dns_PRV"
		iifname $iface_private ip daddr $addr_svc_dns_gw meta l4proto {tcp, udp} th dport 53 counter dnat ip to $addr_svc_dns_gw:$port_svc_dns_gw comment "nat4-prerouting_gw_svc_dns_PRV"
		ip daddr $gw_vpn_nbux meta l4proto {tcp, udp} th dport 53 counter dnat ip to $addr_svc_dns:$port_svc_dns comment "nat4-prerouting_vpn_svc_dns"

		iifname $iface_lan ether saddr $ether_dev_kids meta l4proto {tcp, udp} th dport 53 counter dnat ip6 to $addr6_svc_dns_kids:$port_svc_dns_kids comment "nat6-prerouting_ether_kids_svc_dns_PRV"
        iifname $iface_lan ip6 saddr $addr6_dev_cast meta l4proto {tcp, udp} th dport 53 counter dnat ip6 to $addr6_svc_dns_cast:$port_svc_dns_cast comment "nat6-prerouting_cast_svc_dns_PRV"
        iifname $iface_lan ip6 saddr $addr6_lan_ula_unknown meta l4proto {tcp, udp} th dport 53 counter dnat ip6 to $addr6_svc_dns_unknown:$port_svc_dns_unknown comment "nat6-prerouting_unknown_svc_dns_PRV"
        iifname $iface_lan ip6 daddr $addr6_svc_dns_kids meta l4proto {tcp, udp} th dport 53 counter dnat ip6 to $addr6_svc_dns_kids:$port_svc_dns_kids comment "nat6-prerouting_kids_svc_dns_PRV"
        iifname $iface_lan ip6 daddr $addr6_svc_dns_noads meta l4proto {tcp, udp} th dport 53 counter dnat ip6 to $addr6_svc_dns_noads:$port_svc_dns_noads comment "nat6-prerouting_noads_svc_dns_PRV"
        iifname $iface_private ip6 daddr $addr6_svc_dns_guest meta l4proto {tcp, udp} th dport 53 counter dnat ip6 to $addr6_svc_dns_guest:$port_svc_dns_guest comment "nat6-prerouting_guest_svc_dns_PRV"
        iifname $iface_private ip6 daddr $addr6_svc_dns_gw meta l4proto {tcp, udp} th dport 53 counter dnat ip6 to $addr6_svc_dns_gw:$port_svc_dns_gw comment "nat6-prerouting_gw_svc_dns_PRV"
        ip6 daddr $gw6_vpn_nbux meta l4proto {tcp, udp} th dport 53 counter dnat ip6 to $addr6_svc_dns:$port_svc_dns comment "nat6-prerouting_vpn_svc_dns"


		# vanisher
		#iifname $iface_vanisher_forward tcp dport $port_vanisher_forward counter dnat ip to $addr_vanisher_forward comment "nat4-prerouting_TCP_VANISHER"
		#iifname $iface_vanisher_forward udp dport $port_vanisher_forward counter dnat ip to $addr_vanisher_forward comment "nat4-prerouting_UDP_VANISHER"
		#iifname $iface_vanisher_forward tcp dport $port_vanisher_forward counter dnat ip6 to $addr6_vanisher_forward comment "nat6-prerouting_TCP_VANISHER"
		#iifname $iface_vanisher_forward udp dport $port_vanisher_forward counter dnat ip6 to $addr6_vanisher_forward comment "nat6-prerouting_UDP_VANISHER"


		# http
		iifname $iface_wan ip saddr != { $addr_private_wan } tcp dport { $port_svc_http } counter dnat ip to $addr_svc_http:443 comment "nat4-prerouting_http_HTTPS_WAN"
        iifname $iface_wan ip6 saddr != { $addr6_private_wan } tcp dport { $port_svc_http } counter dnat ip6 to $addr6_svc_http:443 comment "nat6-prerouting_http_HTTPS_WAN"


		# vpn via wan
		iifname $iface_wan ip saddr != { $addr_private_wan } tcp dport { 21, 53, 80, 1194, 9545 } counter dnat ip to $addr_svc_vpn:1194 comment "nat4-prerouting_ovpnTCP_WAN"
		iifname $iface_wan ip saddr != { $addr_private_wan } udp dport { 1194, 9545 } counter dnat ip to $addr_svc_vpn:1194 comment "nat4-prerouting_ovpnUDP_WAN"
		iifname $iface_wan ip saddr != { $addr_private_wan } udp dport { 53, 123, 1195 } counter dnat ip to $addr_svc_vpn:1195 comment "nat4-prerouting_wgUDP_WAN"
		# vpn also allowed via lan
		iifname $iface_lan ip daddr $addr_svc_vpn udp dport { 9545 } counter dnat ip to $addr_svc_vpn:1194 comment "nat4-prerouting_ovpnUDP_LAN"
		iifname $iface_lan ip daddr $addr_svc_vpn tcp dport { 9545 } counter dnat ip to $addr_svc_vpn:1194 comment "nat4-prerouting_ovpnTCP_LAN"
		iifname $iface_lan ip daddr $addr_svc_vpn udp dport { 53 } counter dnat ip to $addr_svc_vpn:1195 comment "nat4-prerouting_wgUDP_LAN"

		iifname $iface_wan ip6 saddr != { $addr6_private_wan } tcp dport { 21, 53, 1194, 9545 } counter dnat ip6 to $addr6_svc_vpn:1194 comment "nat6-prerouting_ovpnTCP_WAN"
        iifname $iface_wan ip6 saddr != { $addr6_private_wan } udp dport { 1194, 9545 } counter dnat ip6 to $addr6_svc_vpn:1194 comment "nat6-prerouting_ovpnUDP_WAN"
        iifname $iface_wan ip6 saddr != { $addr6_private_wan } udp dport { 53, 123, 1195 } counter dnat ip6 to $addr6_svc_vpn:1195 comment "nat6-prerouting_wgUDP_WAN"
        # vpn also allowed via lan
        iifname $iface_lan ip6 daddr $addr6_svc_vpn udp dport { 9545 } counter dnat ip6 to $addr6_svc_vpn:1194 comment "nat6-prerouting_ovpnUDP_LAN"
        iifname $iface_lan ip6 daddr $addr6_svc_vpn tcp dport { 9545 } counter dnat ip6 to $addr6_svc_vpn:1194 comment "nat6-prerouting_ovpnTCP_LAN"
        iifname $iface_lan ip6 daddr $addr6_svc_vpn udp dport { 53 } counter dnat ip6 to $addr6_svc_vpn:1195 comment "nat6-prerouting_wgUDP_LAN"


		# ssh jump
		iifname $iface_wan ip saddr != { $addr_private_wan } tcp dport 22 counter dnat ip to $addr_svc_ssh:22 comment "nat4-prerouting_SSH_WAN"
        iifname $iface_wan ip6 saddr != { $addr6_private_wan } tcp dport 22 counter dnat ip6 to $addr6_svc_ssh:22 comment "nat6-prerouting_SSH_WAN"
	}


	#chain INPUT {
		#type nat hook input priority 100; policy accept;
		#}


	chain OUTPUT {
		type nat hook output priority -100; policy accept;
		# dns router itself - SEE PREROUTING (only required if final port_svc_xxx != 53)
		ip daddr $addr_svc_dns_unknown meta l4proto { tcp, udp } th dport 53 counter dnat ip to $addr_svc_dns_unknown:$port_svc_dns_unknown comment "nat4-output_unknown_svc_dns"
		ip daddr $addr_svc_dns_kids meta l4proto { tcp, udp } th dport 53 counter dnat ip to $addr_svc_dns_kids:$port_svc_dns_kids comment "nat4-output_kids_svc_dns"
		ip daddr $addr_svc_dns_noads meta l4proto { tcp, udp } th dport 53 counter dnat ip to $addr_svc_dns_noads:$port_svc_dns_noads comment "nat4-output_noads_svc_dns"
		ip daddr $addr_svc_dns_guest meta l4proto { tcp, udp } th dport 53 counter dnat ip to $addr_svc_dns_guest:$port_svc_dns_guest comment "nat4-output_guest_svc_dns"
		ip daddr $addr_svc_dns_gw meta l4proto { tcp, udp } th dport 53 counter dnat ip to $addr_svc_dns_gw:$port_svc_dns_gw comment "nat4-output_gw_svc_dns"

		ip6 daddr $addr6_svc_dns_unknown meta l4proto { tcp, udp } th dport 53 counter dnat ip6 to $addr6_svc_dns_unknown:$port_svc_dns_unknown comment "nat6-output_unknown_svc_dns"
		ip6 daddr $addr6_svc_dns_kids meta l4proto { tcp, udp } th dport 53 counter dnat ip6 to $addr6_svc_dns_kids:$port_svc_dns_kids comment "nat6-output_kids_svc_dns"
		ip6 daddr $addr6_svc_dns_noads meta l4proto { tcp, udp } th dport 53 counter dnat ip6 to $addr6_svc_dns_noads:$port_svc_dns_noads comment "nat6-output_noads_svc_dns"
		ip6 daddr $addr6_svc_dns_guest meta l4proto { tcp, udp } th dport 53 counter dnat ip6 to $addr6_svc_dns_guest:$port_svc_dns_guest comment "nat6-output_guest_svc_dns"
		ip6 daddr $addr6_svc_dns_gw meta l4proto { tcp, udp } th dport 53 counter dnat ip6 to $addr6_svc_dns_gw:$port_svc_dns_gw comment "nat6-output_gw_svc_dns"
		}


	chain POSTROUTING {
		type nat hook postrouting priority srcnat; policy accept;
		# dns hairpin NAT / NAT loopback DNS - SEE PREROUTING (only required if final port_svc_xxx != 53)
		iifname $iface_private ip saddr { $addr_private } ip daddr { $addr_svc_dns_kids, $addr_svc_dns_noads, $addr_svc_dns_unknown, $addr_svc_dns_guest, $addr_svc_dns_gw } meta l4proto {tcp, udp} th dport 53 ct status dnat counter masquerade comment "nat4-postrouting_svc_dns_PRV"
        iifname $iface_private ip6 saddr { $addr6_private } ip6 daddr { $addr6_svc_dns_kids, $addr6_svc_dns_noads, $addr6_svc_dns_unknown, $addr6_svc_dns_guest, $addr6_svc_dns_gw } meta l4proto {tcp, udp} th dport 53 ct status dnat counter masquerade comment "nat6-postrouting_svc_dns_PRV"

		oifname $iface_tunnel ip saddr $addr_private counter snat to $snat_tunnel comment "nat4-postrouting_private_TUNNEL"
		#oifname $iface_vpn_nbux ip saddr $addr_private counter masquerade comment "nat4-postrouting_private_VPN"
		oifname $iface_vanisher ip saddr $addr_private counter masquerade comment "nat4-postrouting_private_VANISHER"
		# access private_wan
		#oifname $iface_private_wan1 ip saddr $addr_private counter masquerade comment "nat4-postrouting_private_PRVWAN1"
		oifname $iface_private_wan1 ip saddr $addr_private ip daddr { $addr_private_wan } counter masquerade comment "nat4-postrouting_private_PRVWAN1"
		# manage to internet (firmware upgrade)
		oifname { $iface_wan } ip saddr $addr_manage counter masquerade comment "nat4-postrouting_manage_WAN"
		# avoid asymmetric routing from lan to manage
		oifname $iface_manage ip saddr $addr_private counter masquerade comment "nat4-postrouting_private_MANAGE"

        # map ula to public prefix
        #oifname $iface_wan1 counter snat ip6 to ip6 saddr map { $addr6_lan_ula_prefix : $addr6_lan_wan1_prefix } comment "nat6-postrouting_lanULA_WAN1"
        #oifname $iface_wan1 counter snat ip6 to ip6 saddr map { $addr6_guest_ula_prefix : $addr6_guest_wan1_prefix } comment "nat6-postrouting_guestULA_WAN1"
        # OR just masquerade ula prefix (like ip4)
        #oifname $iface_wan1 ip6 saddr $addr6_private counter masquerade comment "nat6-postrouting_private_WAN1"
        #oifname $iface_wan1 ip6 saddr $addr6_guest counter masquerade comment "nat6-postrouting_guest_WAN1"
        #oifname $iface_tunnel ip6 saddr $addr6_private counter masquerade comment "nat6-postrouting_private_TUNNEL"
        oifname $iface_tunnel ip6 saddr $addr6_private counter snat to $snat6_tunnel comment "nat6-postrouting_private_TUNNEL"
		#oifname $iface_vpn_nbux ip6 saddr $addr6_private counter masquerade comment "nat6-postrouting_private_VPN"
        oifname $iface_vanisher ip6 saddr $addr6_private counter masquerade comment "nat6-postrouting_private_VANISHER"
        # access private_wan
        oifname $iface_private_wan1 ip6 saddr $addr6_private ip6 daddr { $addr6_private_wan } counter masquerade comment "nat6-postrouting_lan_PRVWAN1"
        # manage to internet (firmware upgrade)
        oifname { $iface_wan } ip6 saddr $addr6_manage counter masquerade comment "nat6-postrouting_manage_WAN"
        # avoid asymmetric routing from lan to manage
        oifname $iface_manage ip6 saddr $addr6_private counter masquerade comment "nat6-postrouting_private_MANAGE"
	}
}
```


## filter table: main policy

The `filter` table is the normal firewall policy layer.

It contains the default drop logic, stateful accept paths, zone policy, debug/logging chains and the `flowtable fastpath` used for forwarded established flows.

This table is where the firewall answers the boring but essential question:

```text
should this packet be allowed by policy?
```

The trick is that by the time traffic reaches this layer, much of the garbage has already been handled by `netdev`, `raw`, `mangle`, `nat` or `protect`.

### Source: `filter.inc`

```nft
#!/usr/sbin/nft -f

#
# Filter NFT definition
#




table inet filter {

	set TRUSTED4 {
        type ipv4_addr
        size 131072
        flags interval
        elements = { $addr_trusted }
    }

    set TRUSTED6 {
		type ipv6_addr
		size 131072
		flags interval
		elements = { $addr6_trusted }
	}

	#
	# INPUT
	#

	chain INPUT {

		# headers
		type filter hook input priority filter; policy drop;
		iifname $iface_wan ip6 saddr fe80::/10 udp dport 547 th sport 546 counter jump LINK comment "input6_dhclient_ISP_WAN"
		iifname $iface_wan ip6 saddr fe80::/10 ip6 nexthdr ipv6-icmp counter jump LINK comment "input6_ICMP_ISP_WAN"
		iifname { $iface_wan, $iface_private_wan } ip6 saddr fe80::/10 ip6 nexthdr ipv6-icmp icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, mld-listener-reduction, mld-listener-query, mld-listener-report, mld2-listener-report, mld-listener-done } counter jump LINK comment "input6_NDMLD_WAN"
		ct state established,related counter accept comment "input_RELATED"
		iifname "lo" counter accept
		ct state invalid counter jump INVALID comment "input_INVALID"
		ip protocol icmp counter jump DEBUG comment "input4_ICMP"
        meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, echo-request } counter jump DEBUG comment "input6_typed_ICMP"
        ip6 saddr fe80::/10 ip6 daddr fe80::/10 counter jump DEBUG comment "input6_LL"
		iifname { $iface_private, $iface_vpn_nbux } ip daddr <public-v4-addr-36> udp dport 5353 counter accept comment "input4_MDNS"
		iifname { $iface_private, $iface_vpn_nbux } ip6 daddr <public-v6-addr-20> udp dport 5353 counter accept comment "input6_MDNS"
		iifname { $iface_private, $iface_vpn_nbux } ip protocol igmp counter accept comment "input_IGMP"
		iifname { $iface_private, $iface_vpn_nbux } ip6 nexthdr ipv6-icmp counter jump DEBUG comment "input6_ICMP"
	

		# fron vanisher
		iifname $iface_vanisher counter jump LOGDROP comment "input_VANISHER"


		# basic services
		iifname { $iface_private_wan, $iface_private, $iface_vpn_nbux } ip saddr { $addr_private_wan, $addr_private, $addr_vpn_nbux } ct state new udp dport { $port_svc_dns_gw, 53, 123, 514 } counter accept comment "input4_basic_UDP"
		iifname { $iface_private_wan, $iface_private, $iface_vpn_nbux } ip saddr { $addr_private_wan, $addr_private, $addr_vpn_nbux } ct state new tcp dport { $port_svc_dns_gw, 53, 123, 443, 514 } counter accept comment "input4_basic_TCP"
		iifname { $iface_private_wan, $iface_private, $iface_vpn_nbux } ip6 saddr { $addr6_private_wan, $addr6_private, $addr6_vpn_nbux } ct state new udp dport { $port_svc_dns_gw, 53, 123, 514 } counter accept comment "input6_basic_UDP"
        iifname { $iface_private_wan, $iface_private, $iface_vpn_nbux } ip6 saddr { $addr6_private_wan, $addr6_private, $addr6_vpn_nbux } ct state new tcp dport { $port_svc_dns_gw, 53, 123, 443, 514 } counter accept comment "input6_basic_TCP"

		# from lan / manage / guest (private)
		iifname { $iface_private } ip daddr 255.255.255.255 udp dport { 67, 68, 69 } counter accept comment "input4_DHCP"
		iifname { $iface_private } ip daddr { $bcast_lan, $bcast_guest, $bcast_manage, $bcast_domo, <public-v4-prefix-32>, <public-v4-prefix-33>, <public-v4-addr-34> } counter accept comment "input4_SSDPDEBcast"
		iifname { $iface_lan } ct state new ip saddr $addr_lan counter accept comment "input4_LAN"
		iifname { $iface_manage } ct state new ip saddr $addr_manage counter accept comment "input4_MANAGE"
        iifname { $iface_private } ip6 saddr fe80::/10 udp dport { 547, 69 } counter jump LINK comment "input6_DHCP"
        iifname { $iface_private } ip6 daddr { <public-v6-prefix-16>, <public-v6-prefix-17> } counter accept comment "input6_MCAST"
        iifname { $iface_private } ip6 saddr fe80::/10 meta l4proto {tcp, udp} th dport 53 counter accept comment "input6_LL_DNS"
        iifname { $iface_lan } ct state new ip6 saddr $addr6_lan counter accept comment "input6_LAN"
        iifname { $iface_manage } ct state new ip6 saddr $addr6_manage counter accept comment "input6_MANAGE"


		# from domo
		iifname $iface_domo ct state new tcp dport { 80, 111, 443, 444, 445, 2049, 5870, 20048 } ip saddr $addr_domo counter accept comment "input4_svc_DOMO"
        iifname $iface_domo ct state new tcp dport { 80, 111, 443, 444, 445, 2049, 5870, 20048 } ip6 saddr $addr6_domo counter accept comment "input6_svc_DOMO"


		# from private_wan and vpn (nbux, job)
		iifname { $iface_private_wan, $iface_vpn_nbux } ip saddr { $addr_vpn_nbux } ct state new counter jump VPN comment "input4_VPN"
        iifname { $iface_private_wan, $iface_vpn_nbux } ip6 saddr { $addr6_vpn_nbux } ct state new counter jump VPN comment "input6_VPN"


		# fron tunnel 
		iifname $iface_tunnel ip saddr @TRUSTED4 ct state new ip daddr { $addr_svc_http } tcp dport { $port_svc_http } counter jump TUNNEL comment "input4_domo_TUNNEL"
		iifname $iface_tunnel ct state new ip protocol { tcp, udp } th dport { $port_svc_vpn } counter jump TUNNEL comment "input4_vpn_TUNNEL"
		iifname $iface_tunnel ip6 saddr @TRUSTED6 ct state new ip6 daddr { $addr6_svc_http } tcp dport { $port_svc_http } counter jump TUNNEL comment "input6_domo_TUNNEL"
		iifname $iface_tunnel ct state new ip6 nexthdr { tcp, udp } th dport { $port_svc_vpn } counter jump TUNNEL comment "input6_vpn_TUNNEL"


		# from wan - count from trusted only
		iifname $iface_wan ip saddr @TRUSTED4 ct state new counter jump TRUSTED_CONT comment "input4_log_TRUSTED_WAN"
		iifname $iface_wan ip6 saddr @TRUSTED6 ct state new counter jump TRUSTED_CONT comment "input6_log_TRUSTED_WAN"
		iifname $iface_wan ip saddr @TRUSTED4 ip daddr $addr_svc_http ct state new tcp dport { $port_svc_http } counter jump WAN comment "input4_http_WAN"
		iifname $iface_wan ip6 saddr @TRUSTED6 ip6 daddr $addr6_svc_http ct state new tcp dport { $port_svc_http } counter jump WAN comment "input6_http_WAN"
		iifname $iface_wan ip saddr @TRUSTED4 ip daddr $addr_svc_ssh ct state new tcp dport { $port_svc_ssh } counter jump WAN comment "input4_ssh_WAN"
		iifname $iface_wan ip6 saddr @TRUSTED6 ip6 daddr $addr6_svc_ssh ct state new tcp dport { $port_svc_ssh } counter jump WAN comment "input6_ssh_WAN"
		# from wan - vpn 
		iifname $iface_wan ct state new ip protocol { tcp, udp } th dport { $port_svc_vpn } counter jump WAN comment "input4_vpn_WAN"
		iifname $iface_wan ct state new ip6 nexthdr { tcp, udp } th dport { $port_svc_vpn } counter jump WAN comment "input6_vpn_WAN"
	

		# footers
		counter jump TRASH comment "input_TRASH"
		counter comment "input_COUNT"
	}


	#
	# FORWARD
	# 

	#
	# FASTPATH
	# NOTE : since kernel 6.19.x flowtable (offloading) must contain physical interfaces
	#

	flowtable fastpath {
		hook ingress priority filter; devices = { $iface_offload };
		counter;
	}

	chain FORWARD {

		# headers
		type filter hook forward priority filter; policy drop;
		ct state established meta l4proto { tcp, udp } flow offload @fastpath counter comment "forward_FASTPATH";
		ct state established,related counter accept comment "forward_RELATED"
		iifname "lo" counter accept
		# torelate from LAN to WAN : FIN+ACK or RST+ACK INVALID
		iifname { $iface_private } oifname { $iface_wan } tcp dport { 80, 443, 993 } tcp flags & (fin|ack|rst) == (fin|ack) ct state invalid limit rate 10/second burst 20 packets counter accept comment "forward_silent1_INVALID_PRV_WAN"
		iifname { $iface_private } oifname { $iface_wan } tcp dport { 80, 443, 993 } tcp flags & (fin|ack|rst) == (rst|ack) ct state invalid limit rate 10/second burst 20 packets counter accept comment "forward_silent2_INVALID_PRV_WAN"
		iifname { $iface_private } ct state invalid counter jump INVALID comment "forward_INVALID_PRV"
		ct state invalid counter jump INVALID comment "forward_INVALID"
		ip protocol icmp counter jump DEBUG comment "forward4_ICMP"
		ip6 saddr fe80::/10 ip6 daddr fe80::/10 counter jump DEBUG comment "forward6_LL"
       	#meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, mld-listener-query, mld-listener-report, mld-listener-reduction, nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, ind-neighbor-solicit, ind-neighbor-advert, mld2-listener-report, echo-request, echo-reply } counter jump DEBUG comment "forward6_typed_ICMP"
        meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request } counter jump DEBUG comment "forward6_typed_ICMP"
		iifname { $iface_private, $iface_vpn_nbux } ip6 nexthdr ipv6-icmp counter jump DEBUG comment "forward6_ICMP"


		# from vanisher
		iifname $iface_vanisher counter jump LOGDROP comment "forward_VANISHER"

		# basic services
		iifname { $iface_private_wan, $iface_private, $iface_vpn_nbux } ip saddr { $addr_private_wan, $addr_private, $addr_vpn_nbux } ct state new udp dport { $port_svc_dns_gw, 53, 123, 514 } counter accept comment "forward4_basic_UDP"
		iifname { $iface_private_wan, $iface_private, $iface_vpn_nbux } ip saddr { $addr_private_wan, $addr_private, $addr_vpn_nbux } ct state new tcp dport { $port_svc_dns_gw, 53, 123, 514 } counter accept comment "forward4_basic_TCP"
		iifname { $iface_private_wan, $iface_private, $iface_vpn_nbux } ip6 saddr { $addr6_private_wan, $addr6_private, $addr6_vpn_nbux } ct state new udp dport { $port_svc_dns_gw, 53, 123, 514 } counter accept comment "forward6_basic_UDP"
        iifname { $iface_private_wan, $iface_private, $iface_vpn_nbux } ip6 saddr { $addr6_private_wan, $addr6_private, $addr6_vpn_nbux  } ct state new tcp dport { $port_svc_dns_gw, 53, 123, 514 } counter accept comment "forward6_basic_TCP"

		# kill switch for aurora (avoid out of band vanisher vpn - just to be sure - 1637 is wireguard airvpn)
		iifname $iface_lan oifname $iface_wan ip saddr $addr_svc_aurora meta l4proto { tcp, udp } th dport != { 1-2048 } counter jump LOGDROP comment "forward4_killswitch_aurora_LAN"
		iifname $iface_lan oifname $iface_wan ip6 saddr $addr6_svc_aurora meta l4proto { tcp, udp } th dport != { 1-2048 } counter jump LOGDROP comment "forward6_killswitch_aurora_LAN"

		# from lan / manage / guest / private_wan (private)
		iifname { $iface_private } ip daddr { $bcast_lan, $bcast_guest, $bcast_manage, $bcast_domo, <public-v4-prefix-32>, <public-v4-prefix-33>, <public-v4-addr-34> } counter accept comment "forward4_SSDPDEBcast"
		iifname $iface_lan ct state new ip saddr $addr_lan counter jump LAN comment "forward4_LAN"
		iifname $iface_domo ip saddr $addr_domo ct state new oifname $iface_wan counter jump DOMO comment "forward4_DOMO_WAN"
		iifname $iface_manage ip saddr $addr_manage ct state new oifname $iface_wan counter jump MANAGE comment "forward4_MANAGE_WAN"
		iifname $iface_manage ct state new ip saddr $addr_manage counter jump MANAGE comment "forward4_MANAGE"
		iifname $iface_guest ip saddr $addr_guest ct state new oifname $iface_wan counter jump GUEST comment "forward4_GUEST_WAN"
		oifname $iface_private_wan ct state new ip daddr $addr_private_wan counter jump LOGACCEPT comment "forward4_out_PRVWAN"
		iifname $iface_private_wan ip saddr { $addr_private_wan } oifname $iface_lan ip daddr $addr_svc_http ct state new tcp dport { $port_svc_http } counter jump WAN comment "forward4_http_PRVWAN"

        iifname { $iface_private } ip6 daddr { <public-v6-prefix-16>, <public-v6-prefix-17> } counter accept comment "forward6_MCAST"
        iifname $iface_lan ct state new ip6 saddr $addr6_lan counter jump LAN comment "forward6_LAN"
        iifname $iface_domo ct state new ip6 saddr $addr6_domo oifname $iface_wan counter jump DOMO comment "forward6_DOMO_WAN"
        iifname $iface_manage ct state new ip6 saddr $addr6_manage oifname $iface_wan counter jump MANAGE comment "forward6_MANAGE_WAN"
        iifname $iface_manage ct state new ip6 saddr $addr6_manage counter jump MANAGE comment "forward6_MANAGE"
        iifname $iface_guest ct state new ip6 saddr $addr6_guest oifname $iface_wan counter jump GUEST comment "forward6_GUEST_WAN"
        oifname $iface_private_wan ct state new ip6 daddr { $addr6_private_wan } counter jump LOGACCEPT comment "forward6_out_PRVWAN"
        iifname $iface_private_wan ip6 saddr { $addr6_private_wan } oifname $iface_lan ip6 daddr $addr6_svc_http ct state new tcp dport { $port_svc_http } counter jump WAN comment "forward6_http_PRVWAN"


		# from domo
		#iifname $iface_domo ct state new ip saddr $addr_domo counter jump DOMO comment "forward4_DOMO"
		iifname $iface_domo ct state new tcp dport { 3000, 3001, 8008, 8009, 8443 } ip saddr $addr_domo ip daddr { $addr_dev_cast } counter accept comment "forward4_cast_DOMO"
		iifname $iface_domo ct state new ip saddr $addr_domo ip daddr { $addr_dev_domo } oifname { $iface_lan } counter jump DOMO comment "forward4_lan_DOMO"
		iifname $iface_domo ct state new udp dport { 49000-65535 } ip saddr $addr_domo ip daddr { $addr_lan } oifname { $iface_lan } counter jump DOMO comment "forward4_lan_DOMO_UDP"
		iifname $iface_domo ct state new tcp dport { 11000 } ip saddr $addr_domo ip daddr { $addr_lan } oifname { $iface_lan } counter jump DOMO comment "forward4_lan_DOMO_TCP"
		iifname $iface_domo ct state new tcp dport { $port_svc_monit } ip saddr $addr_domo ip daddr { $addr_svc_monit } counter accept comment "forward4_monit_DOMO"
		iifname $iface_domo ct state new tcp dport { $port_svc_http } ip saddr $addr_domo ip daddr { $addr_svc_http } counter jump DOMO comment "forward4_http_DOMO"
		iifname $iface_domo ct state new tcp dport { 80, 443, 587, 853 } ip saddr $addr_domo oifname { $iface_wan } counter jump DOMO comment "forward4_wan_DOMO"

		#iifname $iface_domo ct state new ip6 saddr $addr6_domo counter jump DOMO comment "forward6_DOMO"
        iifname $iface_domo ct state new tcp dport { 3000, 3001, 8008, 8009, 8443 } ip6 saddr $addr6_domo ip6 daddr { $addr6_dev_cast } counter accept comment "forward6_cast_DOMO"
        iifname $iface_domo ct state new ip6 saddr $addr6_domo ip6 daddr { $addr6_dev_domo } oifname { $iface_wan } counter jump DOMO comment "forward6_lan_DOMO"
        iifname $iface_domo ct state new udp dport { 49000-65535 } ip6 saddr $addr6_domo ip6 daddr { $addr6_lan } oifname { $iface_lan } counter jump DOMO comment "forward6_lan_DOMO_UDP"
        iifname $iface_domo ct state new tcp dport { 11000 } ip6 saddr $addr6_domo ip6 daddr { $addr6_lan } oifname { $iface_lan } counter jump DOMO comment "forward6_lan_DOMO_TCP"
        iifname $iface_domo ct state new tcp dport { $port_svc_monit } ip6 saddr $addr6_domo ip6 daddr { $addr6_svc_monit } counter accept comment "forward6_monit_DOMO"
        iifname $iface_domo ct state new tcp dport { $port_svc_http } ip6 saddr $addr6_domo ip6 daddr { $addr6_svc_http } counter jump DOMO comment "forward6_http_DOMO"
        iifname $iface_domo ct state new tcp dport { 80, 443, 587, 853 } ip6 saddr $addr6_domo oifname { $iface_wan } counter jump DOMO comment "forward6_wan_DOMO"


		# from private_wan and vpn (nbux,job)
		iifname { $iface_private_wan, $iface_vpn_nbux } ip saddr { $addr_vpn_nbux } ct state new counter jump VPN comment "forward4_in_VPN"
		oifname { $iface_private_wan, $iface_vpn_nbux } ip daddr { $addr_vpn_nbux } ct state new counter jump VPN comment "forward4_out_VPN"
        iifname { $iface_private_wan, $iface_vpn_nbux } ip6 saddr {$addr6_vpn_nbux } ct state new counter jump VPN comment "forward6_in_VPN"
        oifname { $iface_private_wan, $iface_vpn_nbux } ip6 daddr {$addr6_vpn_nbux } ct state new counter jump VPN comment "forward6_out_VPN"
		iifname { $iface_private_wan } ip saddr { $addr_private_wan } ct state new ip daddr { $addr_svc_monit } tcp dport $port_svc_monit counter accept comment "forward4_monit_PRVWAN"
		iifname { $iface_private_wan } ip6 saddr { $addr6_private_wan } ct state new ip6 daddr { $addr6_svc_monit } tcp dport $port_svc_monit counter accept comment "forward6_monit_PRVWAN"
		#iifname $iface_vpn_job ip saddr { $gw_vpn_job } ct state new ip daddr { $addr_svc_monit } tcp dport $port_svc_monit counter jump VPN comment "forward4_monit_VPN_JOB"
        #iifname $iface_vpn_job ip6 saddr { $gw6_vpn_job } ct state new ip6 daddr { $addr6_svc_monit } tcp dport $port_svc_monit counter jump VPN comment "forward6_monit_VPN_JOB"


		# from/to tunnel
		oifname $iface_tunnel ct state new counter jump TUNNEL comment "forward_out_TUNNEL"
		# uncomment to allow from tunnel
		iifname $iface_tunnel ip saddr @TRUSTED4 ct state new ip daddr { $addr_svc_http } tcp dport { $port_svc_http } counter jump TUNNEL comment "forward4_domo_TUNNEL"
		iifname $iface_tunnel ct state new ip protocol { tcp, udp } ip daddr { $addr_svc_vpn } th dport { $port_svc_vpn } counter jump TUNNEL comment "forward4_vpn_TUNNEL"
        iifname $iface_tunnel ip6 saddr @TRUSTED6 ct state new ip6 daddr { $addr6_svc_http } tcp dport { $port_svc_http } counter jump TUNNEL comment "forward6_domo_TUNNEL"
		iifname $iface_tunnel ct state new ip6 nexthdr { tcp, udp } ip6 daddr { $addr6_svc_vpn } th dport { $port_svc_vpn } counter jump TUNNEL comment "forward6_vpn_TUNNEL"


		# from wan
		iifname $iface_wan ip saddr @TRUSTED4 ct state new counter jump TRUSTED_CONT comment "forward4_log_TRUSTED_WAN"
		iifname $iface_wan ip saddr @TRUSTED4 oifname $iface_lan ip daddr $addr_svc_ssh ct state new tcp dport $port_svc_ssh counter jump WAN comment "forward4_ssh_WAN"
		iifname $iface_wan ip saddr @TRUSTED4 oifname $iface_lan ip daddr $addr_svc_http ct state new tcp dport $port_svc_http counter jump WAN comment "forward4_http_WAN"
		iifname $iface_wan ct state new ip protocol { tcp, udp } ip daddr { $addr_svc_vpn } th dport { $port_svc_vpn } counter jump WAN comment "forward4_vpn_WAN"
		iifname $iface_wan ip6 saddr @TRUSTED6 ct state new counter jump TRUSTED_CONT comment "forward6_log_TRUSTED_WAN"
        iifname $iface_wan ip6 saddr @TRUSTED6 oifname $iface_lan ip6 daddr $addr6_svc_ssh ct state new tcp dport $port_svc_ssh counter jump WAN comment "forward6_ssh_WAN"
        iifname $iface_wan ip6 saddr @TRUSTED6 oifname $iface_lan ip6 daddr $addr6_svc_http ct state new tcp dport $port_svc_http counter jump WAN comment "forward6_http_WAN"
		iifname $iface_wan ct state new ip6 nexthdr { tcp, udp } ip6 daddr { $addr6_svc_vpn } th dport { $port_svc_vpn } counter jump WAN comment "forward6_vpn_WAN"
		

		# from/to vanisher 
		iifname { $iface_vpn_nbux, $iface_lan } ct state new oifname $iface_vanisher ip saddr { $addr_vpn_nbux, $addr_lan } counter jump VANISHER comment "forward4_VPN_LAN_VANISHER"
        iifname { $iface_vpn_nbux, $iface_lan } ct state new oifname $iface_vanisher ip6 saddr { $addr6_vpn_nbux, $addr6_lan } counter jump VANISHER comment "forward6_VPN_LAN_VANISHER"
		# vanisher forward - disabled (aurora own vpn) - check the above rule all traffic is dropped from iface_vanisher
		#iifname $iface_vanisher_forward ip daddr $addr_vanisher_forward ct state new tcp dport $port_vanisher_forward counter jump VANISHER comment "forward4_TCP_VANISHER"
		#iifname $iface_vanisher_forward ip daddr $addr_vanisher_forward ct state new udp dport $port_vanisher_forward counter jump VANISHER comment "forward4_UDP_VANISHER"
 		#iifname $iface_vanisher_forward ip6 daddr $addr6_vanisher_forward ct state new tcp dport $port_vanisher_forward counter jump VANISHER comment "forward6_TCP_VANISHER"
        #iifname $iface_vanisher_forward ip6 daddr $addr6_vanisher_forward ct state new udp dport $port_vanisher_forward counter jump VANISHER comment "forward6_UDP_VANISHER"


		# footers
		counter jump TRASH comment "forward_TRASH"
		counter comment "forward_COUNT"
	}

	#
	# OUTPUT
	#

	chain OUTPUT {

		# headers
		#type filter hook output priority filter; policy drop;
		type filter hook output priority filter;
		ct state established,related counter accept comment "output_RELATED"
		oifname "lo" counter accept
		ct state invalid counter jump INVALID comment "output_INVALID"
		ip protocol icmp counter jump DEBUG comment "output4_ICMP"
		ip6 daddr fe80::/10 counter accept comment "output6_LL"
        ip6 nexthdr ipv6-icmp counter jump DEBUG comment "output6_ICMP"


		# basics
		ip protocol igmp counter accept comment "output_IGMP"


		# main
		oifname $iface_vanisher counter accept comment "output_VANISHER"
		oifname $iface_tunnel counter accept comment "output_TUNNEL"
		oifname $iface_vpn_nbux counter accept comment "output_VPN"
		ip protocol tcp counter accept comment "output4_TCP"
		ip protocol udp counter accept comment "output4_UDP"
 		ip6 nexthdr tcp counter accept comment "output6_TCP"
        ip6 nexthdr udp counter accept comment "output6_UDP"

		# footers

		counter jump LOGACCEPT comment "output_ACCEPT"
		counter comment "output_COUNT"
	}


	#
	# Logging chains
	#


	chain LOGACCEPT {
		log prefix "netfilter:filter_ACCEPT" group 0
		counter accept
	}

	chain TRUSTED_CONT {
		log prefix "netfilter:filter_TRUSTED@" group 0
		counter continue
	}

	chain DEBUG {
		#log prefix "netfilter:filter_DEBUG" group 0
		counter accept
	}

	chain LOGDROP {
		log prefix "netfilter:filter_DROP" group 0
		counter drop
	}

	chain INVALID {
		log prefix "netfilter:filter_INVALID" group 0
		counter drop
	}

	chain TRASH {
		log prefix "netfilter:filter_TRASH" group 0
		counter drop
	}

	chain LAN {
		log prefix "netfilter:filter_LAN" group 0
		counter accept
	}

	chain WAN {
		log prefix "netfilter:filter_WAN" group 0
		counter accept
	}

	chain GUEST {
		log prefix "netfilter:filter_GUEST" group 0
		counter accept
	}

	chain MANAGE {
		log prefix "netfilter:filter_MANAGE" group 0
		counter accept
	}

	chain DOMO {
		log prefix "netfilter:filter_DOMO" group 0
		counter accept
	}

	chain VANISHER {
		log prefix "netfilter:filter_VANISHER" group 0
		counter accept
	}

	chain TUNNEL {
		log prefix "netfilter:filter_TUNNEL" group 0
		counter accept
	}

	chain VPN {
		log prefix "netfilter:filter_VPN" group 0
		counter accept
	}

	chain LINK {
		#log prefix "netfilter:filter_LINK" group 0
        counter accept
    }

}
```


## protect table: DDoS, scan, brute-force and live dynamic defense

This is the most interesting file.

The `protect` table is a dedicated security layer using early priorities:

```text
PREROUTING priority -305
INPUT/FORWARD/OUTPUT priority -5
```

The warning in the file is there for a reason: changing priorities changes packet chronology.

The table defines dynamic sets and meters for:

- DDoS-like UDP packet floods;
- suspicious TCP SYN/MSS behavior;
- new-flow rate abuse;
- connection-count abuse;
- source-network DDoS buckets;
- scan rates;
- scan connection counts;
- brute-force connection counts;
- brute-force rates;
- blacklists;
- live drop lists;
- trusted bypasses;
- spoof/martian filtering.

The key pattern is repeated many times:

```text
meter condition
→ update dynamic set with timeout
→ jump to logging/drop chain
```

This means the firewall is not just statically filtering. It is learning short-term abuse and making subsequent drops cheaper.

This file is the grumpy bouncer of the ruleset.

### Source: `protect.inc`

```nft
#!/usr/sbin/nft -f

#
# Filter NFT definition
#


#
# WARNING : DO NOT CHANGE PRIORITY (-5 for input/forward/output and -305 for prerouting ) !!!
#



table inet protect {

	#
	# Sets
	#

	set TRUSTED4 {
		type ipv4_addr
		size 131072
		flags interval
		elements = { $addr_trusted }
	}

	set BRUTE4 {
		type ipv4_addr
		#flags interval, timeout
		flags timeout
		size 131072
		gc-interval 10m 
		#auto-merge
	}

	set SCAN4 {
		type ipv4_addr
		#flags interval, timeout
		flags timeout
		size 131072
		gc-interval 10m
		#auto-merge
	}

	set DDOS4 {
		type ipv4_addr
		#flags interval, timeout
		flags timeout
		size 131072
		gc-interval 10m
		#auto-merge
	}

	set BLACKLIST4 {
		type ipv4_addr
		size 131072
		flags interval
		#auto-merge
		#elements = {  }
	}

	set LIVEDROP4 {
		type ipv4_addr
		#flags interval, timeout
		flags timeout
		size 131072
		gc-interval 10m
		#auto-merge
		#elements = {  }
	}

	#set GEODROP4 {
		#include "/etc/nft.d/geodrop/*4.nft"
		#type ipv4_addr
		#flags interval
		#auto-merge
		##just be sure that files exist and geodrop is defined
		#elements = { $geodrop }
		#}


	set TRUSTED6 {
		type ipv6_addr
		size 131072
		flags interval
		elements = { $addr6_trusted }
	}

    set BRUTE6 {
        type ipv6_addr
        #flags interval, timeout
        flags timeout
        size 131072
        gc-interval 10m
        #auto-merge
    }

    set SCAN6 {
        type ipv6_addr
        #flags interval, timeout
        flags timeout
        size 131072
        gc-interval 10m
        #auto-merge
    }

    set DDOS6 {
        type ipv6_addr
        #flags interval, timeout
        flags timeout
        size 131072
        gc-interval 10m
        #auto-merge
    }

	set DDOSNET4 {
  		type ipv4_addr;
  		flags timeout;
  		size 131072;
  		gc-interval 10m;
	}

	set DDOSNET6 {
  		type ipv6_addr;
  		flags timeout;
  		size 131072;
  		gc-interval 10m;
	}

    set BLACKLIST6 {
        type ipv6_addr
		size 131072
		flags interval
		#auto-merge
        #elements = {  }
    }

    set LIVEDROP6 {
        type ipv6_addr
        #flags interval, timeout
        flags timeout
        size 131072
        gc-interval 10m
        #auto-merge
    }

    #set GEODROP6 {
        #include "/etc/nft.d/geodrop/*6.nft"
        #type ipv6_addr
        #flags interval
        #auto-merge
        ##just be sure that files exist and geodrop is defined
        #elements = { $geodrop }
        #}


#
# TYPICAL WAN PROTECTION
#
	chain PROTECT {
		ct state new,untracked counter jump PROTECT_CONT comment "protect-log"

		# NOTE : DO NOT FORGET TO COPY (@DDOS / @DDOSNET) SETS TO NETDEV

		# ipv4
		ct state new,untracked udp length <= 32 																		meter ddos4-udp		size 65535 { ip saddr timeout 15m limit rate over 20/minute burst 20 packets } counter update @DDOS4 { ip saddr timeout 24h } jump DDOS_ADD comment "protect-DDOS4U+_#protect"
		ct state new,untracked tcp flags syn tcp option maxseg size 0-88 												meter ddos4-tcp		size 65535 { ip saddr timeout 15m limit rate over 20/minute burst 20 packets } counter update @DDOS4 { ip saddr timeout 24h } jump DDOS_ADD comment "protect-DDOS4T+_#protect"
        ct state new,untracked																							meter ddos4-rate 	size 65535 { ip saddr timeout 15m limit rate over 60/minute burst 60 packets } counter update @DDOS4 { ip saddr timeout 24h } jump DDOS_ADD comment "protect-DDOS4R+_#protect"
        ct state new,untracked 																							meter ddos4-count 	size 65535 { ip saddr ct count over 100 } update @DDOS4 { ip saddr timeout 24h } counter jump DDOS_ADD comment "protect-DDOS4C+_#protect"
		ct state new,untracked ip protocol { tcp, udp } th dport { $port_scan_wan } th sport != { 1-2048 }				meter ddos4-net		size 65535 { (ip saddr & 255.255.255.0) timeout 10m limit rate over 200/second burst 800 packets } update @DDOSNET4 { (ip saddr & 255.255.255.0) timeout 2h } counter jump DDOS_ADD comment "protect-DDOS4N+_#protect"
		ct state new,untracked ip protocol { tcp, udp } th dport { $port_scan_wan } th sport != { 1-2048 } 				meter scan4-rate1 	size 32768 { ip saddr timeout 2h limit rate over 5/hour } counter update @SCAN4 { ip saddr timeout 12h } jump SCAN_ADD comment "protect-SCAN4R1+_#protect"
		ct state new,untracked tcp flags & (syn | ack) == syn tcp dport { $port_svc_vpn }  								meter scan4-rate2 	size 32768 { ip saddr timeout 6h limit rate over 30/hour burst 30 packets } update @SCAN4 { ip saddr timeout 12h } counter jump SCAN_ADD comment "protect-SCAN4R2+_#protect"
		ct state new,untracked ip protocol { tcp, udp } th dport != { $port_allow_wan } th sport != { 1-2048 }			meter scan4-rate3 	size 32768 { ip saddr timeout 3h limit rate over 15/hour } counter update @SCAN4 { ip saddr timeout 12h } jump SCAN_ADD comment "protect-SCAN4R3+_#protect"
		ct state new,untracked tcp flags & (syn | ack) == syn tcp dport { $port_allow_wan }  							meter scan4-rate4 	size 32768 { ip saddr timeout 10m limit rate over 45/minute burst 45 packets } update @SCAN4 { ip saddr timeout 3h } counter jump SCAN_ADD comment "protect-SCAN4R4+_#protect"
		ct state new,untracked ip protocol { tcp, udp } th dport != { $port_allow_wan } th sport != { 1-2048 }			meter scan4-count1 	size 32768 { ip saddr ct count over 15 } counter update @SCAN4 { ip saddr timeout 3h } jump SCAN_ADD comment "protect-SCAN4C1+_#protect"
		ct state new,untracked tcp flags & (syn | ack) == syn th dport != { $port_allow_wan } th sport != { 1-2048 } 	meter scan4-count2 	size 32768 { ip saddr ct count over 15 } counter update @SCAN4 { ip saddr timeout 3h } jump SCAN_ADD comment "protect-SCAN4C2+_#protect"
        ct state new,untracked tcp dport { $port_brute_wan } 															meter brute4-count 	size 16384 { ip saddr ct count over 3 } update @BRUTE4 { ip saddr timeout 24h } counter jump BRUTE_ADD comment "protect-BRUTE4C+_#protect"
        ct state new,untracked tcp dport { $port_brute_wan } 															meter brute4-rate 	size 16384 { ip saddr timeout 6h limit rate over 4/minute burst 6 packets } update @BRUTE4 { ip saddr timeout 24h } counter jump BRUTE_ADD comment "protect-BRUTE4R+_#protect"


		# ipv6

		ct state new,untracked udp length <= 32																			meter ddos6-udp 	size 65535 { ip6 saddr timeout 15m limit rate over 20/minute burst 20 packets } counter update @DDOS6 { ip6 saddr timeout 24h } jump DDOS_ADD comment "protect-DDOS6U+_#protect"
		ct state new,untracked tcp flags syn tcp option maxseg size 0-88 												meter ddos6-tcp 	size 65535 { ip6 saddr timeout 15m limit rate over 20/minute burst 20 packets } counter update @DDOS6 { ip6 saddr timeout 24h } jump DDOS_ADD comment "protect-DDOS6T+_#protect"
        ct state new,untracked																							meter ddos6-rate 	size 65535 { ip6 saddr timeout 15m limit rate over 60/minute burst 60 packets } counter update @DDOS6 { ip6 saddr timeout 24h } jump DDOS_ADD comment "protect-DDOS6R+_#protect"
        ct state new,untracked 																							meter ddos6-count 	size 65535 { ip6 saddr ct count over 100 } update @DDOS6 { ip6 saddr timeout 24h } counter jump DDOS_ADD comment "protect-DDOS6C+_#protect"
		ct state new,untracked ip6 nexthdr { tcp, udp } th dport { $port_scan_wan }	th sport != { 1-2048 }				meter ddos6-net		size 65535 { (ip6 saddr & ffff:ffff:ffff:ffff::) timeout 10m limit rate over 300/second burst 1200 packets } update @DDOSNET6 { (ip6 saddr & ffff:ffff:ffff:ffff::) timeout 2h } counter jump DDOS_ADD comment "protect-DDOS6N+_#protect"
		ct state new,untracked ip6 nexthdr { tcp, udp } th dport { $port_scan_wan } th sport != { 1-2048 }				meter scan6-rate1 	size 32768 { ip6 saddr timeout 2h limit rate over 5/hour } counter update @SCAN6 { ip6 saddr timeout 12h } jump SCAN_ADD comment "protect-SCAN6R1+_#protect"
		ct state new,untracked tcp flags & (syn | ack) == syn tcp dport { $port_svc_vpn  }   							meter scan6-rate2 	size 32768 { ip6 saddr timeout 6h limit rate over 30/hour burst 30 packets } update @SCAN6 { ip6 saddr timeout 12h } counter jump SCAN_ADD comment "protect-SCAN6R2+_#protect"
        ct state new,untracked ip6 nexthdr { tcp, udp } th dport != { $port_allow_wan } th sport != { 1-2048 }			meter scan6-rate3 	size 32768 { ip6 saddr timeout 3h limit rate over 15/hour } counter update @SCAN6 { ip6 saddr timeout 12h } jump SCAN_ADD comment "protect-SCAN6R3+_#protect"
		ct state new,untracked tcp flags & (syn | ack) == syn tcp dport { $port_allow_wan }   							meter scan6-rate4 	size 32768 { ip6 saddr timeout 10m limit rate over 45/minute burst 45 packets } update @SCAN6 { ip6 saddr timeout 3h } counter jump SCAN_ADD comment "protect-SCAN6R4+_#protect"
		ct state new,untracked ip6 nexthdr { tcp, udp } th dport != { $port_allow_wan } th sport != { 1-2048 }			meter scan6-count1 	size 32768 { ip6 saddr ct count over 15 } counter update @SCAN6 { ip6 saddr timeout 3h } jump SCAN_ADD comment "protect-SCAN6C1+_#protect"
		ct state new,untracked tcp flags & (syn | ack) == syn th dport != { $port_allow_wan } th sport != { 1-2048 }	meter scan6-count2 	size 32768 { ip6 saddr ct count over 15 } counter update @SCAN6 { ip6 saddr timeout 3h } jump SCAN_ADD comment "protect-SCAN6C2+_#protect"
        ct state new,untracked tcp dport { $port_brute_wan } 															meter brute6-count 	size 16384 { ip6 saddr ct count over 3 } update @BRUTE6 { ip6 saddr timeout 24h } counter jump BRUTE_ADD comment "protect-BRUTE6C+_#protect"
        ct state new,untracked tcp dport { $port_brute_wan } 															meter brute6-rate 	size 16384 { ip6 saddr timeout 6h limit rate over 4/minute burst 6 packets } update @BRUTE6 { ip6 saddr timeout 24h } counter jump BRUTE_ADD comment "protect-BRUTE6R+_#protect"
	}



#
# INPUT
#

	chain INPUT {

		# headers
		#type filter hook input priority filter - 5;
		type filter hook input priority -5;
 		# ISP - DO NOT REMOVE
        iifname $iface_wan ip6 saddr fe80::/10 udp dport 547 th sport 546 counter jump LINK comment "protect-input6_dhclient_ISP_WAN"
        iifname $iface_wan ip6 saddr fe80::/10 ip6 nexthdr ipv6-icmp counter jump LINK comment "protect-input6_ICMP_ISP_WAN"
		iifname { $iface_wan, $iface_private_wan } ip6 saddr fe80::/10 ip6 nexthdr ipv6-icmp icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, mld-listener-reduction, mld-listener-query, mld-listener-report, mld2-listener-report, mld-listener-done } counter jump LINK comment "protect-input6_NDMLD_WAN"
		iifname { $iface_wan, $iface_private_wan } ip saddr $addr_private meta l4proto icmp icmp type echo-request counter jump LINK comment "protect-input4_ICMP_PRV_WAN"
		ct state established,related counter accept comment "protect-input_RELATED"
		iifname "lo" counter accept
		ct state invalid counter jump INVALID comment "protect-input_INVALID"

		# DDOS (already in PREROUTING - except ICMP)
		#iifname $iface_wan ip saddr @DDOS4 counter jump DDOS comment "protect-input4_DDOS_WAN_#protect"
		#iifname $iface_wan (ip saddr & 255.255.255.0) @DDOSNET4 counter jump DDOS comment "protect-input4_DDOSNET_WAN_#protect"
		#iifname $iface_wan ip6 saddr @DDOS6 counter jump DDOS comment "protect-input6_DDOS_WAN_#protect"
		#iifname $iface_wan (ip6 saddr & ffff:ffff:ffff:ffff::) @DDOSNET6 counter jump DDOS comment "protect-input6_DDOSNET_WAN_#protect"
		iifname $iface_wan meta l4proto icmp icmp type echo-request limit rate over 10/second burst 8 packets counter jump DDOS comment "protect-input4_DDOS_icmp_WAN_#protect"
		iifname $iface_wan meta l4proto ipv6-icmp icmpv6 type echo-request limit rate over 10/second burst 8 packets counter jump DDOS comment "protect-input6_DDOS_icmp_WAN_#protect"

		# basics
		iifname $iface_private_wan ip saddr { $addr_private_wan } counter accept comment "protect-input4_PRVWAN"
		ip protocol icmp counter jump DEBUG comment "protect-input4_ICMP"
		iifname $iface_private_wan ip6 saddr { $addr6_private_wan } counter accept comment "protect-input6_PRVWAN"
		meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, echo-request } counter jump DEBUG comment "protect-input6_typed_ICMP"

		## protect sets
		iifname $iface_wan ct state new,untracked counter jump WAN_CONT comment "protect-input_log_WAN"

		iifname $iface_wan ct state new,untracked ip saddr @TRUSTED4 counter accept comment "protect-input4_TRUSTED_WAN"
		iifname $iface_wan ct state new,untracked ip6 saddr @TRUSTED6 counter accept comment "protect-input6_TRUSTED_WAN"
		iifname $iface_wan ct state new,untracked counter jump PROTECT comment "protect-input_WAN"

		counter comment "protect-input_COUNT"
	}


	#
	# FORWARD
	# 

	#
	# FASTPATH
	# NOTE : since kernel 6.19.x flowtable (offloading) must contain physical interfaces
	#

	flowtable fastpath {
	   hook ingress priority filter; devices = { $iface_offload };
	   counter;
	}

	chain FORWARD {

		# headers
		#type filter hook forward priority filter - 5; 
		type filter hook forward priority -5; 
		ct state established meta l4proto { tcp, udp } flow offload @fastpath counter comment "protect-forward_FASTPATH"
		ct state established,related counter accept comment "protect-forward_RELATED"
		iifname "lo" counter accept
		# torelate from LAN to WAN : FIN+ACK or RST+ACK INVALID
		iifname { $iface_private } oifname { $iface_wan } tcp dport { 80, 443, 993 } tcp flags & (fin|ack|rst) == (fin|ack) ct state invalid limit rate 10/second burst 20 packets counter accept comment "protect-forward_silent1_INVALID_PRV_WAN"
		iifname { $iface_private } oifname { $iface_wan } tcp dport { 80, 443, 993 } tcp flags & (fin|ack|rst) == (rst|ack) ct state invalid limit rate 10/second burst 20 packets counter accept comment "protect-forward_silent2_INVALID_PRV_WAN"
		iifname { $iface_private } ct state invalid counter jump INVALID comment "protect-forward_INVALID_PRV"
		ct state invalid counter jump INVALID comment "protect-forward_INVALID"
		ip6 saddr fe80::/10 meta l4proto ipv6-icmp icmpv6 type { mld-listener-query, mld-listener-report, mld-listener-reduction, mld2-listener-report } counter jump DEBUG comment "protect-forward6_LL_ICMP"
		ip6 saddr fe80::/10 ip6 daddr fe80::/10 counter jump DEBUG comment "protect-forward6_LL"
		iifname { $iface_wan, $iface_private_wan } ip saddr $addr_private meta l4proto icmp icmp type echo-request counter jump DEBUG comment "protect-forward4_ICMP_PRV_WAN"

		# DDOS (already in PREROUTING - except ICMP and output)
		#iifname $iface_wan ip saddr @DDOS4 counter jump DDOS comment "protect-forward4_DDOS_WAN_#protect"
		#iifname $iface_wan (ip saddr & 255.255.255.0) @DDOSNET4 counter jump DDOS comment "protect-forward4_DDOSNET_WAN_#protect"
		#iifname $iface_wan ip6 saddr @DDOS6 counter jump DDOS comment "protect-forward6_DDOS_WAN_#protect"
		#iifname $iface_wan (ip6 saddr & ffff:ffff:ffff:ffff::) @DDOSNET6 counter jump DDOS comment "protect-forward6_DDOSNET_WAN_#protect"
		oifname $iface_wan ip daddr @DDOS4 counter jump DDOS comment "protect-forward4_DDOS_out_WAN_#protect"
		oifname $iface_wan ip6 daddr @DDOS6 counter jump DDOS comment "protect-forward6_DDOS_out_WAN_#protect"
		iifname $iface_wan meta l4proto icmp icmp type echo-request limit rate over 10/second burst 8 packets counter jump DDOS comment "protect-forward4_DDOS_icmp_WAN_#protect"
        iifname $iface_wan meta l4proto ipv6-icmp icmpv6 type echo-request limit rate over 10/second burst 8 packets counter jump DDOS comment "protect-forward6_DDOS_icmp_WAN_#protect"

		# basics
		iifname $iface_private_wan ip saddr { $addr_private_wan } counter accept comment "protect-forward4_PRVWAN"
		ip protocol icmp counter jump DEBUG comment "protect-forward4_ICMP"
		iifname $iface_private_wan ip6 saddr { $addr6_private_wan } counter accept comment "protect-forward6_PRVWAN"
        meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request } counter jump DEBUG comment "protect-forward6_typed_ICMP"


		## protect sets
		iifname $iface_wan ct state new,untracked counter jump WAN_CONT comment "protect-forward_log_WAN"

		iifname $iface_wan ct state new,untracked ip saddr @TRUSTED4 counter accept comment "protect-forward4_TRUSTED_WAN"
        iifname $iface_wan ct state new,untracked ip6 saddr @TRUSTED6 counter accept comment "protect-forward6_TRUSTED_WAN"
		iifname $iface_wan ct state new,untracked ip daddr $addr_svc_aurora_vanisher udp sport $port_svc_aurora_vanisher counter accept comment "protect-forward4_aurora_vanisher_WAN"
		iifname $iface_wan ct state new,untracked ip6 daddr $addr6_svc_aurora_vanisher udp sport $port_svc_aurora_vanisher counter accept comment "protect-forward6_aurora_vanisher_WAN"
		iifname $iface_wan ct state new,untracked counter jump PROTECT comment "protect-forward_WAN"

		counter comment "protect-forward_COUNT"
	}

	#
	# OUTPUT
	#

	chain OUTPUT {

		# headers
		#type filter hook output priority filter - 5;
		type filter hook output priority -5 ;
		ct state established,related counter accept comment "protect-output_RELATED"
		oifname "lo" counter accept
		ct state invalid counter jump INVALID comment "protect-output_INVALID"

		# DDOS (amplification)
		oifname $iface_wan ip daddr @DDOS4 counter jump DDOS comment "protect-output4_DDOS_WAN_#protect"
		oifname $iface_wan ip6 daddr @DDOS6 counter jump DDOS comment "protect-output6_DDOS_WAN_#protect"

		# basics
		ip protocol icmp counter jump DEBUG comment "protect-output4_ICMP"
        ip6 nexthdr ipv6-icmp counter jump DEBUG comment "protect-output6_ICMP"

		counter comment "protect-output_COUNT"
	}



	#
	# PREROUTING
	#
	chain PREROUTING {

		# headers
		#type filter hook prerouting priority raw - 5;
		type filter hook prerouting priority -305;
		iifname "lo" counter accept

		# DDOS
		iifname $iface_wan (ip saddr & 255.255.255.0) @DDOSNET4 counter jump DDOS comment "protect-prerouting4_DDOSNET_WAN_#protect"
		iifname $iface_wan ip saddr @DDOS4 counter jump DDOS comment "protect-prerouting4_DDOS_WAN_#protect"
		iifname $iface_wan (ip6 saddr & ffff:ffff:ffff:ffff::) @DDOSNET6 counter jump DDOS comment "protect-prerouting6_DDOSNET_WAN_#protect"
		iifname $iface_wan ip6 saddr @DDOS6 counter jump DDOS comment "protect-prerouting6_DDOS_WAN_#protect"
		iifname $iface_wan ip saddr != { $addr_private } meta l4proto icmp icmp type echo-request limit rate over 10/second burst 8 packets counter jump DDOS comment "protect-prerouting4_DDOS_icmp_WAN_#protect"
		iifname $iface_wan ip6 saddr != { fe80::/10 } meta l4proto ipv6-icmp icmpv6 type echo-request limit rate over 10/second burst 8 packets counter jump DDOS comment "protect-prerouting6_DDOS_icmp_WAN_#protect"

		# stateless FLAGS (already in netdev ingress)
		#iifname $iface_wan meta l4proto tcp tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0 counter jump FLAG comment "protect-prerouting_NULL_WAN_#protect" 
		#iifname $iface_wan meta l4proto tcp tcp flags & (fin|syn|rst|psh|ack|urg) == (fin|psh|urg) counter jump FLAG comment "protect-prerouting_XMAS_WAN_#protect"
		#iifname $iface_wan meta l4proto tcp tcp flags & (syn|fin) == (syn|fin) counter jump FLAG comment "protect-prerouting_SYNFIN_WAN_#protect"
		#iifname $iface_wan meta l4proto tcp tcp flags & (syn|rst) == (syn|rst) counter jump FLAG comment "protect-prerouting_SYNRST_WAN_#protect"
		#iifname $iface_wan meta l4proto tcp tcp dport 0 counter jump FLAG comment "protect-prerouting_TCP0_WAN_#protect"

		# statefull FLAGS 
		iifname $iface_wan ct state new,untracked meta l4proto tcp tcp flags & (fin|syn|rst|ack) != syn counter jump FLAG comment "protect-prerouting_NEWnotSYN_WAN_#protect"
		iifname $iface_wan ct state new,untracked meta l4proto tcp tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0 counter jump FLAG comment "protect-prerouting_ct_NULL_WAN_#protect" 
		iifname $iface_wan ct state new,untracked meta l4proto tcp tcp flags & (fin|syn|rst|psh|ack|urg) == (fin|psh|urg) counter jump FLAG comment "protect-prerouting_ct_XMAS_WAN_#protect"

		# VPN allow (before OTHERS and after DDOS)
		iifname $iface_wan ct state new,untracked ip protocol { tcp, udp } th dport { $port_svc_vpn } counter jump VPN comment "protect-prerouting4_vpn_WAN"
		iifname $iface_wan ct state new,untracked ip6 nexthdr { tcp, udp } th dport { $port_svc_vpn } counter jump VPN comment "protect-prerouting6_vpn_WAN"

		# OTHERS drop (except TRUSTED before BLACKLIST,GEODROP,LIVEDROP but after SCAN,BRUTE) 
		iifname $iface_wan ip saddr @SCAN4 counter jump SCAN comment "protect-prerouting4_SCAN_WAN_#protect"
		iifname $iface_wan ip saddr @BRUTE4 counter jump BRUTE comment "protect-prerouting4_BRUTE_WAN_#protect"
		iifname $iface_wan ip saddr @TRUSTED4 counter accept comment "protect-prerouting4_TRUSTED_WAN"
		iifname $iface_wan ip saddr @BLACKLIST4 counter jump BLACKLIST comment "protect-prerouting4_BLACKLIST_WAN_#protect"
		#iifname $iface_wan ip saddr @GEODROP4 counter jump GEODROP comment "protect-prerouting4_GEODROP_WAN_#protect"
		iifname $iface_wan ip saddr @LIVEDROP4 counter jump LIVEDROP comment "protect-prerouting4_LIVEDROP_WAN_#protect"
		iifname $iface_wan ip6 saddr @SCAN6 counter jump SCAN comment "protect-prerouting6_SCAN_WAN_#protect"
		iifname $iface_wan ip6 saddr @BRUTE6 counter jump BRUTE comment "protect-prerouting6_BRUTE_WAN_#protect"
		iifname $iface_wan ip6 saddr @TRUSTED6 counter accept comment "protect-prerouting6_TRUSTED_WAN"
		iifname $iface_wan ip6 saddr @BLACKLIST6 counter jump BLACKLIST comment "protect-prerouting6_BLACKLIST_WAN_#protect"
        #iifname $iface_wan ip6 saddr @GEODROP6 counter jump GEODROP comment "protect-prerouting6_GEODROP_WAN_#protect"
        iifname $iface_wan ip6 saddr @LIVEDROP6 counter jump LIVEDROP comment "protect-prerouting6_LIVEDROP_WAN_#protect"

		# basics
		iifname { $iface_private } ip daddr 255.255.255.255 udp dport { 67, 68 } counter accept comment "protect-prerouting4_dhcpd_PRV"
		iifname { $iface_private } ip daddr { 224.0.0.0/3, 239.255.255.250, 255.255.255.255 } counter accept comment "protect-prerouting4_mbcast_PRV"
		iifname { $iface_vpn_nbux } ip daddr { 224.0.0.0/3, 239.255.255.250, 255.255.255.255 } counter drop comment "protect-prerouting4_mbcast_VPN"
		iifname { $iface_wan, $iface_private_wan } ip daddr { 224.0.0.0/3, 239.255.255.250, 255.255.255.255 } counter drop comment "protect-prerouting4_mbcast_PRVWAN"
		iifname { $iface_private } ip protocol igmp counter accept comment "protect-prerouting4_igmp_PRV"
		iifname { $iface_private_wan } ip saddr { $addr_private_wan } counter accept comment "protect-prerouting4_PRVWAN"
		ip saddr { 240.0.0.0/4, 203.0.113.0/24, 198.51.100.0/24, 192.0.0.0/24, 192.0.2.0/24, 127.0.0.0/8, 224.0.0.0/4, 0.0.0.0/8 } counter jump SPOOF comment "protect-prerouting4_spoof_BOGON_src_#protect"
		ip daddr { 240.0.0.0/4, 203.0.113.0/24, 198.51.100.0/24, 192.0.0.0/24, 192.0.2.0/24, 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } counter jump SPOOF comment "protect-prerouting4_spoof_BOGON_dst_#protect"
		iifname { $iface_tunnel } ip saddr { $addr_tunnel } counter jump TUNNEL comment "protect-prerouting4_TUNNEL"
		iifname { $iface_vpn_nbux, $iface_private } ip saddr != { $addr_vpn_nbux, $addr_private, 169.254.0.0/16 } counter jump SPOOF comment "protect-prerouting4_spoof_PRIVATE_#protect"
		iifname $iface_wan ip saddr $addr_wan_martians counter jump SPOOF comment "protect-prerouting4_spoof_MARTIANS_WAN_#protect"
		icmp type echo-request counter accept comment "protect-prerouting4_ICMP"

		iifname { $iface_private } ip6 daddr { ff00::/8, ff02::/16 } counter accept comment "protect-prerouting6_MCAST_PRV"
		iifname != { $iface_private } ip6 saddr fe80::/10 ip6 nexthdr ipv6-icmp icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, mld-listener-reduction, mld-listener-query, mld-listener-report, mld2-listener-report, mld-listener-done } counter accept comment "protect-prerouting6_NDMLD_NOTPRV"
        iifname != { $iface_private } ip6 daddr { ff00::/8, ff02::/16 } counter drop comment "protect-prerouting6_MCAST_NOTPRV"
        iifname { $iface_private_wan } ip6 saddr { $addr6_private_wan } counter accept comment "protect-prerouting6_PRVWAN"
		ip6 saddr { 2001::/23, ::255.0.0.0/104, ::/104, ::127.0.0.0/104, ::224.0.0.0/100, 3ffe::/16, 2001:10::/28, 2001:db8::/32, ::/96, ::ffff:0:0/96, fec0::/10, ::1, ::  } counter jump SPOOF comment "protect-prerouting6_spoof_BOGON_src_#protect"
		ip6 daddr { 2001::/23, ::255.0.0.0/104, ::/104, ::127.0.0.0/104, ::224.0.0.0/100, 3ffe::/16, 2001:10::/28, 2001:db8::/32, ::/96, ::ffff:0:0/96, fec0::/10, ::1, ::  } counter jump SPOOF comment "protect-prerouting6_spoof_BOGON_dst_#protect"
		iifname { $iface_tunnel } ip6 saddr { $addr6_tunnel } counter jump TUNNEL comment "protect-prerouting6_TUNNEL"
        iifname { $iface_vpn_nbux, $iface_private } ip6 saddr != { $addr6_vpn_nbux, $addr6_private, fe80::/16 } counter jump SPOOF comment "protect-prerouting6_spoof_PRIVATE_#protect"
		iifname != { $iface_vpn_nbux, $iface_private } ip6 daddr ff00::/8 counter jump SPOOF comment "protect-prerouting6_spoof_ULA_#protect"
        iifname $iface_wan ip6 saddr $addr6_wan_martians counter jump SPOOF comment "protect-prerouting6_spoof_MARTIANS_WAN_#protect"
        ip6 nexthdr ipv6-icmp counter accept comment "protect-prerouting6_ICMP"

		counter comment "protect-prerouting_COUNT"

	}



	#
	# Logging chains
	#

    chain LINK {
        log prefix "netfilter:protect_LINK" group 0
        counter accept
    }

	chain DEBUG {
		#log prefix "netfilter:protect_DEBUG" group 0
		counter accept
	}

	chain VPN {
		log prefix "netfilter:protect_VPN" group 0
		counter accept
	}

	chain INVALID {
		log prefix "netfilter:protect_INVALID" group 0
		counter drop
	}

	chain TUNNEL {
		#log prefix "netfilter:protect_TUNNEL" group 0
		counter accept
	}

	chain BRUTE {
		log prefix "netfilter:protect_BRUTE" group 0
		counter drop
	}

	chain BRUTE_ADD {
		log prefix "netfilter:protect_BRUTE+" group 0
		counter drop
	}

	chain SCAN {
		log prefix "netfilter:protect_SCAN" group 0
		counter drop
	}

	chain SCAN_ADD {
		log prefix "netfilter:protect_SCAN+" group 0
		counter drop
	}

	chain DDOS {
		#log prefix "netfilter:protect_DDOS" group 0
		limit rate 10/minute log prefix "netfilter:protect_DDOS" group 0
		counter drop
	}

	chain DDOS_ADD {
		log prefix "netfilter:protect_DDOS+" group 0
		counter drop
	}

	chain BLACKLIST {
		log prefix "netfilter:protect_BLACKLIST" group 0
		counter drop
	}

	chain SPOOF {
		log prefix "netfilter:protect_SPOOF" group 0
		counter drop
	}

	chain FLAG {
		log prefix "netfilter:protect_FLAG" group 0
		counter drop
	}

	chain GEODROP {
		log prefix "netfilter:protect_GEODROP" group 0
		counter drop
	}

	chain LIVEDROP {
		log prefix "netfilter:protect_LIVEDROP" group 0
		counter drop
	}

	chain WAN_CONT {
		#log prefix "netfilter:protect_WAN@" group 0
		#limit rate 30/minute log prefix "netfilter:protect_WAN@" group 0
		counter continue
	}

	chain PROTECT_CONT {
		#log prefix "netfilter:protect_PROTECT@" group 0
		#limit rate 30/minute log prefix "netfilter:protect_PROTECT@" group 0
		counter continue
	}


}
```


## dynamic set persistence helper

Dynamic nftables sets normally disappear when the ruleset is flushed.

This helper defines which sets are dumped and reloaded so runtime state survives firewall reloads.

That gives a useful operational model:

```text
runtime learning
plain nftables sets
reload-safe persistence
no database
no daemon
```

Small, pragmatic, and pleasingly Unix-shaped.

### Source: `set.pre`

```sh
#!/bin/sh
# dump target to files (to be included when reload)
#
INCPATH="/etc/nft.d"
INCPREFIX="set"
#TARGETS="filter:SCAN filter:BRUTE filter:DDOS raw:LIVEDROP protect:SCAN protect:DDOS protect:BRUTE protect:LIVEDROP"
TARGETS="protect:SCAN4 protect:DDOS4 protect:DDOSNET4 protect:BRUTE4 protect:LIVEDROP4 protect:BLACKLIST4 protect:SCAN6 protect:DDOS6 protect:DDOSNET6 protect:BRUTE6 protect:LIVEDROP6 protect:BLACKLIST6"
FAMILY="inet"
COMMENT="generated $0 at `date`"


for t in $TARGETS ; do
	table=`echo "$t" | cut -d: -f1`
	target=`echo "$t" | cut -d: -f2`
	prefix="pre-${target}@${table}"

	for fam in $FAMILY ; do
		echo "$prefix INFO : generating family:${fam} table:${table} target:${target} (nft list set $fam $table $target)"
		inc="${INCPATH}/${INCPREFIX}-${fam}-${table}-${target}.inc"

		# test existence
		nft_curr=`nft list set $fam $table $target 2>/dev/null | grep "elements =" 2>/dev/null`
		inc_curr=""
		[ -e "$inc" ] && inc_curr=`grep "elements =" "$inc" 2>/dev/null`
		if [ -z "$nft_curr" ] && [ -z "$inc_curr" ] ; then
				echo "$prefix INFO : nft and $inc are empty (init?)"
				#echo -e "# INIT ${COMMENT}\ntable $fam $table {\n set $target {\n typeof ip saddr\nsize 131072\nflags dynamic,timeout\ngc-interval 10m\n }\n }" > "$inc"
				echo -e "# INIT ${COMMENT}" > "$inc"
				continue
		else
				if [ ! -z "$nft_curr" ] ; then
						[ ! -z "$inc_curr" ] && echo "$prefix INFO : nft and $inc both already contain some elements, updating from current nft set $fam $table $target"
						echo "# DUMP ${COMMENT}" > "$inc"
						nft list set $fam $table $target >> "$inc"
						if [ $? -eq 0 ] ; then
								echo "$prefix INFO : $inc dump successfull"
						else
								echo "$prefix ERROR : $inc dump FAILED !"
								cp "$inc" "${inc}.bad"
								echo > "$inc"
						fi
				else
						echo "$prefix INFO : current nft set $fam $table $target do not contain any elements (start?)"
				fi
		fi
	done
done
```


## interface boot helper

This helper deals with interface-side boot-time behavior around the firewall environment.

It belongs in the documentation because firewalls are not only rules. They are also load order, interfaces, link state and the unpleasant reality that packets can arrive before the setup is emotionally ready.

### Source: `iface.boot`

```sh
#!/bin/sh
# create interfaces (mandatory for some nftables check - netdev, offloads)
# some tuning params
#
#
IFACE="mlkw0 nbux0 tun0 tun1 vanisher0"
COMMENT="generated $0 at `date`"
PREFIX="firewall boot-iface"

if [ ! -z "$1" ] && [ "$1" = "check" ] ; then
	CHECKONLY=1 
	echo "$PREFIX INFO : check-only mode"
else
	CHECKONLY=0
fi

ret=0
r=0
for i in $IFACE ; do
	if ! ip link show dev $i >/dev/null 2>&1 ; then
		if [ -z "$CHECKONLY" ] || [ $CHECKONLY = "0" ] ; then
			echo "$PREFIX INFO : ip tuntap add dev $i mode tun"
			ip tuntap add dev $i mode tun ; r=$?
		else
			echo "$PREFIX INFO : check-only mode, skipping interface $i creation [ ip tuntap add dev $i mode tun ]"
			r=0
		fi
		if [ $r -ne 0 ] ; then
			echo "$PREFIX ERROR : ip link add dev $i FAILED !"
			ret=$r	
		fi
	else
		echo "$PREFIX INFO : dev $i already exist"
	fi
done

# moved to systemd-networkd .link
#echo "$PREFIX INFO : ethtool Ring Buffers"
#ethtool -G wan1 rx 4096 tx 4096
#ethtool -G lan1 rx 4096 tx 4096
#ethtool -G wan2 rx 1024 tx 1024
#echo "$PREFIX INFO : ethtool GRO"
#ethtool -K wan1 gro off
#ethtool -K wan2 gro off
#ethtool -K lan1 gro off

echo "$PREFIX EXIT : $ret"
exit $ret
```


## networkctl pre-check helper

This small helper is part of the surrounding operational glue.

It is not security policy, but it documents the environment assumptions that make the firewall reload process safer.

### Source: `networkctl.pre`

```sh
#!/bin/sh
# make sure that these interface are correctly configured
# there are some issues on boot with ipv6 subroute 

if [ ! -z "$1" ] && [ "$1" = "start" ] ; then
	echo "pre-networkctl INFO : networkctl reconfigure lan guest manage domo"
	networkctl reconfigure lan guest manage domo
else
	echo "pre-networkctl INFO : skipping networkctl reconfigure, not in starting mode..."
fi
```


## Deep dive: why the `protect` table matters so much

The `protect` table is the part of the ruleset that turns nftables from a static policy engine into a short-term memory system.

It does this with:

```text
sets      → store offenders
timeouts  → forget offenders later
meters    → detect rates and counts
updates   → insert offenders dynamically
chains    → log and drop
```

### DDoS sources vs DDoS networks

There are two related concepts:

```text
DDOS4 / DDOS6       → individual abusive addresses
DDOSNET4 / DDOSNET6 → abusive source network buckets
```

For IPv4, the source network bucket is based on `/24` logic:

```nft
(ip saddr & 255.255.255.0)
```

For IPv6, the bucket is effectively `/64`:

```nft
(ip6 saddr & ffff:ffff:ffff:ffff::)
```

That is a pragmatic compromise.

If one address is noisy, list the address.  
If a whole small network is noisy, list the network bucket.

This avoids playing whack-a-mole with a botnet that brought a subnet to a packet fight.

### Scan logic is not the same as DDoS logic

A scan is often slower than a flood.

That is why the rules distinguish:

```text
high-rate generic new-flow abuse
slow repeated touches on interesting ports
connection-count abuse
VPN-specific probing
allowed-port excessive SYNs
```

The scan logic uses lower rate thresholds and longer observation windows.

This is the right shape: a scanner is not always loud, but it is repetitive.

### Brute-force logic is deliberately tighter

The brute-force rules watch `$port_brute_wan`, which represents services where repeated login attempts are meaningful.

The pattern combines:

```text
ct count over 3
rate over 4/minute burst 6
timeout 24h
```

That means a few mistakes are tolerated, but repeated attempts become a one-day networking timeout.

Not a legal ruling. Just packet consequences.

### Why timeouts are useful

Permanent blocklists are operational debt.

Timeout sets keep the firewall adaptive without turning every random bot into a lifelong relationship.

Typical timeouts in this ruleset include:

```text
3h
12h
24h
```

Different behaviors get different memory lengths.

A short scan may deserve a few hours. A brute-force source can go think about its choices for a day.

### Why both `protect` and `netdev`

The `protect` table detects and updates dynamic sets.

The `netdev` table consumes some of those sets even earlier on WAN ingress.

That means:

```text
first suspicious packets
→ detected by protect
→ source inserted into DDOS/SCAN/BRUTE set
→ later packets dropped earlier by protect or netdev
```

This is the important performance pattern.

Detection may require conntrack, meters and state.  
Dropping known bad traffic should be as cheap as possible.

## Deep dive: fastpath and why it is intentionally boring

Fastpath is not security policy. It is a performance optimization.

The rule:

```nft
ct state established meta l4proto { tcp, udp } flow offload @fastpath counter
```

means:

```text
this flow has already been accepted
this flow is TCP or UDP
this flow is established
future packets may use the flowtable
```

The firewall still evaluates the early packets. That is where all the important decisions happen:

```text
drop known bad source
detect scan/brute/ddos
assign multi-WAN ct mark
perform NAT decision
apply zone policy
```

After that, if the flow is established and allowed, making every packet walk the full ruleset is not more secure. It is just more CPU.

The offload interface group is defined separately:

```nft
define iface_offload = { $iface_lan_phy, $iface_lan, $iface_guest, $iface_manage, $iface_domo, $iface_wan1, $iface_wan2, $iface_wan3 }
```

That is important because flowtable behavior depends on actual forwarding devices. The comment about newer kernels requiring physical interfaces is not decorative. It is the kind of comment written after reality had opinions.

### Fastpath and debugging

When debugging weird routing, NAT or mark behavior, fastpath can hide packets from the normal slow-path view.

Temporary rule of thumb:

```text
production traffic working normally → fastpath is useful
debugging strange packet behavior    → disable fastpath or trace before offload
```

`nft monitor trace` and flow offload are not best friends. They tolerate each other at family events.

## Final thoughts

This ruleset is not small.

But it is structured.

The important part is that each file has a job:

```text
define  → vocabulary
netdev  → earliest ingress drop
raw     → early hygiene
mangle  → marks and multi-WAN identity
mwan    → local WAN selection policy
nat     → DNS policy and address translation
filter  → normal allow/drop policy
protect → dynamic defense and abuse memory
set.pre → persistence of learned state
```

That is the kind of complexity I can live with.

Not complexity for its own sake.  
Complexity with labels, comments, counters, timeouts and logs.

Which is basically infrastructure therapy.

#nbux/firewall #blog/cyasssw/linux #publish

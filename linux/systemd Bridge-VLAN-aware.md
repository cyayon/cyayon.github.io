# Building a VLAN-Aware Linux Bridge for `systemd-nspawn` Containers

When a Linux router starts to look like a small datacenter, the network topology usually evolves in layers.

At first, a few bridges are enough. Then VLANs arrive. Then containers need to live in different security zones. Then the firewall expects stable interface names. Then monitoring, DHCP, Router Advertisements, and policy routing all quietly depend on the exact same naming conventions.

And eventually, you look at the topology and realize that your Linux box has reinvented a managed switch using too many moving parts.

This post describes a migration from a stacked Linux bridge model to a single VLAN-aware bridge using `systemd-networkd` and `systemd-nspawn`.

The result is closer to a real switch design: one trunk, one VLAN-aware bridge, explicit access ports, and clean L3 VLAN interfaces.

Simple enough to reason about. Weird enough to still be fun.

---

## The Initial Problem

The original design used one trunk bridge, several VLAN interfaces, and one access bridge per VLAN.

Conceptually, it looked like this:

```text
physical trunk
  -> trunk bridge
    -> VLAN interface
      -> per-VLAN access bridge
        -> containers
```

For example:

```text
lan1
  -> lantr1
    -> lantr1.lan
      -> lan
        -> vb-container
```

This worked.

It was reliable, understandable once documented, and friendly to `systemd-nspawn`, because containers could simply attach to an already-untagged bridge such as:

```text
lan
 domo
 guest
 manage
```

A container service could use:

```text
--network-bridge=lan
```

or:

```text
--network-bridge=domo
```

The container never had to care about VLAN tags.

That part was good.

The less good part was that the host L2 topology was more complex than necessary.

There were:

```text
multiple Linux bridges
intermediate VLAN interfaces
per-VLAN access bridges
less meaningful bridge VLAN visibility
more objects to debug during boot
```

In other words: it worked, but it no longer looked like the design I would build intentionally from scratch.

And that is usually a good signal that it is time to simplify.

---

## Design Goal

The goal was to migrate to a topology closer to:

- a managed switch with VLAN filtering;
- a MikroTik bridge with VLAN filtering;
- a Proxmox VLAN-aware bridge;
- a clean Linux bridge model using native VLAN awareness.

The new design had to keep the existing final interface names unchanged:

```text
lan
 domo
 guest
 manage
```

This was important because those names were already used by other parts of the system:

```text
nftables
 dnsmasq
 Router Advertisements
 Prometheus / node_exporter
 local scripts
 policy routing
 monitoring
```

Changing a topology is one thing.

Breaking half the router because an interface got renamed is another form of entertainment, usually reserved for late evenings and questionable life choices.

So the design goal was:

```text
change the L2 architecture
keep the operational interface names stable
```

---

## Previous Topology

The previous topology can be summarized as stacked bridges with VLAN subinterfaces.

```text
                           +----------------------+
                           |   Switch / CCR trunk |
                           +----------+-----------+
                                      |
                                      | tagged VLANs
                                      |
                                    lan1
                                      |
                                      v
                           +----------------------+
                           |       lantr1         |
                           |   bridge trunk       |
                           +---+-------+------+---+
                               |       |      |
                               |       |      +--- VLAN 88 tagged
                               |       |
                               |       +---------- VLAN 40 tagged
                               |
                               +---------- VLAN 9 tagged
```

VLANs were extracted using Linux VLAN interfaces:

```text
lantr1.lan     VLAN 42
lantr1.guest   VLAN 9
lantr1.domo    VLAN 40
lantr1.manage  VLAN 88
```

Each VLAN interface was then attached to a dedicated access bridge:

```text
lan1
  |
  v
lantr1
  |
  +-- lantr1.lan
  |      |
  |      v
  |     lan
  |      |
  |      +-- vb-container-a
  |      +-- vb-container-b
  |
  +-- lantr1.domo
  |      |
  |      v
  |     domo
  |
  +-- lantr1.guest
  |      |
  |      v
  |     guest
  |
  +-- lantr1.manage
         |
         v
        manage
```

This is a valid model, but it is not the most elegant one once Linux bridge VLAN filtering is available.

The main drawback is that VLAN membership is not centralized in one bridge VLAN table.

You can troubleshoot it, but you are troubleshooting a topology made of several L2 objects instead of one switch-like object.

---

## New Topology

The new topology uses one central VLAN-aware bridge:

```text
brlan1
```

The physical interface becomes a trunk port of this bridge:

```text
lan1 -> brlan1
```

The final L3 interfaces are VLAN interfaces created on top of `brlan1`:

```text
lan     = VLAN 42   on brlan1
guest   = VLAN 9    on brlan1
domo    = VLAN 40   on brlan1
manage  = VLAN 88   on brlan1
test    = VLAN 123  on brlan1
```

The bridge becomes the central Layer 2 object.

The VLAN interfaces become the router-facing Layer 3 objects.

```text
                              tagged trunk
                                  |
                                  v
                                lan1
                                  |
                                  v
                    +-----------------------------+
                    |           brlan1            |
                    |     VLAN-aware bridge       |
                    +---+------+-------+------+---+
                        |      |       |      |
                        |      |       |      +--> manage@brlan1
                        |      |       |           VLAN 88 / L3 host
                        |      |       |
                        |      |       +----------> domo@brlan1
                        |      |                    VLAN 40 / L3 host
                        |      |
                        |      +------------------> guest@brlan1
                        |                           VLAN 9 / L3 host
                        |
                        +-------------------------> lan@brlan1
                                                    VLAN 42 / L3 host
```

Containers also attach to `brlan1`, but as access ports.

Their VLAN membership is configured on the host-side veth interface:

```text
vb-container-a  access VLAN 42
vb-container-b  access VLAN 40
vb-container-c  access VLAN 9
```

From the container point of view, the interface is still untagged.

From the host point of view, the VLAN assignment is explicit in the bridge VLAN table.

That is the design I wanted: one bridge, explicit VLANs, no magic.

---

## Why This Design Is Cleaner

The new model has several advantages.

First, the bridge behaves like a real VLAN-aware switch.

There is one place to inspect VLAN membership:

```sh
bridge vlan show
```

Second, the physical interface is clearly a trunk:

```text
lan1 carries tagged VLANs
```

Third, containers are clearly access ports:

```text
vb-* interfaces use PVID + untagged VLAN membership
```

Fourth, the L3 interfaces keep their existing names:

```text
lan
 domo
 guest
 manage
```

That means existing firewall rules, DNS services, monitoring, and scripts can continue to refer to the same logical interfaces.

The implementation changed.

The operational contract stayed stable.

That distinction matters a lot on a router.

---

## Trunk vs Access Ports

A key point in this design is the difference between trunk ports and access ports.

The physical interface is a trunk:

```text
lan1
```

It carries VLANs tagged.

Therefore it should have VLAN entries like:

```ini
[BridgeVLAN]
VLAN=42

[BridgeVLAN]
VLAN=9

[BridgeVLAN]
VLAN=40

[BridgeVLAN]
VLAN=88
```

It should not be configured with:

```ini
PVID=42
EgressUntagged=1
```

Those settings are for access ports.

Access ports are used for container veth interfaces.

For example, a container that should live in VLAN 40 gets:

```sh
bridge vlan add dev vb-homeassistant vid 40 pvid untagged
```

Inside the container, there are no VLAN tags.

Outside the container, the host bridge knows exactly which VLAN the port belongs to.

This is the same mental model as a managed switch:

```text
uplink port  = trunk
device port  = access
```

Linux can do this very well. It just enjoys making the syntax look like a small initiation ritual.

---

## `systemd-networkd` Bridge Configuration

The VLAN-aware bridge is defined as a bridge netdev.

```ini
[NetDev]
Name=brlan1
Kind=bridge

[Bridge]
VLANFiltering=yes
DefaultPVID=none
STP=no
```

The important part is:

```ini
DefaultPVID=none
```

This prevents newly attached ports from automatically receiving a default untagged VLAN.

That is exactly what I want.

No implicit VLAN.

No accidental access port.

No “why is this container suddenly on the wrong network?” moment.

Every bridge port must be explicitly configured as either:

```text
trunk
```

or:

```text
access
```

The bridge network configuration then declares the VLAN interfaces created on top of it:

```ini
[Match]
Name=brlan1

[Network]
Description=VLAN-aware LAN bridge
ConfigureWithoutCarrier=true
LinkLocalAddressing=no
IPv6AcceptRA=no

VLAN=lan
VLAN=guest
VLAN=domo
VLAN=manage
VLAN=test
```

The bridge itself is Layer 2 only.

It should not carry IP addresses.

It should not accept IPv6 Router Advertisements.

The routed interfaces are the VLAN interfaces.

---

## Physical Trunk Port

The physical interface is attached to the bridge:

```ini
[Match]
Name=lan1

[Network]
Description=LAN trunk port to switch/CCR
Bridge=brlan1
LinkLocalAddressing=no
IPv6AcceptRA=no

[BridgeVLAN]
VLAN=42

[BridgeVLAN]
VLAN=9

[BridgeVLAN]
VLAN=40

[BridgeVLAN]
VLAN=88

[BridgeVLAN]
VLAN=123
```

There is intentionally no `PVID` and no `EgressUntagged` on this port.

This is a trunk port.

The switch on the other side must agree with that design.

As usual with VLANs, both sides need to tell the same story, otherwise packets disappear into the kind of silence only network engineers truly appreciate.

---

## L3 VLAN Interfaces

Each routed VLAN is created as a VLAN interface on top of `brlan1`.

Example for the LAN VLAN:

```ini
[NetDev]
Name=lan
Kind=vlan

[VLAN]
Id=42
```

And its network configuration:

```ini
[Match]
Name=lan

[Network]
Description=LAN VLAN 42
Address=192.168.42.254/24
IPv6AcceptRA=no
LinkLocalAddressing=no
```

Other VLANs follow the same pattern:

```text
guest   VLAN 9
domo    VLAN 40
manage  VLAN 88
test    VLAN 123
```

The important design choice is that `lan`, `guest`, `domo`, and `manage` remain the names used by the rest of the system.

Before the migration, they were bridges.

After the migration, they are VLAN interfaces.

From the firewall and routing point of view, the logical role is preserved.

---

## `systemd-nspawn` Containers

The container model changes slightly.

Before the migration, containers were attached to per-VLAN access bridges:

```text
--network-bridge=lan
--network-bridge=domo
--network-bridge=guest
--network-bridge=manage
```

After the migration, those interfaces are no longer bridges.

They are L3 VLAN interfaces.

So containers must attach to the central VLAN-aware bridge:

```text
--network-bridge=brlan1
```

Then the host-side veth interface is configured as an access port in the correct VLAN.

Example:

```ini
ExecStart=/usr/bin/systemd-nspawn --machine=container-name --directory=/mnt/vm/systemd/container-name --boot --network-bridge=brlan1
ExecStartPost=/etc/systemd/scripts/nspawn-access-vlan vb-container-name 42
```

The container sees a simple untagged interface, usually named:

```text
host0
```

Inside the container, the network configuration remains boring:

```ini
[Match]
Name=host0

[Network]
DHCP=yes
IPv6AcceptRA=yes
```

That is a good thing.

The host handles VLAN complexity.

The container gets a normal Ethernet interface and can remain blissfully unaware of the crimes committed outside its namespace.

---

## VLAN Access Helper Script

The access VLAN assignment can be done with a small helper script.

```sh
#!/bin/sh
set -eu

[ -z "$2" ] && echo "FATAL: usage: $0 interface vlan_id" && exit 9

iface="$1"
vid="$2"

if ! ip link show dev "$iface" >/dev/null 2>&1; then
    echo "Interface not found: $iface" >&2
    exit 1
fi

bridge vlan del dev "$iface" vid 1 2>/dev/null || true
bridge vlan add dev "$iface" vid "$vid" pvid untagged
ip link set "$iface" up

bridge vlan show dev "$iface"
bridge link show dev "$iface"
```

This helper does a few things:

1. checks that the veth interface exists;
2. removes the default VLAN 1 membership if present;
3. adds the requested VLAN as PVID and untagged;
4. brings the interface up;
5. prints the resulting bridge VLAN state.

Usage examples:

```ini
ExecStartPost=/etc/systemd/scripts/nspawn-access-vlan vb-lan-app 42
ExecStartPost=/etc/systemd/scripts/nspawn-access-vlan vb-guest-app 9
ExecStartPost=/etc/systemd/scripts/nspawn-access-vlan vb-domo-app 40
ExecStartPost=/etc/systemd/scripts/nspawn-access-vlan vb-admin 88
```

This is not a framework.

It is a tiny, explicit tool doing one job.

KISS still applies, even when VLANs are involved.

---

## Firewall and Boot Ordering

One subtle issue after the migration is boot ordering.

The interfaces `lan`, `domo`, `guest`, and `manage` are now VLAN interfaces created by `systemd-networkd` on top of `brlan1`.

If the firewall starts too early, those interfaces may not exist yet.

A firewall unit depending only on:

```ini
After=network.target
```

may be too optimistic.

A safer dependency is:

```ini
[Unit]
Description=Firewall
After=systemd-networkd.service network-online.target
Wants=network-online.target
```

For a router, the firewall should also avoid flushing a working ruleset before validating that required interfaces exist.

A simple guard is better than a clever outage:

```sh
for i in lan domo manage; do
    if ! ip link show dev "$i" >/dev/null 2>&1; then
        echo "firewall ERROR: interface $i not ready, keeping existing ruleset"
        exit 1
    fi
done

# Only load or replace the full nftables ruleset after validation.
```

This is especially important on remote systems.

A firewall script should fail safe, not fail enthusiastically.

---

## Verification Commands

The most useful commands are the boring ones.

Show VLAN interfaces:

```sh
ip -d link show type vlan
cat /proc/net/vlan/config
```

Show bridge topology:

```sh
bridge link show
bridge vlan show
```

Inspect the physical trunk:

```sh
tcpdump -eni lan1 vlan 42
tcpdump -eni lan1 vlan 40
tcpdump -eni lan1 not vlan
```

Inspect bridge traffic:

```sh
tcpdump -eni brlan1 arp or icmp
```

Inspect a container access port:

```sh
ip -br link show vb-container-name
bridge vlan show dev vb-container-name
```

Check routed VLAN interfaces:

```sh
ip -br addr show lan domo guest manage
```

Test connectivity:

```sh
ping -c 3 192.168.42.254
ping -c 3 1.1.1.1
```

Inside a container:

```sh
ip -br addr
ip route
ping -c 3 192.168.42.254
ping -c 3 1.1.1.1
```

The expected state is simple:

```text
lan1      = tagged trunk
brlan1    = VLAN-aware bridge
lan       = L3 interface for VLAN 42
guest     = L3 interface for VLAN 9
domo      = L3 interface for VLAN 40
manage    = L3 interface for VLAN 88
vb-*      = access ports for containers
```

---

## Lessons Learned

A few practical lessons came out of this migration.

First, Linux bridge VLAN filtering is worth using when the host starts to behave like a switch.

Second, preserving logical interface names reduces migration risk. The topology can change without forcing every firewall rule, service, script, and dashboard to change at the same time.

Third, `DefaultPVID=none` is your friend when you want explicit behavior.

Fourth, containers do not need to understand VLANs. The host can expose a clean untagged interface while still enforcing VLAN membership at the bridge level.

Fifth, boot ordering matters on routers. Network interfaces, firewall rules, DHCP, Router Advertisements, and monitoring do not all magically become ready at the same time just because `network.target` happened.

And finally: if `bridge vlan show` tells a clear story, the design is probably healthier than the one you had before.

---

## Final Model

The previous model was:

```text
lan1
  -> trunk bridge
    -> VLAN subinterface
      -> per-VLAN access bridge
        -> nspawn containers
```

The new model is:

```text
lan1
  -> brlan1 VLAN-aware bridge
    -> L3 VLAN interfaces: lan, guest, domo, manage
    -> nspawn access ports: vb-* with PVID/untagged VLANs
```

The key difference is that containers are no longer attached to per-VLAN bridges.

They all attach to the central VLAN-aware bridge, and their VLAN is configured on the host-side veth interface.

This gives a cleaner L2 model, keeps L3 interface names stable, and makes the Linux host behave much more like a real VLAN-aware switch/router.

It is not magic.

It is just Linux doing exactly what was asked.

Which, when networking is involved, is already a small victory.

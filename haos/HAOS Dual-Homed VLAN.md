# Making Home Assistant OS Dual-Homed with a Persistent IoT VLAN

Home Assistant OS is intentionally designed as an appliance.

That is one of its strengths: it is easy to install, easy to update, and avoids exposing too many operating system details to the user. But when you run a more advanced home network, this model can also become limiting.

In my case, I wanted my Home Assistant OS instance to be reachable from two different network segments:

- my main LAN VLAN, used for administration and trusted services;
- my IoT / home automation VLAN, where devices such as sensors, relays, gateways, and local integrations live.

The goal was not simply to “add a VLAN interface”. The real objective was to make Home Assistant OS behave correctly as a **dual-homed host**, with deterministic routing, IPv4 and IPv6 support, and a configuration that survives reboots.

This post describes the approach I implemented in my [hass_vlan.sh](hass_vlan.sh) script.

---

## The Problem

Home Assistant OS provides a managed network configuration layer through the Supervisor and the `ha network` command.

For standard setups, this is perfectly fine.

However, more advanced routing scenarios quickly hit limitations:

- adding a VLAN interface is possible, but the routing model is limited;
- Home Assistant OS may create connected routes in the main routing table;
- source-based routing is not directly exposed in the GUI;
- NetworkManager configuration can be overwritten or normalized by the Supervisor;
- changes made manually with `ip route` or `ip rule` are not persistent;
- the `hassio` internal bridge and container routing can make troubleshooting harder.

In a dual-homed setup, this can easily result in ambiguous routing.

For example, if Home Assistant has an address on both the LAN and the IoT VLAN, Linux may route replies using the wrong interface unless the routing policy is made explicit.

That is especially problematic when firewall rules are strict and traffic is expected to return through the same network path.

---

## Design Goals

The script was written with the following goals:

1. Keep the default Home Assistant OS network model intact.
2. Avoid modifying the base interface profile.
3. Add a dedicated VLAN interface for the IoT network.
4. Support both IPv4 and IPv6.
5. Avoid polluting the main routing table with IoT VLAN connected routes.
6. Use policy routing so traffic sourced from the VLAN address leaves through the VLAN.
7. Make the configuration persistent across reboots.
8. Provide clear status and validation commands.
9. Keep a safe cleanup path to remove the configuration if needed.

In other words, the goal was not only to make it work once, but to make it operationally reliable.

---

## Network Topology

The Home Assistant OS host is connected to the main network through a physical interface.

In my production setup, the base interface is:

```text
enp0s20f0
```

The main network is:

```text
192.168.40.0/24
fd11:0:0:40::/64
```

The IoT / home automation VLAN is VLAN 42:

```text
192.168.42.0/24
fd11:0:0:42::/64
```

The script creates a VLAN interface on top of the base interface:

```text
enp0s20f0.42
```

Home Assistant then gets a dedicated IPv4 and IPv6 address on that VLAN:

```text
192.168.42.61
fd11:0:0:42::61
```

The VLAN gateways are:

```text
192.168.42.254
fd11:0:0:42::254
```

The script also supports a failover host with a different interface and IP suffix, so the same logic can be reused outside production.

---

## The Key Trick: /32 and /128 Addresses

The most important design choice is that the VLAN interface is not configured with a traditional `/24` or `/64`.

Instead, the script configures:

```text
192.168.42.61/32
fd11:0:0:42::61/128
```

At first sight, this may look unusual.

The reason is simple: I do not want NetworkManager or Home Assistant OS to automatically install connected routes for the IoT VLAN in the main routing table.

If the interface were configured as:

```text
192.168.42.61/24
fd11:0:0:42::61/64
```

Linux would automatically add routes such as:

```text
192.168.42.0/24 dev enp0s20f0.42
fd11:0:0:42::/64 dev enp0s20f0.42
```

in the main table.

That is exactly what I wanted to avoid.

By using `/32` and `/128`, the VLAN address exists on the interface, but the subnet routes are not implicitly injected into the main routing table.

The routes are then added explicitly into a dedicated routing table.

---

## Dedicated Routing Table

The script uses a dedicated routing table for VLAN-sourced traffic.

For VLAN 42, I use table:

```text
142
```

The table contains the IPv4 routes required for the VLAN:

```text
192.168.42.254 dev enp0s20f0.42
192.168.42.0/24 dev enp0s20f0.42
default via 192.168.42.254 dev enp0s20f0.42
```

And the IPv6 routes:

```text
fd11:0:0:42::254 dev enp0s20f0.42
fd11:0:0:42::/64 dev enp0s20f0.42
default via fd11:0:0:42::254 dev enp0s20f0.42
```

Because the interface address is configured as `/32` and `/128`, the gateway itself must also be added as an on-link route.

That is why the script explicitly installs routes to:

```text
192.168.42.254/32
fd11:0:0:42::254/128
```

Without those routes, the kernel may reject the default route because the gateway is not considered directly reachable.

---

## Source-Based Policy Routing

The second key part is policy routing.

The script adds rules like:

```text
from 192.168.42.61 lookup 142
from fd11:0:0:42::61 lookup 142
```

with an explicit priority:

```text
10042
```

This means:

- traffic sourced from the main LAN address follows the normal routing table;
- traffic sourced from the IoT VLAN address uses routing table 142;
- the main table remains clean;
- return traffic from Home Assistant services bound to the VLAN address goes back through the VLAN.

This is the actual dual-homing logic.

The host can exist on multiple networks, but the routing decision is deterministic.

---

## Runtime Mode vs Persistent Mode

The script provides two ways to apply the configuration.

### Runtime mode

Runtime mode uses:

```sh
ip route
ip -6 route
ip rule
ip -6 rule
```

This is useful for testing, debugging, and emergency repair.

It can be applied with:

```sh
./hass_vlan.sh start_ip
```

or:

```sh
./hass_vlan.sh fix
```

This mode is not persistent across reboot, but it allows quick recovery without touching NetworkManager profiles.

### Persistent mode

Persistent mode uses NetworkManager through `nmcli`.

It can be applied with:

```sh
./hass_vlan.sh enable
```

or:

```sh
./hass_vlan.sh start_nmcli
```

This mode creates a dedicated NetworkManager VLAN profile:

```text
Supervisor enp0s20f0.42
```

The base interface profile is detected, but not modified.

That is intentional.

The script owns the VLAN profile only. This minimizes the risk of breaking Home Assistant OS networking or fighting with the Supervisor-managed base configuration.

---

## Why Not Modify the Base Interface?

One earlier approach was to add additional policy rules or routes to the base interface profile.

That worked, but it was fragile.

Home Assistant OS and the Supervisor expect to manage the primary interface. Changing that profile directly increases the risk of:

- losing changes after a reboot;
- breaking the default network path;
- creating unexpected interactions with the internal `hassio` bridge;
- making future upgrades harder to debug.

The current design avoids that.

The base interface remains responsible for the default Home Assistant OS connectivity.

The VLAN profile is isolated and owned by the script.

---

## NetworkManager Configuration

The persistent configuration relies on NetworkManager properties such as:

```sh
ipv4.route-table 142
ipv6.route-table 142
```

Routes are then added to the VLAN profile without embedding the table number in each individual route.

This matters because Home Assistant OS may normalize or strip route attributes when they are expressed in a way it does not fully preserve.

By setting the route table at the profile level, the configuration remains cleaner and survives reboots more reliably.

The VLAN profile stores:

- the VLAN parent interface;
- the VLAN ID;
- IPv4 `/32` address;
- IPv6 `/128` address;
- route table ID;
- IPv4 and IPv6 VLAN routes;
- IPv4 and IPv6 source policy rules.

---

## Built-In Cleanup

The script includes cleanup logic for both the current design and older attempts.

This is important because networking experiments often leave behind stale routes or rules.

The script removes old policy rules with priorities:

```text
10042
10043
10044
```

It also cleans legacy routes from the old table design.

The persistent cleanup mode can be called with:

```sh
./hass_vlan.sh disable
```

or:

```sh
./hass_vlan.sh stop_nmcli
```

Runtime cleanup is available with:

```sh
./hass_vlan.sh stop_ip
```

This makes the script reversible, which is critical when working remotely or on an appliance-like system.

---

## Status and Validation

The script provides two diagnostic commands:

```sh
./hass_vlan.sh info
```

and:

```sh
./hass_vlan.sh check
```

The `info` command prints:

- Home Assistant network information;
- active NetworkManager profiles;
- base and VLAN interface addresses;
- IPv4 and IPv6 routing rules;
- routing table contents;
- route lookup tests;
- expected routing behavior.

The `check` command performs validation and exits with a non-zero code if something is wrong.

It verifies that:

- the VLAN interface exists;
- IPv4 and IPv6 addresses are present with `/32` and `/128`;
- the main routing table does not contain the VLAN subnet;
- the old routing table is empty;
- old policy rules are absent;
- the dedicated VLAN routing table contains the expected routes;
- source-based IPv4 and IPv6 rules exist;
- route lookup behaves as expected.

The expected behavior is:

```text
Default traffic to the IoT VLAN uses the base interface and the main routing table.
Traffic sourced from the IoT VLAN address uses the VLAN interface and table 142.
```

That distinction is the core of the design.

---

## Operational Usage

Typical usage is:

```sh
./hass_vlan.sh init
./hass_vlan.sh enable
./hass_vlan.sh check
```

Where:

- `init` installs `networkmanager-cli` if needed;
- `enable` creates and persists the VLAN profile;
- `check` validates the final routing behavior.

If something needs to be repaired temporarily:

```sh
./hass_vlan.sh fix
```

If the configuration needs to be removed:

```sh
./hass_vlan.sh disable
```

---

## Why This Matters

In a simple home network, this kind of setup is unnecessary.

But once Home Assistant becomes part of a segmented infrastructure, routing precision matters.

A typical modern smart home network may have:

- trusted LAN devices;
- IoT VLANs;
- guest networks;
- management networks;
- firewall policies between zones;
- local integrations that depend on broadcast or direct IP reachability;
- IPv6 ULA addressing;
- strict routing expectations.

In that context, Home Assistant OS should not be treated as a single-interface black box.

It may need to participate cleanly in multiple L3 domains while still preserving the simplicity and update model of Home Assistant OS.

This script is my attempt to bridge those two worlds:

- keep the appliance-like behavior of Home Assistant OS;
- add the routing control expected from a properly engineered Linux host.

---

## Lessons Learned

A few lessons came out of this work.

First, adding a VLAN is easy. Making it route correctly is the real challenge.

Second, persistence matters. A fix that disappears at reboot is not a solution.

Third, source-based routing is often cleaner than trying to force everything through the main table.

Fourth, when working with Home Assistant OS, it is safer to avoid modifying the base interface profile directly.

Finally, validation should be part of the script. Networking problems are much easier to troubleshoot when the expected behavior is encoded and tested.

---

## Conclusion

The final design gives Home Assistant OS a persistent IoT VLAN presence while keeping the main LAN connectivity intact.

It provides:

- dual-homed IPv4 and IPv6 connectivity;
- clean separation between main and VLAN routing;
- source-based policy routing;
- persistent NetworkManager configuration;
- safe cleanup;
- built-in diagnostics.

This is not the simplest way to add a VLAN to Home Assistant OS.

But it is a robust way to make Home Assistant OS behave predictably in a segmented, firewall-controlled, dual-stack home network.

For me, that is the difference between a configuration that merely works and a configuration that can be operated with confidence.

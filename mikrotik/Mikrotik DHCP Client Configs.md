# Mikrotik DHCP Client Configs

# Making MikroTik DHCP Clients Network-Aware

Most DHCP client scripts are small operational hacks.

This one is different.

The goal is not only to accept whatever address or prefix the ISP gives to the router. The goal is to make the DHCP lease event become the source of truth for the rest of the routing, firewalling, NAT, policy routing, and monitoring configuration.

In a simple home setup, a DHCP client obtains an address and installs a default route.

In a multi-WAN router, especially one using both IPv4 and IPv6, that is not enough.

A WAN lease may change. A delegated IPv6 prefix may change. The IPv4 gateway may not always be stable. The ISP may provide a dynamic address today and a different one tomorrow. The router may have multiple routing tables, per-WAN policy routing rules, recursive or non-recursive routes, firewall address lists, netmap rules, and monitoring probes that all depend on the current lease.

If these elements are not updated consistently, the router may still appear partially online while some traffic silently breaks.

This post describes the design behind two MikroTik RouterOS DHCP client scripts:

- one for IPv4 DHCP client events [dhcp4-client.mkt](https://codeberg.org/cyayon/cyasssw/src/branch/main/mikrotik/dhcp4-client.mkt);
- one for IPv6 DHCPv6 Prefix Delegation events [dhcp6-client.mkt](https://codeberg.org/cyayon/cyasssw/src/branch/main/mikrotik/dhcp6-client.mkt).

They are used directly inside the MikroTik DHCP client configuration and update the router dynamically when the ISP changes the assigned parameters.

---

## Why DHCP Client Scripts Matter

On RouterOS, DHCP clients can execute a script when the lease state changes.

That makes the DHCP client more than a passive address acquisition mechanism. It becomes a trigger point for network reconfiguration.

This is extremely useful in ISP environments where:

- the IPv4 address may change;
- the IPv4 gateway may change;
- the IPv6 delegated prefix may change;
- the IPv6 non-temporary address may not always be valid;
- firewall rules depend on the current prefix;
- NAT or netmap rules depend on the current prefix;
- per-WAN routing tables depend on the current gateway;
- monitoring probes must use the correct source address.

Instead of manually updating all dependent configuration blocks, the DHCP client script performs the update automatically.

The key idea is simple:

> When the ISP changes the lease, the router updates every dependent object that must follow that lease.

---

## Technical Prerequisites

This design assumes a router that is already built around deterministic routing.

It is not a replacement for a proper multi-WAN architecture. It complements it.

Before using this kind of script, the router should already have the following elements in place.

---

## Per-WAN Routing Tables

Each WAN should have its own routing table.

For example, WAN1 may use:

```text
route-wan1
```

That table must already exist in RouterOS.

The DHCP script does not create the full routing architecture. It only updates the dynamic parts of it.

A typical design is:

```text
main
route-wan1
route-wan2
route-wan3
```

The `main` table is used for the default system routing decision.

The per-WAN tables are used for policy routing, diagnostics, forced egress checks, or traffic explicitly pinned to a WAN.

---

## Pre-Created Routes

The script expects some routes to already exist.

This is intentional.

Instead of creating and deleting routes dynamically, the script updates existing routes that are identified by:

- destination;
- routing table;
- distance;
- comment pattern.

For IPv4, the script updates routes such as:

```text
0.0.0.0/0 in route-wan1
0.0.0.0/0 in main with distance 1
0.0.0.0/0 in main with distance 101
```

The important point is that the objects already exist.

The script only changes the gateway and comments when a new lease is obtained.

This avoids a class of operational problems where duplicated routes are accidentally created after repeated DHCP renewals.

---

## Active Route and Persistent Fallback Route

The routing model uses two routes for a real WAN path:

1. an active route;
2. a persistent fallback route.

The active route is the one manipulated by operational logic, watchdogs, or failover scripts.

The persistent route is kept as a stable fallback. It is not meant to be modified by the watchdog loop. It exists so the router always has a known, preconfigured path that can be restored or used as a safety net.

In the IPv4 DHCP script, both are updated when the DHCP lease changes because both must point to the current ISP gateway.

For example:

```text
distance 1    active default route
distance 101  persistent fallback default route
```

The DHCP client updates the gateway of both routes using the gateway provided by the ISP.

But the runtime watchdog may only manipulate the active one.

This separation is important.

The DHCP script keeps the configuration accurate.

The route watchdog decides whether the active route should be currently usable.

Those are two different responsibilities.

---

## Strong Object Matching

The scripts do not blindly update the first object they find.

They use a comment pattern such as:

```text
DHCLIENT4 orange1
DHCLIENT6 orange1
```

This is one of the most important operational safeguards.

Routes, routing rules, firewall address lists, NAT rules, and Netwatch entries are selected by their function and by a comment regex.

That means the script is designed to update the intended objects only.

This also makes the configuration self-documenting.

When looking at the MikroTik configuration, comments show which objects are controlled by the DHCP client script and which WAN they belong to.

---

## IPv4 DHCP Client Script

The IPv4 script runs only when the DHCP client is bound:

```routeros
:if ($bound=1) do={
    ...
}
```

This avoids applying incomplete values when the client is not in a valid state.

When the lease is valid, the script reads:

```routeros
:local leaseaddr $"lease-address"
:local gwaddr $"gateway-address"
```

These values are then used to update the rest of the router configuration.

---

## Updating the Per-WAN Routing Rule

The script updates the source address of the routing rule associated with WAN1:

```routeros
/routing rule set [find where action=lookup table=$routetable comment~$commentregex ] src-address=$"lease-address" comment="wan1 fib - $commentregex"
```

This keeps policy routing aligned with the current DHCP address.

If the ISP changes the IPv4 address, the routing rule follows automatically.

Without this, source-based routing may continue to reference an obsolete address.

---

## Updating the Per-WAN Default Route

The script also updates the default route inside the per-WAN routing table:

```routeros
/ip route set [find where dst-address="0.0.0.0/0" routing-table=$routetable distance=1 ] gateway=$"gateway-address" comment="wan1 fib - $commentregex"
```

This keeps `route-wan1` valid after a DHCP renewal.

Any diagnostic, policy-routed, or explicitly WAN1-sourced traffic can continue to use the correct gateway.

---

## Updating the Main Default Routes

The script then updates the main routing table.

It first looks for the active default route:

```routeros
/ip route find where dst-address="0.0.0.0/0" routing-table=main distance=1
```

If exactly one route is found, the gateway is updated.

If not, the update is skipped and a warning is logged.

The same logic is applied to the persistent fallback route:

```routeros
/ip route find where dst-address="0.0.0.0/0" routing-table=main distance=101
```

This is deliberately defensive.

A DHCP event should not turn a routing ambiguity into an outage by modifying multiple routes unexpectedly.

If the script does not find exactly one matching route, it refuses to guess.

---

## Updating Netwatch Source Address

Finally, the IPv4 script updates Netwatch entries associated with the WAN:

```routeros
/tool netwatch set [find where comment~$commentregex ] src-address=$"lease-address"
```

This matters because monitoring should test the correct path.

If Netwatch keeps probing from an old source address, the monitoring result becomes meaningless.

By binding the probe source address to the current DHCP lease, the monitoring logic remains consistent with the actual WAN state.

---

## IPv6 DHCPv6 Client Script

The IPv6 script is built around Prefix Delegation.

It runs only when the delegated prefix is valid:

```routeros
:if ($"pd-valid" = 1) do={
    ...
}
```

This is the IPv6 equivalent of refusing to act on incomplete state.

The script reads:

```routeros
:local pdprefix $"pd-prefix"
:local naaddress $"na-address"
:local navalid $"na-valid"
```

The delegated prefix is then propagated to the dependent configuration objects.

---

## Prefix Delegation as a Dynamic Input

Many ISPs do not provide a permanently fixed IPv6 delegated prefix.

Even when the prefix is stable most of the time, the router should not assume that it will never change.

If firewall rules, prefix routes, ULA-to-GUA mappings, or delegated LAN prefixes are configured statically, a prefix change can break IPv6 silently.

The DHCPv6 script solves this by treating the delegated prefix as a dynamic variable.

When the ISP provides a valid prefix, the script updates:

- IPv6 addresses assigned from the pool;
- internal prefix routes;
- per-WAN routing rules;
- firewall address lists;
- IPv6 netmap rules;
- Netwatch source addresses.

---

## Updating IPv6 Addresses from the Delegated Pool

The script updates an address on the WAN-side interface:

```routeros
/ipv6 address set [find where interface=$iface from-pool=$pool comment~$commentregex ] address=$guaiface comment="wan1 pool (ONLY tiergw) - $commentregex"
```

It also updates an address on an interconnection interface:

```routeros
/ipv6 address set [find where interface=$ifaceinterco from-pool=$pool comment~$commentregex ] address=$guainterco comment="wan1 pool - interco (ONLY tiergw OPTION) - $commentregex"
```

The point is not merely to assign addresses.

The point is to make internal router-facing sub-configurations follow the prefix delegated by the ISP.

This is especially useful when another downstream router, firewall, or tiered gateway needs to receive or route part of the delegated space.

---

## Prefix Route via ULA Interconnection

The script updates a route to the delegated prefix through a ULA gateway on the interconnection network:

```routeros
/ipv6 route set $check dst-address=$"pd-prefix" comment="wan1 pool - prefix via ULA iface (ONLY tiergw) - $commentregex"
```

The gateway is based on an internal ULA next hop:

```text
fd11:0:0:2::254%vlan2-interco
```

This design is useful when the delegated ISP prefix must be routed across an internal interconnection network while keeping the next hop stable.

The GUA prefix may change.

The ULA interconnection gateway remains stable.

That separation is a good design principle.

Dynamic public addressing should not force the internal underlay to become dynamic too.

---

## Deriving the Interconnection Prefix

The script also updates a route through the interconnection interface itself.

To do this, it retrieves the current IPv6 address assigned from the pool, extracts the prefix part, and builds a `/64` route.

Conceptually:

```text
assigned address -> derived /64 prefix -> update route
```

This allows the router to follow the prefix delegated by the ISP while still maintaining correct routing toward the internal interconnection segment.

The script also logs the derived prefix and warns if it cannot derive it safely.

Again, the principle is defensive automation.

The script automates what can be inferred safely, and logs a warning when the expected structure is not present.

---

## Updating IPv6 Source-Based Routing

The DHCPv6 script updates the policy routing rule for WAN1:

```routeros
/routing rule set [ find where action=lookup table=route-wan1 comment~$commentregex ] src-address=$"pd-prefix" comment="wan1 fib - $commentregex"
```

This is the IPv6 equivalent of the IPv4 source-address update.

Traffic sourced from the delegated prefix can be routed through the WAN-specific routing table.

If the ISP prefix changes, the routing rule follows the new prefix.

---

## Updating Firewall Address Lists

The script updates the IPv6 firewall address list associated with the LAN:

```routeros
/ipv6/firewall/address-list set [find where list=lan comment~$commentregex ] address=$"pd-prefix" comment="wan1 pool - $commentregex" dynamic=no
```

This is a very practical detail.

Firewall policies often refer to address lists rather than hardcoded prefixes.

By updating the address list when the delegated prefix changes, firewall rules remain stable.

The rules keep referencing the same list name, while the actual prefix behind the list is updated dynamically.

This is cleaner than rewriting firewall rules directly.

---

## Updating IPv6 Netmap

The script updates an IPv6 netmap rule:

```routeros
/ipv6/firewall/nat set [find where chain=srcnat action=netmap out-interface=$iface src-address="fd11::/56" comment~$commentregex ] to-address=$"pd-prefix" comment="wan1 netmap ULA - $commentregex"
```

This maps an internal ULA prefix to the delegated ISP prefix.

It is useful when internal addressing is stable but the public delegated prefix is not guaranteed to be fixed.

The internal network can keep using stable ULA addressing.

The router dynamically maps it to the currently delegated GUA prefix.

This is not always necessary in IPv6 networks, and many designs avoid NAT66 entirely.

But in a lab, home-lab, or tiered router design, netmap can be a pragmatic way to preserve internal addressing stability while still using ISP-provided global addresses.

---

## Updating IPv6 Netwatch

The script updates Netwatch only if the non-temporary IPv6 address is valid:

```routeros
:if ($navalid = 1) do={
    /tool netwatch set [ find where type=icmp comment~$commentregex ] src-address=$"na-address" comment="wan1 src - $commentregex"
} else={
    /log info "dhcp6-client na-address not valid (na-valid $navalid), skipping netwatch src-address update"
}
```

This is important.

The delegated prefix may be valid while the non-temporary address is not.

The script does not assume both are valid at the same time.

If the source address is not valid, it skips the Netwatch update and logs the reason.

That is a small detail, but it makes the automation safer.

---

## Why Not Let RouterOS Do Everything Automatically?

RouterOS can install DHCP-provided default routes automatically.

For simple networks, that is enough.

For this design, it is not.

The router is not simply using one WAN and one main routing table.

It has:

- per-WAN routing tables;
- source-based routing rules;
- active and persistent default routes;
- optional recursive route logic;
- Netwatch probes with explicit source addresses;
- firewall address lists tied to delegated prefixes;
- IPv6 netmap tied to the current prefix;
- internal interconnection routes;
- delegated prefix handling toward downstream segments.

No DHCP client can automatically infer all of that design intent.

The DHCP client knows the lease.

The script knows how the rest of the router architecture depends on that lease.

That is the missing layer.

---

## Existing Alternatives

There are several ways to handle this kind of problem.

### Fully static ISP addressing

The cleanest solution is a fixed IPv4 address and a fixed IPv6 delegated prefix.

If the ISP guarantees stable addressing, most of this automation becomes unnecessary.

But not every residential or small-business ISP provides truly static parameters.

Even when addresses are stable in practice, they may not be contractually guaranteed.

### Letting the DHCP client install routes automatically

This is simple, but it usually only updates the main routing table.

It does not update per-WAN tables, source rules, firewall address lists, netmap rules, or monitoring source addresses.

### Using more RouterOS dynamic routing features

One could build a more complex design using recursive routing, check-gateway, multiple distances, routing rules, routing marks, and Netwatch-triggered scripts.

This can work very well.

But if too many components are allowed to modify routes at the same time, the design becomes harder to reason about.

### Using a full routing daemon

On Linux routers, one might use FRR, BGP, OSPF, or another routing daemon.

On RouterOS, dynamic routing can also be used in more complex topologies.

That is appropriate for larger networks.

But for a home-lab or small edge router, it can be overkill if the real problem is simply “when DHCP changes, update the dependent objects”.

### Rebuilding configuration from scratch on every lease

Another approach would be to delete and recreate routes, rules, firewall entries, and monitoring objects on every DHCP event.

I deliberately avoid that.

The safer approach is to pre-create the intended objects and update only their dynamic attributes.

The configuration remains visible, auditable, and predictable.

---

## Why I Prefer This KISS Design

This design follows a KISS principle: Keep It Simple, Stupid.

The DHCP client script does not try to become a routing daemon.

It does not try to own the whole firewall.

It does not create a hidden state machine.

It does not maintain external state.

It simply reacts to a valid DHCP event and updates the RouterOS objects that depend on the current ISP parameters.

The persistent design lives in the RouterOS configuration.

The script only changes values that are expected to change:

- current IPv4 lease address;
- current IPv4 gateway;
- current IPv6 delegated prefix;
- current IPv6 non-temporary address;
- dependent route destinations;
- dependent source addresses;
- dependent firewall address-list values;
- dependent netmap target prefix.

That makes it robust.

If the script runs twice, it sets the same values twice.

If the DHCP lease changes, the dependent objects follow.

If the expected object is missing or duplicated, the script logs a warning instead of guessing.

This is exactly the kind of automation I prefer on an edge router: small, explicit, idempotent, and observable.

---

## Operational Philosophy

The scripts separate responsibilities cleanly.

The DHCP client script is responsible for lease-driven configuration.

The route watchdog is responsible for determining whether a WAN path should currently be active.

Firewall rules are responsible for allowing or denying traffic.

Routing tables are responsible for routing decisions.

Netwatch is responsible for health checks.

Each component does one job.

This is simpler than building one large script that tries to detect, decide, reconfigure, firewall, and monitor everything at once.

The result is easier to debug because the failure domain is smaller.

If routing is wrong, inspect routing tables and rules.

If the prefix changed, inspect the DHCPv6 client script logs.

If monitoring is wrong, inspect Netwatch source addresses.

If firewalling is wrong, inspect the address lists.

That is operationally much cleaner than opaque automation.

---

## Example Flow: IPv4 Lease Renewal

When the IPv4 DHCP client receives a valid lease:

1. the script reads the lease address;
2. the script reads the gateway address;
3. the per-WAN routing rule source address is updated;
4. the per-WAN default route gateway is updated;
5. the active main default route gateway is updated;
6. the persistent fallback default route gateway is updated;
7. Netwatch probes are updated to use the current lease address;
8. the script logs completion.

The result is that the whole IPv4 WAN-dependent configuration follows the current ISP lease.

---

## Example Flow: IPv6 Prefix Renewal

When the DHCPv6 client receives a valid delegated prefix:

1. the script reads the delegated prefix;
2. the script reads the non-temporary address validity state;
3. IPv6 addresses assigned from the pool are updated;
4. the delegated prefix route via ULA interconnection is updated;
5. the interconnection prefix route is derived and updated;
6. the per-WAN routing rule is updated to use the delegated prefix;
7. the firewall LAN address list is updated;
8. the IPv6 netmap target prefix is updated;
9. Netwatch is updated only if the non-temporary address is valid;
10. the script logs completion.

The result is that IPv6 routing, firewalling, monitoring, and prefix-dependent translation remain aligned with the ISP-provided prefix.

---

## Why Comments Are Part of the Design

The scripts rely heavily on comments such as:

```text
DHCLIENT4 orange1
DHCLIENT6 orange1
```

This is not cosmetic.

In RouterOS, comments are a practical way to tag configuration objects.

They make scripts safer because the script can find the objects it owns.

They make troubleshooting easier because the operator can see why a route, rule, or firewall entry exists.

They also make the configuration portable.

To adapt the design to another WAN, the same logic can be reused with a different comment pattern and routing table.

---

## Things I Intentionally Avoid

I intentionally avoid:

- dynamically creating large parts of the configuration;
- deleting and recreating routes on each lease;
- using hidden state files;
- depending on a single monolithic failover script;
- embedding too much decision logic into DHCP events;
- letting DHCP automatically own the full routing model;
- relying only on the main routing table;
- assuming that IPv6 NA and PD validity always move together.

This keeps the system predictable.

The router configuration remains the source of truth.

The DHCP scripts only update the dynamic values inside that configuration.

---

## Conclusion

These MikroTik DHCP client scripts are small, but they solve an important operational problem.

They make a multi-WAN RouterOS configuration follow ISP-provided dynamic parameters without turning the router into a fragile pile of manual updates.

The IPv4 script keeps per-WAN routing, default routes, fallback routes, and Netwatch aligned with the current lease.

The IPv6 script keeps delegated prefixes, internal routes, firewall address lists, netmap rules, policy routing, and monitoring aligned with the current prefix.

The design is intentionally simple:

- pre-create the objects;
- tag them clearly;
- update only what depends on the lease;
- refuse to guess when matches are ambiguous;
- log what happened;
- keep the rest of the routing architecture explicit.

It is not the most sophisticated possible design.

That is the point.

For an edge router, especially in a home-lab or small infrastructure environment, I prefer automation that is boring, deterministic, and easy to inspect.

This is KISS networking: simple enough to understand, robust enough to trust.


#publish #cyasssw/mikrotik

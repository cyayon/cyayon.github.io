# Building a Simple DHCP Client Watchdog for a MikroTik Router

Consumer and ISP-facing networks fail in ways that are not always clean.

Sometimes the physical link stays up, but the upstream path is broken. Sometimes IPv4 is still working while IPv6 has silently failed. Sometimes the default route remains installed, but traffic no longer leaves through the WAN. Sometimes the DHCP client is no longer in a healthy state, even though the interface itself looks fine.

This is especially true on ISP networks where the router is connected through an ONT, a VLAN-tagged WAN interface, DHCPv4, DHCPv6-PD, and dynamically installed routes.

For that kind of setup, I wrote a small RouterOS watchdog script [check-dhclient](check-dhclient).

Its purpose is deliberately simple:

> continuously verify that a WAN DHCP client is healthy, and restart the DHCP client and interface only when the failure is real.

This post explains the design behind the script, why I chose this approach, and why I prefer a KISS, robust, mostly stateless watchdog over more complex routing or monitoring frameworks for this specific problem.

---

## Context

The script is designed for a MikroTik router used as an ISP edge router.

In my case, the WAN interface is a VLAN interface:

```text
vlan832-orange1.wan1
```

This interface is used by both:

- an IPv4 DHCP client;
- an IPv6 DHCP client, typically for prefix delegation;
- dynamic WAN routes;
- ISP-facing reachability checks.

The script is intended to be launched periodically by the RouterOS scheduler, or run in the background depending on the operational model.

The key idea is not to build a full routing daemon.

The key idea is to answer one operational question:

> Is this WAN still healthy enough to be trusted?

If not, the script releases the DHCP leases, disables the WAN interface briefly, and enables it again.

---

## Why a DHCP Watchdog?

A DHCP client can fail in subtle ways.

The status can become stale, the delegated prefix can disappear, the route may remain but no longer work, or the interface may stay up while the ISP-side session is broken.

On many networks, simply checking whether the interface is `running` is not enough.

Likewise, checking only one public IP with one ping is too fragile. A remote host may be temporarily unreachable even if the WAN is fine.

The script therefore combines several checks:

1. verify that the local source address exists on the WAN interface;
2. optionally verify the local ONT reachability;
3. optionally verify that recursive routes are active;
4. test real forwarding with pings forced through the WAN interface;
5. verify that both DHCPv4 and DHCPv6 clients are in `bound` state;
6. reset the interface and DHCP clients only after a real failure condition.

This gives a better signal than any single test alone.

---

## Technical Prerequisites

Before using this kind of script, the router should already have a clean and deterministic WAN design.

The script is not meant to compensate for an unclear routing architecture.

It assumes that the following foundations are already in place.

---

## 1. A Dedicated WAN Interface

The WAN should be represented by a clear RouterOS interface.

In my case, this is a VLAN interface:

```routeros
:local iface "vlan832-orange1.wan1"
```

This interface is the point where DHCPv4 and DHCPv6 run.

It is also the interface used by the script to force connectivity checks:

```routeros
/ping 1.0.0.1 interface=$iface count=3
```

Forcing the interface is important. It avoids testing the wrong path when the router has multiple WANs, multiple default routes, or policy routing.

---

## 2. DHCPv4 and DHCPv6 Clients

The script expects both DHCP clients to exist on the WAN interface.

It checks the IPv4 DHCP client status:

```routeros
/ip dhcp-client get [find where interface=$iface] status
```

And the IPv6 DHCP client status:

```routeros
/ipv6 dhcp-client get [find where interface=$iface] status
```

Both are expected to be:

```text
bound
```

If either DHCP client is not bound, the WAN is considered failed.

That may look strict, but for a dual-stack ISP connection it is the right operational behavior: if IPv6-PD silently disappears, I want to know and I want the client to recover.

---

## 3. Stable DHCP Client Identifiers

The script uses explicit DHCP client IDs:

```routeros
:local dhclient4ID "0"
:local dhclient6ID "0"
```

Those IDs are used during the reset sequence:

```routeros
/ip/dhcp-client/release numbers=$dhclient4ID
/ipv6/dhcp-client/release numbers=$dhclient6ID
```

In a production configuration, these values must match the actual DHCP client objects.

You can verify them with:

```routeros
/ip dhcp-client print
/ipv6 dhcp-client print
```

This is intentionally explicit.

I prefer explicit identifiers in this kind of script because they reduce ambiguity. The script is written for one WAN at a time, not for auto-discovering and modifying every DHCP client on the router.

---

## 4. Optional ONT Reachability

If the ISP connection goes through an ONT or upstream modem, the script can test its management or local address:

```routeros
:local addrONU "192.168.4.11"
```

Then:

```routeros
/ping $addrONU count=3
```

This test is useful because it separates two different problems:

- the router cannot even reach the local ONT;
- the ONT is reachable, but the ISP path behind it is broken.

The script logs the result, but the ONT test alone is not the only decision point. It is part of the diagnostic picture.

---

## 5. Multiple Public Test Targets

The script does not rely on a single remote IP.

It uses three independent test addresses:

```routeros
:local addrTest1 "1.0.0.1"
:local addrTest2 "9.9.9.10"
:local addrTest3 "8.8.4.4"
```

Each ping test is performed through the WAN interface:

```routeros
/ping $addr interface=$iface count=$countTest
```

A single failed ping target only raises the suspicion level.

The WAN is considered failed only if all configured external tests fail.

This avoids resetting the DHCP client because of a temporary issue with one public resolver or one remote network.

---

## 6. Optional Recursive Route Check

The script includes an optional recursive route test:

```routeros
:local routeRecursive "0"
```

When enabled, it checks whether specific `/32` recursive routes are active.

This can be useful in designs where WAN health is represented by recursive routes toward public test targets.

For example, a router may have recursive routes such as:

```text
1.0.0.1/32 via WAN gateway
9.9.9.10/32 via WAN gateway
8.8.4.4/32 via WAN gateway
```

and default routes that depend on those recursive targets.

In my script, this check is optional because I do not want the watchdog to require one specific routing model. Some environments use recursive routing heavily; others do not.

The script can support both.

---

## What the Script Actually Does

The watchdog follows a simple sequence.

### 1. Initialize Global State

The script stores a few global variables:

```routeros
:global dhclientStatus
:global dhclientRun
:global dhclientResetID
```

`dhclientRun` records the last execution time.

`dhclientStatus` records the latest global health state.

`dhclientResetID` is used as a simple rate limiter to avoid repeated resets during the same hour.

This is not a state machine. It is only minimal operational memory.

The script remains fundamentally simple and mostly stateless.

---

### 2. Detect the Source Address

If no source address is manually defined, the script reads the address configured on the WAN interface:

```routeros
/ip/address print detail as-value where interface=$iface
```

It then strips the prefix length and keeps the bare IP address.

This is useful for logging and diagnostics.

If no source address is found, the script raises a warning and sends an email alert.

A WAN interface without an address is already a strong indication that something is wrong.

---

### 3. Test the ONT

If an ONT address is configured, the script pings it.

This tells me whether the local ISP-facing segment is still reachable.

A failed ONT ping is logged as a warning and recorded in the global status.

---

### 4. Optionally Test Recursive Routes

If recursive route checking is enabled, the script validates that the configured `/32` routes are active.

It does this with retries, which is important on RouterOS because transient route updates can happen during DHCP renewals or interface events.

The script only marks the route status as failed after multiple targets fail.

---

### 5. Test Real WAN Reachability

The most important connectivity test is the forced-interface ping.

The script tests:

```text
1.0.0.1
9.9.9.10
8.8.4.4
```

through the WAN interface.

The logic is intentionally conservative:

- if the first target works, the WAN is considered reachable;
- if the first fails, try the second;
- if the second fails, try the third;
- only if all fail is the ping status marked as failed.

This makes the script robust against false positives.

---

### 6. Verify DHCP Client State

After connectivity tests, the script checks the DHCP clients directly.

For IPv4:

```routeros
/ip dhcp-client get [find where interface=$iface] status
```

For IPv6:

```routeros
/ipv6 dhcp-client get [find where interface=$iface] status
```

If either one is not `bound`, the global status becomes `FAILED`.

This is important because a WAN can sometimes still answer one kind of test while the DHCP state is broken or incomplete.

---

### 7. Log a Summary

Before taking action, the script logs a compact summary:

```text
interface
source address
route status
ping status
DHCPv4 status
DHCPv6 status
global DHCP status
link status
reset ID
```

This is one of the most important operational features of the script.

When troubleshooting WAN issues, I want one log line that explains why the script decided to reset or not reset the interface.

---

### 8. Reset Only When Needed

If the global status is failed, the script performs a controlled reset.

The reset sequence is:

```routeros
/ip/dhcp-client/release numbers=$dhclient4ID
/ipv6/dhcp-client/release numbers=$dhclient6ID
/interface/disable $iface
:delay 3
/interface/enable $iface
```

This is deliberately basic.

It releases the DHCP clients, bounces the interface, and lets RouterOS and the ISP rebuild the session cleanly.

No firewall rules are changed.

No NAT rules are changed.

No route policy is rewritten.

The script fixes the failing WAN edge condition and lets the rest of the router configuration do its job.

---

## Reset Rate Limiting

One small but important safeguard is the reset limiter.

The script stores the current hour in:

```routeros
:global dhclientResetID
```

Before resetting, it checks whether a reset has already happened during the same hour.

If yes, it skips the reset:

```text
skipping reset interface ...
```

This prevents the router from entering an endless flap loop if the ISP is genuinely down.

That is a critical difference between a useful watchdog and a dangerous one.

A watchdog should recover from transient failures, not make a persistent outage worse by continuously bouncing the interface.

---

## Alerts

The script sends email alerts for important events, such as:

- missing source address;
- completed reset;
- email send failure is itself logged as a warning.

This is enough for my use case.

I do not need a full monitoring stack inside RouterOS. I only need to know when the watchdog had to intervene.

---

## Existing Alternatives

There are several other ways to solve WAN monitoring and DHCP recovery.

Some are more powerful. Some are more elegant on paper. Some are also much more complex.

---

## Alternative 1: Netwatch

RouterOS includes Netwatch, which can monitor a remote host and run scripts on up/down transitions.

For simple cases, Netwatch is perfectly fine.

However, a single Netwatch target is often too simplistic for a real WAN health decision.

It usually answers only one question:

> Can I reach this one host?

My script answers several questions:

- is the WAN interface address present?
- is the ONT reachable?
- are recursive routes active, if enabled?
- can several public targets be reached through the WAN interface?
- is DHCPv4 bound?
- is DHCPv6 bound?
- has the interface already been reset recently?

That is a more complete decision model while still remaining simple.

---

## Alternative 2: Recursive Routing Only

Recursive routes are a common and powerful RouterOS technique.

They are excellent for dynamic failover between multiple WANs.

But recursive routing does not necessarily repair a broken DHCP client.

It can remove a route from service when a target is unreachable, but it does not automatically release and restart DHCPv4/DHCPv6 clients or bounce the WAN interface.

In other words, recursive routing is good at selecting a path.

This script is about recovering a broken WAN attachment.

Those are related problems, but not the same problem.

---

## Alternative 3: Full Multi-WAN Frameworks

A full multi-WAN design can include:

- multiple routing tables;
- recursive next-hop checks;
- firewall marks;
- connection marks;
- routing marks;
- per-WAN NAT rules;
- scheduled scripts;
- dynamic route distances;
- failback logic;
- external monitoring.

This can be extremely powerful.

It can also become hard to reason about.

When a failure happens, the question becomes:

- did the route fail?
- did the mark fail?
- did connection tracking pin the flow?
- did NAT use the expected WAN?
- did the DHCP client lose its lease?
- did IPv6-PD disappear?
- did the script race with another script?

For some environments, that complexity is justified.

For this specific watchdog, I intentionally avoided that path.

---

## Alternative 4: External Monitoring System

Another option would be to monitor the router externally with Prometheus, Zabbix, LibreNMS, or a custom script from another host.

That is useful for visibility.

But an external monitor may not be able to safely repair the MikroTik WAN state.

Also, if the WAN is broken, the monitoring path may be broken too.

I prefer the recovery mechanism to live directly on the router, close to the resource it controls.

External monitoring can still observe and alert, but the router can perform the local repair by itself.

---

## Why I Chose KISS

This script follows a simple principle:

> Keep It Simple, Stupid.

The goal is not to build a clever routing controller.

The goal is to recover from a known class of WAN failures with the least moving parts possible.

The script is intentionally:

- small;
- readable;
- explicit;
- easy to disable;
- easy to test manually;
- independent from firewall rules;
- independent from NAT policy;
- independent from complex route marking;
- conservative before taking action;
- rate-limited to avoid flapping.

That is why I like this design.

It does not try to own the whole router.

It only owns one operational responsibility:

> check whether this WAN DHCP client is healthy, and restart it if it is clearly broken.

Everything else remains handled by the normal RouterOS configuration.

---

## Stateless by Design

Strictly speaking, the script keeps a few global variables.

But it does not maintain a complex state machine.

There is no database of previous failures.

There is no multi-step failover history.

There is no persistent decision tree.

Each run mostly evaluates the current state of the router:

- current interface address;
- current ping results;
- current route state;
- current DHCP status.

The only retained value that really matters is the last reset hour, used to prevent repeated resets.

This makes the script easy to reason about.

If the current state is healthy, do nothing.

If the current state is clearly broken, reset once.

If the failure persists, stop flapping and let the logs show the outage.

That is exactly the behavior I want from an infrastructure watchdog.

---

## Operational Benefits

This approach has several practical advantages.

First, it is transparent. The logs clearly show what was tested and why a reset happened.

Second, it is conservative. It does not reset the WAN because of one failed ping.

Third, it is dual-stack aware. IPv4 and IPv6 DHCP states are both checked.

Fourth, it is local. The router can repair its own WAN client without depending on another host.

Fifth, it is safe. The reset is rate-limited and does not touch unrelated firewall or routing policy.

Finally, it is maintainable. There are no hidden dependencies and no complex daemon to debug.

---

## Example Failure Flow

A typical failure flow looks like this:

1. the script starts and records the execution time;
2. the WAN interface source address is read;
3. the ONT is pinged;
4. recursive routes are skipped or checked depending on configuration;
5. public test targets are pinged through the WAN interface;
6. DHCPv4 status is checked;
7. DHCPv6 status is checked;
8. a summary log line is written;
9. if the status is failed and no reset happened this hour, DHCP clients are released;
10. the WAN interface is disabled;
11. the script waits three seconds;
12. the WAN interface is enabled again;
13. an email notification is sent.

This is simple, deterministic, and easy to troubleshoot.

---

## What This Script Does Not Do

It is also important to be clear about what the script does not do.

It does not implement full multi-WAN failover.

It does not manipulate firewall rules.

It does not rewrite NAT rules.

It does not change connection tracking.

It does not dynamically reprioritize all routes.

It does not try to be a routing daemon.

It does not decide which WAN should be preferred.

It only checks and repairs one WAN DHCP client.

That limited scope is a feature, not a weakness.

---

## Lessons Learned

The main lesson is that WAN health is not a single signal.

A link can be up while DHCP is broken.

A DHCP client can be bound while the upstream path is broken.

One ping target can fail while the WAN is fine.

IPv4 can work while IPv6-PD is broken.

A good watchdog should combine several weak signals into one conservative decision.

The second lesson is that recovery logic should be boring.

When the network is failing, I do not want a clever script. I want a predictable script.

The third lesson is that rate limiting matters.

Without it, a watchdog can become part of the outage.

---

## Conclusion

The `check-dhclient` script is a small RouterOS watchdog for DHCP-based WAN links.

It checks the local WAN address, optional ONT reachability, optional recursive routes, external connectivity through the WAN interface, and both DHCPv4 and DHCPv6 client states.

When the WAN is clearly failed, it releases the DHCP clients and bounces the interface.

It does this without touching firewall rules, NAT policy, or global routing architecture.

The design is intentionally KISS:

- simple checks;
- explicit interface;
- explicit DHCP clients;
- multiple test targets;
- minimal state;
- clear logs;
- reset rate limiting;
- local recovery.

There are more sophisticated ways to build WAN monitoring and failover.

But for this problem, I prefer a small, robust, stateless watchdog that does one thing well.

Sometimes the best infrastructure code is not the most advanced one.

It is the one you can still understand at 2 a.m. when the WAN is down.

# Linux Multi-WAN Watchdog
# Building a Route-Oriented Multi-WAN Watchdog for a Linux Firewall Router


Running a Linux firewall as the main router gives a level of control that is difficult to achieve with most commercial appliances.

It also means that you own the failure modes.

In my home infrastructure, the router is not only a firewall. It is also responsible for multiple WAN links, IPv4 and IPv6 routing, policy routing, dynamic failover, and service reachability from several internal VLANs.

The firewall itself is implemented with `nftables`, but the watchdog described here is deliberately **not an nftables watchdog**.

It does not primarily manipulate firewall rules.

Instead, it monitors real routing paths and changes the Linux routing state when a WAN path becomes unusable or comes back online.

That distinction is important.

Firewalling decides what is allowed. Routing decides where traffic actually goes.

This post describes the design behind my [check-route.sh](https://codeberg.org/cyayon/cyasssw/src/branch/main/linux/check-route.sh) script, a shell-based route watchdog used on a Linux firewall router to monitor WAN paths, remove failed active routes, restore them when connectivity returns, and keep deterministic fallback routes in place.

---

## The Objective

The goal of the script is to supervise WAN routes on a Linux router and keep the routing state coherent.

For each monitored WAN path, the script can:

- check physical or virtual interface status;
- test real connectivity using IPv4 and/or IPv6 probes;
- verify the presence of the active route in the main routing table;
- verify the presence of a persistent fallback route;
- verify per-WAN routing tables;
- verify source-based policy routing rules;
- remove a failed active route;
- restore a route when the WAN comes back;
- trigger auxiliary commands such as dynamic DNS updates;
- export status for monitoring systems such as Prometheus node exporter;
- run continuously as a background watchdog.

The script is meant for a router where WAN failover is route-driven.

The firewall may be very advanced, but the failover decision itself is made by manipulating routes, not by rewriting firewall rules.

---

## Why Route-Based Failover?

Many multi-WAN setups are implemented by marking packets in the firewall and then forcing traffic into different routing tables.

That is a valid design, and I also use policy routing where it makes sense.

However, for the default WAN path, I wanted a simpler and more deterministic model:

```text
The currently usable WAN owns the preferred default route.
If it fails, its active route is removed.
If it recovers, its active route is restored.
```

This keeps the kernel routing table as the source of truth.

Applications, services, and local router traffic do not need to understand the failover logic. They simply follow the best route currently installed in the routing table.

In this model, the watchdog is responsible for ensuring that the routing table reflects reality.

---

## Technical Prerequisites

This design assumes a Linux router with a reasonably advanced network configuration.

Before using this kind of watchdog, the following concepts should already be in place.

---

## 1. Multiple WAN Interfaces

The router must have one or more WAN interfaces.

They can be physical interfaces, VLANs, PPP links, LTE routers, WireGuard tunnels, or any other Linux network interface.

Example:

```text
wan1      primary physical WAN
wan2      secondary physical WAN
mlkw0     VPN or tunnel-based fallback path
```

The script does not require all WANs to be the same type.

It only needs an interface name, a destination route, a gateway, a metric, and optionally a routing table.

---

## 2. Persistent Routes per WAN

A key design choice is that each real WAN path has **two routes**:

1. an active route;
2. a persistent fallback route.

The active route is the route that participates in normal routing decisions.

The persistent route uses a higher metric and is normally not selected. It exists as a stable anchor for fallback and recovery logic.

Example for IPv4:

```sh
ip route replace default via 192.168.2.7 dev wan1 metric 0
ip route replace default via 192.168.2.7 dev wan1 metric 2000
```

The first route is active.

The second route is persistent.

The watchdog is allowed to remove or restore the active route.

The persistent route is intentionally kept in place and should not be modified during normal failover.

This makes the routing model safer:

- the active route can be removed when a WAN fails;
- the persistent route remains available as a known fallback reference;
- the system does not lose all knowledge of the WAN path;
- recovery is easier and more deterministic.

In my configuration, this persistent route is defined with:

```sh
MetricPersist="2000"
```

---

## 3. Per-WAN Routing Tables

The router also uses dedicated routing tables for WAN-specific routing.

For example, WAN1 uses table `100`:

```sh
Table="100"
```

The watchdog verifies and restores the route in this table:

```sh
ip route replace default via 192.168.2.7 dev wan1 table 100
ip -6 route replace default via fd11:0:0:2::7 dev wan1 table 100
```

This is useful when some traffic is routed by source address, firewall mark, service, VLAN, or policy rule.

The main routing table decides the default behavior.

The per-WAN tables allow deterministic routing when a specific path must be selected explicitly.

---

## 4. Source-Based Policy Routing

For advanced routing, the script can also verify and restore `ip rule` entries.

The design supports variables such as:

```sh
RuleFrom="192.168.x.y"
```

and then checks rules like:

```sh
ip rule show from 192.168.x.y lookup 100 prio 100
```

The rule priority is intentionally aligned with the routing table number in the script.

That keeps the design easy to inspect:

```text
WAN1 table: 100
WAN1 rule priority: 100
```

For a router with multiple internal VLANs, this makes policy routing readable and predictable.

---

## 5. Internal Subroutes in the WAN Table

A WAN-specific routing table should not only contain the default route.

It often also needs routes back to internal networks.

Otherwise, traffic forced into that table may lose reachability to local VLANs.

The script supports `SubRoute4` and `SubRoute6`.

Example from the WAN1 configuration:

```sh
SubRoute4="192.168.42.0/24 192.168.40.0/24 192.168.9.0/24 192.168.88.0/24 192.168.2.0/24 192.168.6.0/24"
```

For IPv6:

```sh
SubRoute6="fd11:0:0:42::/64 fd11:0:0:40::/64 fd11:0:0:9::/64 fd11:0:0:88::/64 fd11:0:0:2::/64 fd11:0:0:6::/64"
```

The script tries to find the appropriate local interface for each subroute and installs the route in the WAN-specific table.

This is important when using policy routing.

A routing table must be complete enough to route both outbound traffic and local return traffic.

---

## 6. IPv4 and IPv6 Dual-Stack Monitoring

The script supports IPv4, IPv6, or both.

The configuration can use:

```sh
Proto="4"
Proto="6"
Proto="64"
```

With `Proto="64"`, the script checks both protocols.

Protocol-specific variables can override the generic ones:

```sh
Via4="192.168.2.7"
Via6="fd11:0:0:2::7"
CheckPing_dest4="1.1.1.1 8.8.8.8 9.9.9.9"
CheckPing_dest6="2606:4700:4700::1111 2a07:a8c0:: 2a07:a8c1::"
```

This is important because IPv4 and IPv6 do not always fail in the same way.

A WAN may still have IPv4 while IPv6 is broken, or the opposite.

Treating both protocols independently avoids hiding partial failures.

---

## 7. Connectivity Checks Bound to the WAN Path

A route watchdog should not simply ping from the router without constraints.

If the router has multiple WANs, a normal ping may succeed through another path and hide the failure.

The script uses ping with an explicit source interface or source address:

```sh
ping -4 -I wan1 -c 2 -n -W 4 1.1.1.1
ping -6 -I wan1 -c 2 -n -W 4 2606:4700:4700::1111
```

By default, the script uses the monitored interface as the ping source.

It can also be configured to use a specific source IP address.

This is essential.

The watchdog must test the WAN path itself, not just general Internet reachability from the router.

---

## 8. A Linux Router with Deterministic Metrics

The design assumes that default route metrics are meaningful.

For example:

```text
metric 0       active primary route
metric 2000    persistent fallback route
metric 4000    lower-priority tunnel route
```

The exact numbers are not important.

What matters is that the metric hierarchy is intentional.

The watchdog only manipulates the active route for a given WAN, while the persistent route remains present with a higher metric.

---

## Configuration Example: WAN1

Here is a simplified example based on my `check-route@wan1.conf` file.

```sh
Iface="wan1"
Dest="default"
Metric="0"
Proto="64"
Table="100"
MetricPersist="2000"

CheckPing_count="2"
CheckPing_wait="4"
StepExec="30"

Via4="192.168.2.7"
SubRoute4="192.168.42.0/24 192.168.40.0/24 192.168.9.0/24 192.168.88.0/24 192.168.2.0/24 192.168.6.0/24"
CheckPing_dest4="1.1.1.1 45.90.28.0 45.90.30.0 8.8.8.8 9.9.9.9"

Via6="fd11:0:0:2::7"
SubRoute6="fd11:0:0:42::/64 fd11:0:0:40::/64 fd11:0:0:9::/64 fd11:0:0:88::/64 fd11:0:0:2::/64 fd11:0:0:6::/64"
CheckPing_dest6="2606:4700:4700::1111 2a07:a8c0:: 2a07:a8c1::"
```

This tells the watchdog:

- monitor interface `wan1`;
- monitor the default route;
- manage both IPv4 and IPv6;
- use the active route metric `0`;
- keep a persistent route with metric `2000`;
- maintain WAN-specific routing table `100`;
- test multiple external IPv4 and IPv6 destinations;
- keep local VLAN routes present in the WAN-specific table.

---

## State Machine

The script is built around a small operational state machine.

The main states are:

```text
UP       everything is healthy
DOWN     the route or connectivity is down
LINK     the interface carrier or route is link-down
START    the route should be restored
STOP     the active route should be removed
RELOAD   the interface or network stack should be refreshed
ERROR    an operation failed
UNKNOWN  initial or undefined state
```

The `status` function evaluates the current situation.

The `auto` action then decides what to do:

```text
UP       do nothing
DOWN     stay in failover mode
LINK     report link issue
START    restore the route
STOP     remove the active route
RELOAD   bring the interface up and run reload hooks
```

This makes the script more than a simple ping loop.

It evaluates several layers before taking action.

---

## What the Watchdog Checks

For each protocol, the script checks several independent signals.

### 1. Interface link state

It detects `NO-CARRIER` on the monitored interface.

If the link is physically down, the script does not waste time interpreting ping failures as normal packet loss.

### 2. Active route

It verifies that the active route exists in the main routing table:

```sh
ip route show default via 192.168.2.7 dev wan1 metric 0
```

or for IPv6:

```sh
ip -6 route show default via fd11:0:0:2::7 dev wan1 metric 1024
```

### 3. Persistent route

It verifies that the higher-metric persistent route exists:

```sh
ip route show default via 192.168.2.7 dev wan1 metric 2000
```

This route is not normally selected, but it should remain present.

### 4. WAN-specific routing table

It verifies the default route in the dedicated table:

```sh
ip route show default via 192.168.2.7 dev wan1 table 100
```

### 5. Internal subroutes

It verifies that internal VLAN routes exist in the WAN table.

This prevents policy-routed traffic from becoming isolated from local networks.

### 6. Source policy rules

If configured, it verifies the `ip rule` entries associated with the WAN table.

### 7. Real connectivity

It pings several external destinations through the monitored interface.

The check succeeds if at least one configured destination responds.

This avoids false negatives caused by a single remote probe being unavailable.

### 8. Optional custom status command

The script can also run a custom status command through `StatusExec`.

This allows the routing health decision to include external checks specific to the environment.

---

## Start: Restoring a WAN Path

When the watchdog decides that a WAN path should be restored, it runs the `start` logic.

The start operation can:

- restore the active main route;
- restore the persistent route if it is missing;
- restore the route in the WAN-specific table;
- restore internal subroutes in the WAN-specific table;
- restore source-based policy rules;
- flush the route cache;
- run a `StartExec` hook.

Conceptually, the main route is restored like this:

```sh
ip route replace default via 192.168.2.7 dev wan1 metric 0
```

The persistent route is also checked and restored if needed:

```sh
ip route replace default via 192.168.2.7 dev wan1 metric 2000
```

The WAN-specific table is restored:

```sh
ip route replace default via 192.168.2.7 dev wan1 table 100
```

This is recovery without guessing.

The script re-installs the expected routing state.

---

## Stop: Removing a Failed Active Route

When the WAN is considered unusable, the watchdog removes only the active route:

```sh
ip route del default via 192.168.2.7 dev wan1 metric 0
```

The persistent route is preserved or restored if missing:

```sh
ip route replace default via 192.168.2.7 dev wan1 metric 2000
```

This is the core of the design.

The active route is the operational route.

The persistent route is a fallback and recovery anchor.

Removing the active route lets Linux select another lower-priority but healthy route.

Keeping the persistent route avoids losing the WAN definition entirely.

---

## Reload: Repairing an Inconsistent State

Not every problem is a clean up/down transition.

Sometimes the route looks partially correct, but the network stack or interface state is inconsistent.

For that case, the script has a `RELOAD` state.

The reload action brings the interface up:

```sh
ip link set up dev wan1
```

and can run a custom `ReloadExec` command.

In my WAN1 configuration, IPv6 uses a reload hook to remove a temporary unreachable route and reconfigure the interface:

```sh
ReloadExec="ip -6 route del table main unreachable ::/0 metric 1500 ; networkctl reconfigure $Iface"
```

This is useful when the interface is physically present but needs a network stack refresh.

---

## IPv6-Specific Handling

IPv6 failure modes can be different from IPv4.

On my setup, `wan1` is the only true physical IPv6 WAN path.

When it is down, the script can install an unreachable IPv6 default route:

```sh
ip -6 route replace table main unreachable ::/0 metric 1500
```

The goal is to explicitly disable broken IPv6 routing while still allowing a controlled fallback route with a different priority.

When IPv6 comes back, the route is removed:

```sh
ip -6 route del table main unreachable ::/0 metric 1500
```

This avoids a common dual-stack problem: IPv6 appears available enough for applications to try it, but not healthy enough to work reliably.

In that situation, explicit unreachable routing can be better than silent blackholing.

---

## Hooks for External Systems

The script is not limited to route manipulation.

It supports several hook points:

```sh
BootExec
StatusExec
StopExec
StartExec
ReloadExec
CronExec
CronDownExec
CronUpExec
```

Each hook can also be protocol-specific:

```sh
StartExec4
StartExec6
StopExec4
StopExec6
CronExec4
CronExec6
CronDownExec4
CronDownExec6
```

In the WAN1 example, these hooks are used to update dynamic DNS state depending on whether the route is up or down.

For example:

```sh
StartExec4="/jobs/DynhostMGR -C /etc/nbux/dynhost_cordon_nbux_org.conf -p 4"
StopExec4="/jobs/DynhostMGR -C /etc/nbux/dynhost_cordon_nbux_org.conf -i mlkw0 -p 4"
```

That allows the router to keep external DNS aligned with the currently usable path.

The watchdog therefore becomes a small orchestration point for route-dependent services.

---

## Daemon Mode

The script can run once, or it can run continuously in daemon mode.

A one-shot status check looks like this:

```sh
check-route -a status -C /etc/nbux/check-route@wan1.conf
```

A continuous watchdog run uses the `auto` action with a daemon sleep interval:

```sh
check-route -a auto -C /etc/nbux/check-route@wan1.conf -D 10
```

In daemon mode, the script loops forever:

1. select IPv4 and/or IPv6;
2. load protocol-specific variables;
3. evaluate status;
4. decide whether to start, stop, reload, or do nothing;
5. run periodic hooks when required;
6. sleep;
7. repeat.

This is intentionally simple.

The script does not need a database or a complex controller.

The Linux routing table is the controller state.

---

## Logging, Locking and Status Files

The script writes logs under:

```text
/var/log/nbux
```

Runtime files are stored under:

```text
/run/check-route
```

Lock files are stored under:

```text
/tmp/check-route
```

Each monitored route gets its own PID file, lock file, log file, and status file.

This matters when running several instances, for example one per WAN and per monitored route.

The script prevents two instances from managing the same route at the same time by using a lock file.

If required, the lock can be removed with:

```sh
check-route -a unlock -C /etc/nbux/check-route@wan1.conf
```

---

## Prometheus / Node Exporter Integration

The script can export a status metric into a textfile collector directory:

```text
/tmp/node_exporter
```

The generated metric looks like this conceptually:

```text
checkroute_wan1_default_4{interface="wan1",protocol="4",route="default",metric="0"} 0
```

The value is the internal status code.

For example:

```text
0 = UP
1 = DOWN
2 = LINK
3 = RELOAD
4 = ERROR
5 = UNKNOWN
6 = STOP
7 = START
```

This makes it possible to graph route health over time and alert on degraded states.

For a router, that is much more useful than only knowing whether the host itself is up.

---

## Alert Throttling

A route watchdog can become noisy if a WAN is unstable.

To avoid notification storms, the script tracks repeated abnormal states within the same hour.

The configuration variable is:

```sh
MaxRepeat="3"
```

After too many repeated identical failures, the script limits alerts while continuing to log and operate.

This is an important operational detail.

A watchdog should be loud when a state changes, but not uselessly noisy when the same failure continues for a long time.

---

## Why the Persistent Route Matters

The persistent route is the most important part of the design.

Without it, failover scripts often fall into one of two bad patterns.

Either they remove the route completely and later have to reconstruct it from scratch, or they leave a broken route installed and traffic keeps trying to use it.

This design separates the two concerns:

```text
Active route       used by normal routing decisions
Persistent route   kept as a stable fallback/recovery object
```

The watchdog is allowed to manipulate the active route.

The persistent route remains a stable representation of the WAN path.

It is not meant to win normal routing decisions because its metric is higher.

But it keeps the path known to the system.

That makes failover safer and recovery easier.

---

## Relationship with nftables

The router uses `nftables`, but this script does not depend on nftables to perform failover.

That is intentional.

`nftables` can still be used for:

- firewall policy;
- connection tracking;
- packet marking;
- NAT;
- anti-scan or anti-DDoS rules;
- multi-WAN classification when needed.

But this watchdog focuses on route health.

When the default WAN route is removed, Linux naturally selects the next valid route based on metrics and routing policy.

This keeps the failover mechanism independent from the firewall policy.

In practice, that separation makes troubleshooting easier:

```text
If packets are blocked, inspect nftables.
If packets choose the wrong WAN, inspect routes and rules.
```

That separation of responsibilities is one of the reasons I prefer this design.

---

## Example Operational Flow

Assume WAN1 is healthy.

The routing table contains:

```sh
ip route show default via 192.168.2.7 dev wan1 metric 0
ip route show default via 192.168.2.7 dev wan1 metric 2000
```

The watchdog checks connectivity through `wan1`.

At least one probe succeeds.

The route remains active.

Now assume WAN1 loses upstream connectivity, but the interface is still electrically up.

The route still exists, but probes fail.

The watchdog enters `STOP` state and removes the active route:

```sh
ip route del default via 192.168.2.7 dev wan1 metric 0
```

The persistent route remains:

```sh
ip route show default via 192.168.2.7 dev wan1 metric 2000
```

Linux now selects another usable default route with a better effective priority.

When WAN1 connectivity returns, the watchdog enters `START` state and restores the active route:

```sh
ip route replace default via 192.168.2.7 dev wan1 metric 0
```

Normal routing resumes through WAN1.

---

## Lessons Learned

A few practical lessons came out of this design.

First, do not test Internet reachability in a multi-WAN router without binding the probe to the WAN being tested.

Second, do not mix firewall policy and route health more than necessary.

Third, a missing route and a failed route are not the same condition.

Fourth, a persistent high-metric route is a simple but powerful recovery anchor.

Fifth, IPv4 and IPv6 need to be monitored independently.

Finally, a watchdog should not only take action. It should also explain its decisions through logs, status files, and metrics.

---

## Conclusion

This script is not a generic “ping and failover” snippet.

It is a route-oriented watchdog for a Linux firewall router using multiple WAN paths, dual-stack routing, per-WAN routing tables, persistent fallback routes, and optional service hooks.

Its core idea is simple:

```text
Do not guess the correct WAN state.
Continuously validate it.
Then make the routing table reflect reality.
```

For a small network, this may be unnecessary.

For a segmented home lab or a production-like home infrastructure, it gives a level of control and observability that is hard to get from black-box router appliances.

The result is a firewall router where failover is explicit, inspectable, and reversible.

That is the kind of design I want at the center of my network.

#publish #blog/cyasssw/linux
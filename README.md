# Bubble

This repository is the foundation of Bubble, a nearby wireless discovery and
network assessment app derived from Device Scanner. See [BUBBLE.md](BUBBLE.md)
for the Android features, limitations, build instructions and S21 Ultra checks.

The original Python network inventory tool is retained below.

# netinv

A LAN device **discovery + fingerprinting** core: the highest effort-to-payoff
piece of a network-onboarding tool. It finds devices on the local network,
fuses several signals into one record per host, and makes a first guess at
each device's role. Standard library only (optional data file for OUI).

> **Authorized use only.** Run this only on networks and devices you own or
> are explicitly authorized to manage. Discovery and fingerprinting are
> observational; the optional admin-interface probe is read-only and never
> changes device state, and the default-credential audit sends no login
> attempt unless you assert ownership (`--i-own-these`).

## Install

```bash
pip install -e .        # from the repo root; adds a `netinv` command
```

Or run without installing, from the repo root:

```bash
python -m netinv
```

## Run

```bash
python -m netinv                     # 4s passive scan, table output
python -m netinv --sweep             # also ping-sweep the subnet for silent hosts
python -m netinv --json              # machine-readable (incl. match reasons)
python -m netinv --oui manuf         # full vendor names (see below)
python -m netinv --probe             # read-only probe of HTTP admin interfaces
python -m netinv --probe-defaults --i-own-these   # audit for default creds
```

Passive discovery uses multicast, so run it on a host **joined to the LAN** —
a container/VM with NAT networking usually can't see the multicast groups and
will come back empty. `--sweep` adds active ICMP probing of the local subnet.

## The signals (`discovery/`)

| Module     | Protocol        | Contributes                          |
|------------|-----------------|--------------------------------------|
| `ssdp.py`  | UPnP / SSDP     | model, manufacturer, deviceType URNs |
| `mdns.py`  | mDNS / DNS-SD   | hostname, advertised service types   |
| `sweep.py` | ICMP + subnet   | silent hosts multicast never reveals |
| `arp.py`   | ARP cache       | MAC address (via ping-prime + read)  |
| `oui.py`   | IEEE OUI table  | manufacturer from the MAC            |

No single signal is reliable alone; `model.py` merges them per IP into one
`Device`, and the fingerprint engine scores the combined evidence.

## Fingerprinting (`fingerprint/`)

`signatures.py` is a database of device signatures; `engine.py` scores each
device against all of them. Every satisfied condition (vendor, model string,
service set, UPnP device type) adds weighted points; the best signature above
a floor becomes the `classification`, with a `confidence` that saturates once
several strong signals agree. A bare vendor match still labels the device, but
honestly — low confidence. Unmatched devices fall back to a coarse heuristic
category (`Device.role_guess`).

Add coverage by appending dicts to `SIGNATURES` — no engine changes needed.
Each carries an informational `notes` field (e.g. where the admin UI lives);
it is never a credential.

## Full OUI coverage

The built-in vendor table is a handful of entries. For real coverage, point
`--oui` at either:

- Wireshark's `manuf` file, or
- the IEEE `oui.txt` registry (`standards-oui.ieee.org/oui/oui.txt`).

Both formats are auto-detected.

## Drivers (`drivers/`)

Opt-in, device-class modules that *talk to* a device, selected per host by a
registry. The one shipped driver, **`http_admin.py`, is read-only** — it
reports and never changes device state:

- reachability + which port/scheme serves the admin UI;
- the access gate: HTTP Basic/Digest, a login form, or **nothing** (an
  unauthenticated admin page is reported as a security *alert*);
- a **default-credential audit** that is doubly gated — pass `--probe-defaults`
  *and* `--i-own-these`. It only tests side-effect-free HTTP Basic/Digest GETs;
  login *forms* are detected but never auto-submitted (POSTing risks config
  changes and lockouts). Findings are graded `[!]` alert / `[~]` warn / `[ ]` info.

The audit uses a tiny built-in list of universal defaults; point `--candidates`
at a larger authorized list (e.g. SecLists) in `user:password` per-line format.

> This layer is for devices you own or are authorized to manage. The audit
> refuses to send a credential unless you assert that.

Add a driver by subclassing `base.Driver` and calling `registry.register()`.

## Where this grows next

Discovery, fingerprinting, and a read-only driver are here. The follow-ons:

- **more drivers** — SSH, SNMP, TR-069; and, clearly separated behind their own
  opt-in, *write* drivers for devices you administer.
- **`provision/`** — declarative desired-state applied through the drivers.

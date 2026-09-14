## Platform Buckets (experimental — not yet part of `quartz-docs-rules.md`)

This is a candidate rule for the `Homelab` domain specifically. It is kept in its own file because it hasn't been decided yet whether it should be folded into the main `quartz-docs-rules.md` as a permanent rule, or whether it's specific enough to `Homelab` that it should stay a domain-local convention. Treat it as authoritative for `Homelab` until told otherwise, but don't assume it generalizes to other domains unless it's later merged into the main rules file.

### The problem this solves

A domain like `Homelab` where many OSes and services all run as guests on a hypervisor tends to overload a single flat `Software/` bucket as more services get added — it becomes a long, undifferentiated list with no indication of which services actually run together on the same machine.

### The rule

Instead of one flat `Software/` bucket, `Homelab` uses a **`Platform/`** bucket. Each entry under `Platform/` represents one virtualization host or VM — a physical or logical machine that runs a guest OS plus zero or more services on top of it. A platform entry bundles:

- the guest OS's own bucket (install/setup/gotchas for the OS itself — see the guest-OS-separation rule in `quartz-docs-rules.md` §3), and
- one bucket per service that runs on that guest OS.

Example shape:

```text
Platform/
├── Productivity-VM/
│   ├── Debian/              (the guest OS itself)
│   ├── Nextcloud/
│   ├── Stirling-PDF/
│   └── ConvertX/
├── Local-AI-VM/
│   ├── Fedora/
│   ├── Llama.cpp/
│   ├── Open-WebUI/
│   └── SearXNG/
└── ...
```

Hardware entries (physical machines: the Proxmox host itself, the OpenMediaVault box, the router) still live under `Hardware/` as before — `Platform/` is specifically for the VM-and-what's-on-it grouping, not a replacement for `Hardware/`.

Cross-cutting Logical entries (addressing plan, VM allocation roster, the Podman-vs-Docker rationale, etc.) still live under `Logical/` as before — `Platform/` doesn't absorb those either.

### Source of truth for the grouping

`Homelab/Images/homelab-architecture-diagram.png` (migrated from `Other Notes/Homelab.png`) is the current planning diagram for which services belong to which platform/VM. Use it to decide platform boundaries and to catch services that are planned but not yet documented (don't create empty buckets for services shown in the diagram that haven't actually been set up yet — see the Migration Q&A entries already on file for the Monitoring VM and Arrrrgh VM for the standard of "OS installed, nothing configured yet, no bucket beyond a roster mention").

### Naming

Platform bucket folder names describe the VM's role (`Productivity-VM`, `Local-AI-VM`, `Personal-VM`, `Monitoring-VM`, `Arrrrgh-VM`), matching the VM names already used in `Logical/Virtual-machines/Vm-allocation.md` and the diagram — sentence-kebab-case per the main naming rules (§16).

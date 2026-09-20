# Quartz Docs Rules: Adding New Entries

These rules cover adding new content to the existing wiki. They assume the vault already has its structure and that the new content arrives as a source document (a guide, notes, a draft, or a reference the user provides).

They do not cover converting legacy blog posts. Those rules stay in `quartz-docs-rules.md`.

---

## 1. Concept-First Organization

- Organize documentation by **what the documentation is about**, not by the shape of the source document that produced it.
- A source document is **source material, not the destination structure**.
- Decompose the source and redistribute its useful content into the correct buckets.
- Merging, splitting, adding, renaming, or deleting topics is expected when it improves discoverability, isolation, or usefulness.
- Never create a folder or page merely because a source document exists.
- A single source document may contribute to many buckets.
- Multiple source documents may contribute to one bucket or page.
- Historical context such as "failed attempt," "old," or "current" should normally be represented with page titles, tags, or a Lessons Learned/Gotchas section, not by creating a bucket whose only purpose is to record history.

---

## 2. Structure Is Allowed to Evolve

The structure is **content-driven, not fixed**.

Whenever a new entry is added, it may:

- create a new entry;
- merge two or more existing entries;
- split an existing entry into multiple entries;
- move content between entries;
- rename an entry;
- delete an entry that is no longer useful;
- turn a standalone entry into part of another entry;
- cause an existing sequence to be reorganized into a different sequence structure.

These changes are encouraged whenever the new content makes the resulting documentation easier to understand, search, maintain, and navigate.

### Decision rule

Do not ask:

> "Where does this new document fit into the existing tree?"

Ask:

> "Given all the content now available, what structure makes the most sense?"

The existing tree is a starting point, **not a constraint**.

A new piece of content is allowed to change the tree if doing so produces a better information architecture.

---

## 3. Hardware, Software, and Logical Buckets

If a domain contains at least two hardware entries **and** at least two entries that are software or logical (in any combination), the domain groups its entries into Hardware, Software, and Logical buckets. A domain with only hardware+software entries, or only hardware+logical entries, still splits into those groupings; the Logical grouping only appears as a bucket if the domain has at least one Logical entry.

### Hardware buckets

A hardware bucket represents one concrete physical item.

Examples:

```text
Hardware/
├── Asus-X555q/
├── Dell-Optiplex-5060/
└── Dell-Vostro-260s/
```

### Software buckets

A software bucket represents one software, operating system, service, tool, or script that the user uses.

```text
Software/
├── Proxmox/
├── Nginx/
├── Nextcloud/
└── BorgBackup/
```

### Logical buckets

A logical bucket represents a cross-cutting system, policy, or convention that isn't a concrete physical item and isn't a single installed software/OS/service. Examples are network addressing schemes, subnetting plans, naming conventions, or other shared logical structure that spans multiple hardware and software entries.

Examples:

```text
Logical/
└── Home-network/
    ├── Glossary.md
    ├── Addressing-plan.md
    ├── Subnets.md
    ├── Dhcp.md
    └── Connectivity-testing.md
```

### A guest OS gets its own bucket, separate from what runs on it

When a hardware or virtualization host (e.g. a Proxmox VM, a physical machine) runs a guest OS that in turn hosts several distinct services, the guest OS's own installation, setup, and gotchas get their own dedicated bucket, separate from the buckets for the services running on top of it. Do not lump OS-level material (install steps, firewall/SELinux defaults, package manager quirks, OS-level troubleshooting) into whichever service bucket happened to be written first, or into a "random" service's bucket merely because that's where the OS was first mentioned. If a fact is about the OS itself (would still be true with no services installed on it), it belongs in the OS's own bucket; if it's about a specific service's behavior, it belongs in that service's bucket.

### Cross-cutting technology-choice reasoning belongs in Logical, not in any one service

When a single technical decision applies uniformly across multiple software entries (e.g. "why Podman instead of Docker" for every containerized service in a domain), the reasoning for that decision belongs in its own entry under the **Logical** bucket, not repeated in, or attached to, any one of the individual service buckets it happens to apply to. Each service bucket should simply link to that Logical entry rather than re-explaining or duplicating the reasoning.

### Decision rule

Some entries can be confusing to place. An example is a bash script that automatically tweaks some features when the battery is disconnected. While the bash script might make this fall under the software bucket, it actually belongs in the hardware bucket. The reason is that the script's end goal is to improve the physical item's battery usage.

When confused between Hardware and Software, ask yourself:

> What does the entry interact with?
> What is the end goal for the entry?

If the answer to any of those questions involves or relates to a physical item, then it goes into the hardware bucket.

### The OS-agnostic test

Some content is edited inside a particular software's config files but is not actually caused by that software. Use this test:

> If a different OS or software were installed on the same physical item, in the same physical/network environment, would the same problem and the same fix still apply?

- **Yes** → the root cause is the hardware or its environment (e.g. a dorm network that blocks static IPs and bridged traffic, a dead internal Wi-Fi card, a USB port that loses power on lid-close). This belongs in the **hardware bucket**, even though the actual edits happen inside a specific software's config files (e.g. `/etc/network/interfaces`, `/etc/wpa_supplicant/wpa_supplicant.conf`). Cross-link from the software bucket rather than duplicating.
- **No** → the root cause is specific to that software's behavior, packaging, or defaults (e.g. a minimal OS not shipping a package by default, a specific installer's storage-pool layout). This stays in the **software bucket**.

A single topic can split this way: *why* Wi-Fi is needed and *how the network environment behaves* is hardware/environment (→ hardware bucket); *how to get a specific package installed on a specific minimal OS without internet access* is software-specific (→ software bucket). Don't force the whole topic into one bucket just because it arrived as a single source section. Apply the test per fact, not per section.

When confused between Software and Logical, ask yourself:

> Is this one thing I installed and run (→ Software), or is it a scheme/convention that other things participate in (→ Logical)?

A DHCP *server* (e.g. dnsmasq config on a router) is Software. A home's overall *addressing plan* that DHCP serves is Logical.

### Retroactive application

The two-and-two threshold can be crossed by a single new entry, not just by pre-planned structure. When a new entry causes a domain to cross the Hardware/Software/Logical threshold, the restructuring applies to **all existing entries in that domain**, not only the new one going forward. Existing sibling buckets must be moved under the new grouping folders as part of adding the entry, and any internal links updated to match.

This means a single new entry can trigger a domain-wide reorganization. That is expected and correct. The tree reflects the best structure given everything now known, not the structure that was true before the entry existed (§2).

---

## 4. Top-Level Structure

- The vault root contains the main site `Index.md`.
- Each top-level domain/context is a folder with exactly one `Index.md`.
- Top-level domains are allowed to describe broad contexts such as:
  - `Laptop/`
  - `Homelab/`
- These top-level domains are **organizational contexts, not content buckets**. Their child buckets must still follow the Item/OS/Service rule in §3.
- A normal bucket does NOT get its own `Index.md`.
- The top-level domain `Index.md` should:
  - introduce the domain;
  - contain one `#` section per bucket;
  - link directly to that bucket's glossary and content pages.
- Do not add redundant index pages at every folder level.

---

## 5. One Concrete Thing Per Bucket

- Keep a bucket focused on one item, OS, service, or tool.
- Do not mix unrelated systems merely because they appeared in the same source document.
- Cross-system relationships should be represented with wikilinks.
- If a page genuinely documents two systems, keep the canonical procedure with the system it primarily configures and link to it from the other system's bucket.
- Do not duplicate the procedure just to make it appear in multiple buckets.

---

## 6. Glossaries

- Every bucket gets exactly one `Glossary.md`.
- The glossary contains only terms actually used by that bucket's pages.
- Each glossary entry should include an authoritative external reference where one exists.
- A glossary entry should give the reader enough context to understand why the term matters *in this vault*, not just a dictionary-style one-liner. If a term's definition would otherwise be a single short clause, expand it with the detail a reader unfamiliar with the term would need (what it's for, how it's typically used, why it comes up here) rather than leaving it terse.
- Shared terms have one canonical glossary definition.
- Other buckets should link to or transclude the canonical definition instead of duplicating it.

---

## 7. No Inline Term Definitions

- Content pages must not define glossary terms inline.
- Link the term to its glossary entry instead.

Example:

```md
Configure [[Glossary#IOMMU|IOMMU]] before enabling GPU passthrough.
```

- Keep content pages focused on procedures, configuration, reference information, troubleshooting, and decisions.

---

## 8. Sequential Workflows MUST Have Their Own Folder

A sequential workflow is a series of pages where the reader is expected to complete the steps in order.

**Every sequential workflow MUST live inside its own dedicated subfolder.**

Do not put `Pt 1`, `Pt 2`, `Pt 3`, etc. directly beside unrelated pages in the parent bucket.

Example:

```text
Proxmox/
├── Glossary.md
├── Installation/
│   ├── Pt 1, Prerequisites.md
│   ├── Pt 2, Installation.md
│   └── Pt 3, Initial-configuration.md
├── Networking.md
└── Storage.md
```

The sequence folder itself is an organizational container, not a new Item/OS/Service bucket.

### Sequential filename rules

- Use `Pt 1,`, `Pt 2,`, `Pt 3,` prefixes.
- Every page in the sequence gets a cumulative `# Prerequisites` section.
- `Pt 1` must say:
  `None — this is the first step.`
- Later pages link to every prerequisite page required up to that point.
- Wikilinks must use the exact numbered filenames.

### Sequential folder rules

- A sequence folder should have a clear workflow name, such as:
  - `Installation/`
  - `GPU-Passthrough/`
  - `Migration/`
  - `Setup/`
- Do not use a sequence folder merely to make a large flat collection look tidy.
- If pages are independent references, keep them flat.

---

## 9. Flat Reference Collections

Use a flat collection when pages are independent and can be read in any order.

- No `Pt N,` prefixes.
- No cumulative `# Prerequisites` requirement.
- Alphabetical Explorer/sidebar ordering applies.
- A bucket may contain both:
  - flat reference pages; and
  - one or more dedicated sequence folders.

---

## 10. No Duplicate Content

- Do not create duplicate copies of the same procedure.
- Do not create empty stub `.md` files.
- Choose one canonical source of truth.
- Use Quartz transclusion when the same content needs to appear elsewhere:

```md
![[real-content-filename]]
```

or:

```md
![[real-content-filename#Heading Name]]
```

- An embedding page keeps its own frontmatter.

---

## 11. Cross-Bucket Linking

- Use normal Obsidian wikilinks across buckets and domains.
- Cross-link related systems rather than duplicating documentation.
- Backlinks and graph relationships are generated automatically; do not manually maintain backlink sections.

---

## 12. Content Page Format

Every content page should use the standard frontmatter:

```yaml
---
title: ...
description: ...
tags:
  - ...
---
```

- Use `---` between major sections.
- Prefer durable documentation over personal narrative.
- Write in the first person ("I did X", "I chose Y because...") — this is a personal wiki in the vault owner's own voice, not a third-party reference manual.
- Explain what the reader needs to do, why the procedure exists when useful, how to verify it, and what can go wrong.
- Preserve useful historical details only when they help explain a decision, failure mode, or constraint.
- If the source material says an AI tool was used for a specific piece of content, code, or decision, keep that attribution in the page, including which specific AI model/tool it was (e.g. "generated with Google Gemini", "a regex written with Claude's help"). Do not silently drop AI-authorship notes.

---

## 13. Troubleshooting and Lessons Learned

- Troubleshooting belongs with the concrete item/OS/service it concerns.
- Do not create a generic `Gotchas/`, `Fixes/`, or `Lessons-Learned/` bucket at the domain level.
- A bucket may contain a `Gotchas.md` or `Lessons-Learned.md` page when that information is specific to the bucket.
- Historical failures should be retained when they provide useful diagnostic or design information.

---

## 14. Adding a New Entry

When new content arrives as a source document:

1. Read the entire source.
2. Identify the concrete items, OSes, services, and tools involved.
3. Extract durable technical topics from the source's headings and content.
4. Check the existing tree and page headings for an existing bucket that already owns each topic.
5. Assign each topic to the appropriate Item/OS/Service bucket, applying §2 and §3. Move or rename existing entries when the new content makes a better structure clear.
6. Split one source across multiple buckets when necessary. Merge material from multiple sources when they document the same system.
7. Create a sequence folder when the material is genuinely step-by-step (§8).
8. Remove redundant or purely narrative material unless it has useful historical or diagnostic value.
9. Cross-link related buckets instead of duplicating content.
10. Add each new glossary term to the right bucket's glossary (§6), and link to existing canonical definitions instead of repeating them.
11. Apply §15 (Image Curation) to every image in the source.
12. Update every wikilink that points to a page you moved or renamed.
13. Update the domain's `Index.md` so it lists every new, moved, or renamed page (§4).
14. Do not carry over a source's numbered citation or reference list. Where a cited source is genuinely useful to a reader (e.g. authoritative documentation), fold it in inline as a normal link or as a glossary reference (§6). Otherwise drop it.
15. Record anything you cannot determine confidently as a clarification question (§18) instead of guessing.

---

## 15. Image Curation

Source documents often carry far more images than a wiki entry needs: process narration, option comparisons, before/after polish shots, and borrowed illustrations. Images are content like any other. They get added selectively, not wholesale (§1).

### Keep an image when it does one of the following

- **Diagnoses a problem.** It shows a real error, broken state, or failure mode the reader could otherwise hit: a stack trace, a broken render, a wrong UI state. Pair it with the fix per §13 (Gotchas/Lessons Learned).
- **Verifies a fix or a final state.** It shows the *working* result of a procedure the page just described, or confirms a multi-step procedure actually succeeded (a "how to verify" image).
- **Is the only record of a non-reproducible fact.** A diagram, a piece of hand-drawn planning, a config screen in a UI that has no equivalent code block: something a code block or plain description can't fully capture.
- **Documents a genuine external constraint.** A UI limitation, a dropdown with only two options, a hard cap: evidence of *why* a decision was forced, not just *what* the decision was.

### Discard an image when it only does one of the following

- **Narrates process rather than documenting outcome.** "Here's what the tool looked like right after installing it," "here's the blank template before I added content": scaffolding for the original narrative, not a fact the reader needs.
- **Compares options that weren't chosen.** Screenshots of every alternative considered (themes, tools, layouts) add nothing once the decision is made. Keep at most one image of the option actually adopted, and only if it clears another rule in this section. A rejected option can still get an image if it independently earns one under "diagnoses a problem" (e.g. it errored). The exclusion is for comparison-only shots, not every image involving a rejected option.
- **Is purely cosmetic before/after.** Visual polish (spacing, color, a toggle's appearance) that a code snippet already fully specifies in the page. If the code block says what changed and why, an image of the visual result is decorative, not documentation.
- **Duplicates another kept image.** The same fact shown twice (two crops of the same screenshot, desktop *and* mobile of the identical state) only needs one instance. Prefer whichever crop best isolates the relevant detail.
- **Was borrowed from unrelated subject matter.** An image pulled from a different source purely to illustrate a general point does not belong to this bucket's subject and should be dropped even if the point it illustrates is kept in prose.
- **Is fully redundant with text already required elsewhere on the page.** If a code block, front-matter block, or config snippet already contains everything the image shows, the image is optional restatement, not new information.
- **Is one of a step-by-step sequence of UI actions.** A series of screenshots showing which buttons/menus to click to do something (e.g. "click Settings, then click this toggle, then click Save") is usually clearer, more maintainable, and more accessible as a numbered list of written steps than as a stack of images. Write the steps out instead of screenshotting each one.
- **Is easier to describe in words, or folds cleanly into existing prose.** If the image's content can be stated in a sentence, or slotted into a code block/config snippet that's already on the page, prefer the text version over the image. Don't keep an image just because it existed in the source when a line of prose does the same job.

The exception to the previous two rules: if the image genuinely conveys its content more easily than text would (actual visual layout, a comparison that's hard to describe precisely, a UI arrangement where words would be a clumsy substitute), keep the image instead. Apply judgment. These two rules are about not defaulting to a screenshot when a sentence or a step list would clearly serve the reader better, not about banning images of UIs outright.

### Placement, naming, and embedding

- All kept images for a domain go in one shared folder at the domain's root, e.g. `<Domain>/Images/`, not scattered per-bucket. Buckets reference the shared pool rather than each maintaining their own.
- Rename every image out of its source filename (`img-014.png`, `Pasted image 20260307124029.png`) into a descriptive sentence-kebab-case name that stands on its own: `<subject>-<state-or-context>.png` (e.g. `archie-theme-missing-content-posts.png`, not `screenshot3.png`).
- Embed with a transclusion (`![[filename.png]]`) immediately after the paragraph it supports, followed by an italic one-line caption explaining what the image shows and why it matters, not just what it depicts literally.
- An image belongs on the content page for the fact it supports, not automatically on the page for the bucket or tool it happens to show a screenshot of. A GitHub Pages screenshot that documents a Hugo-caused symptom still lives on the GitHub Pages page if that's the fact being illustrated.
- Never leave a dangling reference to a discarded image. If an image is not kept, remove every embed, caption, and inline mention of it ("see the screenshot below", a caption with no image above it) from the page as well. A page must never reference or describe an image that isn't actually there.

### Decision rule

Don't ask:

> "Was this image in the source?"

Ask:

> "Does removing this image lose a fact the reader needs, or just a moment of the author's narrative?"

If only the narrative is lost, discard it.

---

## 16. Naming Rules

- Folder and file names use sentence kebab-case unless a sequence filename requires the `Pt N,` prefix.
- Capitalize abbreviations and the names of products.
- Use names that identify the actual item, OS, service, or tool.
- Prefer `OpenMediaVault/` over `NAS/`.
- Prefer `Proxmox/` over `Virtualization/`.
- Prefer `OpenWRT/` over `Router/` when the documentation is specifically about OpenWrt.
- Prefer `Dell-Optiplex-5060/` over `Hardware/`.
- Prefer `Hugo/` over `Content-Pipeline/` when the material is specifically about Hugo.
- Use broader names such as `Home-network/` only when the bucket represents the actual shared system/service being documented.

---

## 16a. Titles and Filenames Must Be Search-Specific

- A generic name like `Glossary.md`, `Gotchas.md`, `Overview.md`, `Setup.md`, or `Installation.md` is not enough by itself. The vault has many buckets, and a search bar or file list showing several identically-named files is not useful.
- Both the frontmatter `title:` and the actual filename must identify what the entry is *about*, not just what kind of entry it is.
- Prefer `Nextcloud Glossary` / `Nextcloud-glossary.md` over `Glossary` / `Glossary.md`.
- Prefer `openSUSE Gotchas` / `Opensuse-gotchas.md` over `Gotchas` / `Gotchas.md`.
- Decision rule: "If I searched for this title in a search bar with no folder context, would I know which entry it is?" If the answer is no, the title/filename is too generic.
- When renaming a filename, update every wikilink across the vault that points to it.

---

## 17. External File References (Code/Config Files)

- A file that was manually created or edited by the user (a script, a container definition, a config file, etc.) must NOT be pasted into a wiki page as a code block. Reference it via a GitHub link instead.
- Exception: a code block is allowed only when either is true:
  - it exists purely to show the reader what a file's contents look like (illustrative, not the maintained copy), or
  - the file is temporary/throwaway and isn't something that gets maintained.
- Decision rule: "Was this file manually created/edited by the user?" If yes → link, don't paste (unless one of the two exceptions above applies).
- If the GitHub URL is not known yet, put a placeholder link in the page: `[filename](TODO)`.
- Do not guess missing file names, file paths, URLs, relationships, or other context. If the source material does not provide enough information to confidently determine what is needed, ask the user a clarification question (§18).

---

## 18. Clarification Questions

- Never guess when the available source material is insufficient to confidently determine a file, bucket, relationship, procedure, or other important context.
- Continue adding everything that can be determined confidently, while recording unresolved questions for the user in `Entry Q&A.json` at the vault root.
- Questions may ask things such as:
  - `What files did you use to make X work?`
  - `How many files did you create?`
  - `Explain more what X means.`
  - `What is the GitHub URL that points to X file?`
  - or another targeted question needed to resolve the ambiguity.
- Questions about missing context from other vault entries are temporary. They are not permanent buckets, pages, or categories.

The file uses this structure:

```json
{
  "questions": [
    {
      "id": "q001",
      "type": "missing-file",
      "question": "What files did you use to make the custom Nextcloud image work?",
      "context": "The source mentions a custom Docker image but does not identify the files used to build it.",
      "related": [
        "Nextcloud/Installation.md"
      ],
      "answer": null
    }
  ]
}
```

- `id` is a unique question identifier.
- `type` identifies the reason clarification is required. Useful values include `missing-context`, `missing-file`, `missing-url`, `ambiguous-reference`, `missing-history`, and `missing-relationship`.
- `question` is the direct question the user needs to answer.
- `context` briefly explains why the question was generated and what source material caused the uncertainty.
- `related` lists the page or pages affected by the answer.
- `answer` is `null` when the question is asked. The user fills it in, so no additional status field is required.

Lifecycle:

- When the user answers a question, incorporate the answer into the affected pages and remove that question object from `Entry Q&A.json`.
- If `Entry Q&A.json` contains no questions, delete the file entirely. Its absence means there are no pending questions.
- If a new question is needed and `Entry Q&A.json` does not exist, create it using the structure above.

---

## 19. Flagged Concerns

- Never silently fix, silently ignore, or silently work around something in the source material that looks like a security problem or an unintended mistake (plaintext secrets, disabled certificate verification, overly permissive allow-lists, hard-coded credentials, etc.).
- When you find something like this, add a flagged-concern question to `Entry Q&A.json` asking the user to confirm it was intentional, even when everything else is clear and nothing else is ambiguous.
- This is additive to §18. A flagged-concern question does not block adding the surrounding material. It needs an explicit answer before the page is treated as final/publishable.
- Once the user confirms (fix it / leave it / already handled elsewhere), incorporate the answer and remove the question per the §18 lifecycle.

---

## 20. Required Pre-Creation Checklist

Before creating a new bucket:

- [ ] Is it about one specific item, OS, service, or tool?
- [ ] Could an existing bucket own this page?
- [ ] Would merging it into an existing bucket improve discoverability?
- [ ] Am I copying the structure of the source document instead of organizing by concept?
- [ ] Is this actually a sequence? If yes, does it have its own subfolder?
- [ ] Is the content duplicated elsewhere?
- [ ] Does the bucket need a glossary entry rather than an inline definition?
- [ ] For each source image: does it diagnose a problem, verify a fix, record a non-reproducible fact, or document a genuine constraint? If not, discard it (§15).

Before finalizing the change:

- [ ] Every top-level domain has exactly one `Index.md`, and it lists every new, moved, or renamed page.
- [ ] No normal bucket has an `Index.md`.
- [ ] Every bucket has a `Glossary.md`.
- [ ] Every sequential workflow has its own folder.
- [ ] Every sequential page has cumulative prerequisites.
- [ ] No generic organizational bucket has slipped in.
- [ ] No duplicate procedures exist.
- [ ] The source document was treated as source material, not as the site structure.
- [ ] If a Hardware/Software/Logical split was triggered, all existing entries in the domain were moved into it, not just the new one.
- [ ] Every wikilink to a moved or renamed page still resolves.
- [ ] No kept image is pure narration, a rejected-option comparison, a cosmetic before/after, a duplicate, or borrowed from unrelated subject matter (§15).
- [ ] Every kept image lives in its domain's shared image folder with a descriptive kebab-case filename, and has a captioned transclusion on the page for the fact it supports.
- [ ] Any unresolved ambiguity has a targeted question in `Entry Q&A.json`, and the file is deleted when no questions remain.

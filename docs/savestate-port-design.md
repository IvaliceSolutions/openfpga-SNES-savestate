# SNES Pocket — Save State / Sleep Port Design (J1)

Goal: bring save states ("Memories") + sleep/wake to the openFPGA SNES core on the
Analogue Pocket, by porting paulb-nl's MiSTer save-state engine (`ss_wip`) onto
agg23's Pocket port. Target = the `none` build variant (no coprocessors), which
fits the Cyclone V with headroom and runs all standard non-chip games.

## Architecture — Strategy A (wrap the proven engine, scratch in PSRAM)

```
   [power button / Memories menu]
            │  savestate_start / savestate_load     (openFPGA Memories API, already wired in core_top.sv)
            ▼
   ┌─────────────────────┐   SS_SAVE/SS_LOAD/SS_SLOT/SS_AVAIL
   │  ss_glue_fsm (NEW)  │ ───────────────────────────────►  paulb-nl engine (ported, intact)
   │                     │                                         │ SS_DDR_* (req/ack, 64-bit)
   │                     │                                         ▼
   │                     │                              ┌───────────────────────┐
   │                     │ ◄── shuttle blob (PSRAM⇄bridge) │ ss_psram_arbiter (NEW)│
   └─────────┬───────────┘                              └───────────────────────┘
             │ bridge (addr 0x4xxxxxxx)                   cram1 die1 (8MB free) scratch
             ▼
       SD card  ← APF host reads/writes the Memory file
```

Why Strategy A: paulb-nl's engine (NMI-hijack: runs save code on the SNES CPU) is the
hard, proven part. We do NOT modify it; we adapt the storage + transport around it.

## Memory map (from rtl/mister_top/SNES.sv ~500-657)

| Region | Size | Location |
|---|---|---|
| ROM | ≤4MB | SDRAM (dram_*) |
| WRAM | 128KB | PSRAM cram0, die0 (first 128KB) |
| ARAM | 64KB | PSRAM cram1, die0 (first 64KB) |
| VRAM | 2×32KB | on-chip BRAM (dpram) |

Pocket PSRAM = 2 chips × 16MB (dual 8MB die; `bank_sel` = die select; addr[21:0] words).
=> **cram0 die1 (8MB) and cram1 die1 (8MB) are entirely free.**

Savestate scratch lives on **cram1 die1 (bank_sel=1)**, shared with ARAM (die0) via an
arbiter. Savestate is a distinct phase from active gameplay, so serializing ARAM+scratch
through the single PSRAM controller is fine (latency non-critical).

## Savestate blob size (chipless game)

WRAM 128KB + VRAM 64KB + ARAM 64KB + CGRAM 512B + OAM 544B + CPU/PPU/SMP registers
≈ ~260KB. Engine allows up to 1MiB/slot. We expose 1 slot (the Pocket's single Memory).
=> savestate_size constant ≈ round up to a safe value (TBD from actual engine output).

## NEW module 1 — `ss_psram_arbiter`

Shares PSRAM chip cram1 between two clients and exposes the storage interface the
paulb-nl engine expects.

- Client A (ARAM): existing 16-bit byte interface, die0 (bank_sel=0).
- Client B (savestate scratch): die1 (bank_sel=1).
- Engine-facing port = `SS_DDR_*` style: 64-bit data in/out, address (word), WE, BE,
  REQ/ACK handshake. Internally packs each 64-bit word into 4× 16-bit PSRAM accesses.
- Drives the real cram1_* pins (currently driven by the "aram" psram instance — this
  module subsumes/wraps it). Makes `bank_sel` per-transaction (today hardwired to 0).
- Arbitration: simple priority/round-robin; when savestate active, scratch gets the bus.

## NEW module 2 — `ss_glue_fsm`

Bridges the openFPGA Memories API to the engine + moves the blob to/from the host.

- Translates openFPGA `savestate_start` → `SS_SAVE` (pulse), `savestate_load` → `SS_LOAD`.
- Drives `SS_SLOT=0`, monitors `SS_AVAIL`, reports back start/load _ack/_busy/_ok/_err.
- After a SAVE: streams scratch (PSRAM) → bridge so the APF host writes the Memory file.
- For a LOAD: host → bridge → scratch (PSRAM), then pulse `SS_LOAD`.
- Reuses agg23's existing save_state_controller.sv bridge plumbing where possible
  (FIFO bridge↔host), with the PSRAM scratch as the random-access backing the engine needs.

## Incremental, independently-testable sub-milestones

- **J1a — Un-gray (openFPGA side only).** Instantiate save_state_controller in SNES
  core_top.sv (NES recipe), set `savestate_supported=1`, define savestate_addr/size/
  maxloadsize, stub the core-side bus (ss_busy=0). Expected hardware result: the
  "save state" option in Memories is **no longer grayed out**. (Saving won't work yet.)
  *** This is the next user test. ***
- **J1b — Engine + scratch.** Port SMP/PPU/DSP (ss_wip versions) + the 6 savestate_*
  files; instantiate ss_psram_arbiter; engine writes a blob to PSRAM scratch.
- **J1c — Host shuttle.** ss_glue_fsm streams scratch ↔ bridge; a Memory file appears
  on SD.
- **J2 — Manual save/load** of a chipless game (Tactics Ogre / FF6 / Chrono Trigger).
- **J3 — Sleep/wake** (set core.json `sleep_supported: true`; auto save/restore on power).

## Reference constants (from working NES core)

savestate_supported=1; savestate_addr=0x40000000; savestate_size=0x144008 (~1.3MB on NES);
bridge read mux routes `bridge_addr[31:28]==4'h4` → save_state_bridge_read_data.

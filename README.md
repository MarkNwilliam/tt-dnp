<div align="center">

#  Digital Number Plate Evidence Core

**Tiny Tapeout 2x2-tile digital core** — the trust anchor for a Ugandan digital
number plate: a write-once sealed identity, a decrement-only toll balance, and a
24-byte evidence token a roadside reader can photograph.

PDK `ihp-sg13g2` · 20 ns clock · [Write-up](docs/info.md) ·
[Live 3D layout](https://marknwilliam.github.io/tt-dnp/) · [Fab package](gds_output/) · [Render](gds_output/preview.png)

</div>

---

## The chip

A host MCU provisions the plate once; after that the identity is frozen and the
chip only ever *subtracts*. GPS, RFID/UHF, cellular, display and power stay
off-chip — the seal, the money and the evidence trail live on this tile.

- **Write-once 32-byte identity** — serial, 5-char registration, tax/insurance
  and class flags, mileage, toll balance and flat toll. Seals only if all 32
  bytes are present and every field validates; afterwards every `wr` is ignored.
- **Decrement-only balance** — a `zenter`→`zexit` passage debits the sealed
  toll, saturating at zero. It can never go negative, never be incremented.
  An underpayment still records `unpaid` in the token and raises `IMMOB`.
- **24-byte evidence token** — plate, flags, zone class, mileage, post-passage
  balance, toll charged, passage count, rolling chain, and a 64-bit digest.
- **Sticky tamper + removal latches** — a broken seal or a removal shock
  permanently clears `VALID`, asserts `IMMOB`, and marks every future token.
- **EDR / axle evidence** — brake, wheel, impact and weighbridge counters;
  more than 6 axles in one passage sets the overweight flag.
- **Honest digest** — the 64-bit mixer is tamper-*evident*, not cryptographic.
  A production plate needs a real signature or a secure element. See
  [docs/info.md](docs/info.md).

## Pin map

| Pin | Signal | Direction | Meaning |
|-----|--------|-----------|---------|
| `ui[0]` | `EN` | in | global enable (AND'ed with `ena`) |
| `ui[1]` | `GO` | in | seal during setup / issue a token once sealed |
| `ui[2]` | `WR` | in | host mode: write header; sensor mode: sample sensors |
| `ui[3]` | `RD` | in | host mode: stream the next token byte out |
| `ui[4]` | `SEL` | in | `0` = host byte-bus mode, `1` = sensor-inject mode |
| `ui[5]` | `PPS` | in | 1 Hz time window |
| `ui[6]` | `ZONE` | in | toll-zone level (enter/exit edge-detected) |
| `ui[7]` | `TAMPER` | in | enclosure/seal broken (active-high level) |
| `uo[0..7]` | `BUSY, SEALED, ERR, TAMPER, BAL_OK, IMMOB, RDY, VALID` | out | core status |
| `uio[7:0]` | `DATA` | bidir | host byte bus, or sensor vector in sensor mode |

The core wants an 8-bit data bus plus ten control and sensor lines but Tiny
Tapeout only offers 8 `uo` + 8 `uio`, so the bus is **time-multiplexed**: with
`SEL=1` the same eight pins carry
`{brake, wheel, impact, weigh, zenter, zexit, removal, spare}` and pulsing
`WR` turns each asserted bit into a one-cycle pulse. The host synthesises the
whole sensor waveform with a few writes.

## Verification

12 cocotb tests drive the core through the real `ui`/`uio`/`uo` pins, so they
check the wrapper routing as well as the core: reset, short-header rejection,
seal and token identity, invalid zone class, toll decrement across two
passages, unpaid toll, enclosure tamper, removal shock, EDR counters, axle
overload, digest determinism/change, and immobilize on expired tax.

```
cd test && make          # 12/12 PASS
```

## Silicon (2x2, IHP sg13g2 — all green)

| Metric | Value |
|---|---|
| Tiles | 2x2 (die 419.52 x 313.74 um) |
| Std cells | 4,652 (2,866 logic + 690 sequential) |
| Utilization | 63.1 % |
| Core area | 128,155 um^2 (65,675 um^2 of cells) |
| Setup WNS / TNS | 0.0 / 0.0 ns — **no violations** |
| Hold WNS / TNS | 0.0 / 0.0 ns — **no violations** |
| Route DRC | 0 |
| Antenna violations | 0 |
| LVS | clean (0 device/net differences) |
| Magic DRC | 0 errors, 0 illegal overlaps |
| Power | 2.62 mW total (2.20 internal, 0.42 switching, 0.004 leakage) |
| IR drop | 0.60 mV worst |

Timing closes at the 20 ns target across all three corners with zero setup
and zero hold violations, and LVS matches the schematic. `gds_output/` holds
the GDSII, OASIS, LEF, SPEF and gate-level netlist, plus a rendered preview.

One known issue: **50 max-fanout violations**. These are wide control nets,
not timing failures — slack is clean at every corner — but they are a real
signal-integrity smell that would want a buffer tree before a production
run. Tracked rather than hidden.

## Status

RTL, wrapper, tests, and physical implementation are complete. GDS, precheck
and gate-level simulation are all green in GitHub Actions; the fabrication
package is in `gds_output/`.

## License

CERN-OHL-S-2.0 — see [LICENSE](LICENSE).

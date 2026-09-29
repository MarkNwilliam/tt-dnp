# Digital Number Plate Evidence Core — Tiny Tapeout writeup

A 2x2-tile trusted evidence core for a Ugandan digital number plate (DNP): the
chip that makes a plate **unforgeable** and its **toll/road-user balance
decrement-only**, and that hands a roadside reader a signed-by-construction
evidence token to photograph.

## Why this exists

A paper number plate can be swapped. A DNP is only as trustworthy as the chip
that holds its identity, so the identity has to be written once, never rewritten,
and any physical attack has to leave a permanent mark that a reader can see.
The core in this repo is the *trusted head*: GPS, RFID/UHF, cellular, the
display and the power supply all stay off-chip, but the seal, the money and the
evidence trail live here.

## The sealed identity (32 bytes, write-once)

A host MCU writes exactly 32 bytes, then pulses `GO` to seal. The core accepts
the seal only if every byte is present and every field validates.

| Bytes | Field | Notes |
|-------|-------|-------|
| 0 | ctl | bit0 registered_ok, bit1 tax_ok, bit2 insurance_ok, bit3 class_ok |
| 1..8 | serial | 8-byte vehicle serial, big endian |
| 9..13 | plate | 5-character registration, e.g. `UAB12` |
| 14 | zone class | 0..3 (must be <= 3, else ERR) |
| 15 | mileage | x10 km |
| 16..18 | balance | road-user toll balance in 1/100 units, big endian |
| 19..20 | toll | flat per-passage toll in 1/100 units, big endian |
| 21..31 | reserved | must be 0 |

After sealing, the header is frozen. Any later `wr` is ignored, so the identity
cannot be re-provisioned in the field.

## The token (24 bytes, per reading)

| Bytes | Field |
|-------|-------|
| 0..4 | plate string |
| 5 | flags: bit3 class, bit4 overweight, bit5 axles, bit6 unpaid, bit7 tamper |
| 6 | zone class |
| 7 | mileage |
| 8..10 | balance after the passage |
| 11..12 | toll charged |
| 13..14 | passage count |
| 15 | chain (rolling evidence chain) |
| 16..23 | 64-bit digest |

## How the money works

The balance is **decrement-only** in hardware. Each `zenter`→`zexit` passage
debits the sealed flat toll; the counter saturates at zero, so it can never go
negative and can never be incremented by an attacker. If the balance is
insufficient, the toll still records `unpaid` in the token — that is the
enforcement evidence — and `IMMOB` goes high.

## Tamper, removal, EDR

- `TAMPER` pin high latches a sticky enclosure-open flag.
- A removal shock (`g_pulse`) latches a separate removal flag.
- Both clear `VALID` and assert `IMMOB` **permanently** — a reader sees the
  tamper bit in every token forever.
- The EDR block counts brake, wheel, impact and weighbridge pulses. More than 6
  axles in one passage sets the overweight bit.

## The digest: honest about what it is

The 64-bit digest binds the live token record to the sealed serial, so a token
cannot be edited field-side without changing the digest. The mixer is
**multiplier-free and tamper-evident, not cryptographic** — it is not a MAC and
not collision-resistant against a determined attacker with no key. A production
DNP needs a real digital signature (Ed25519/P-256) or a secure element holding
the private key. This core is the tamper/anti-rollback layer, not the
authentication root of trust.

## How to test (through the real TT pins)

The wrapper time-multiplexes sensors onto the data bus, so from a testbench:

1. `SEL=0` (host mode), hold `EN=1`, write the 32-byte header on `WR`/`DATA`.
2. Pulse `GO` — `SEALED` and `VALID` rise.
3. `SEL=1` (sensor mode), put `{brake,wheel,impact,weigh,zenter,zexit,removal}`
   on `DATA` and pulse `WR` to inject the sensors; `zenter` … axles … `zexit`
   is one passage.
4. Back to `SEL=0`, pulse `GO`, wait for `RDY`, then pulse `RD` 24 times to
   read the token out on `DATA`.

## External hardware

A host MCU (or roadside reader), a GNSS module for zone and PPS, a UHF/RFID
front-end for identity, a display driver, a weighbridge/speed-loop pair for
axle and mileage evidence, and an immobilize relay. All of that is off-chip;
this tile is the trust anchor.

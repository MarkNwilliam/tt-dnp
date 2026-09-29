"""cocotb testbench for the Tiny Tapeout wrapper tt_um_dnp.

Exercises the core through the real TT pin map (ui/uio/uo), so this doubles as
a wrapper-level check that the pin routing and the byte host port work.

Pin map (see src/tt_um_dnp.v):
  ui[0] EN  ui[1] GO  ui[2] WR  ui[3] RD  ui[4] SEL
  ui[5] PPS ui[6] ZONE  ui[7] TAMPER
  uo[0] BUSY uo[1] SEALED uo[2] ERR uo[3] TAMPER
  uo[4] BAL_OK uo[5] IMMOB uo[6] RDY uo[7] VALID
  uio[7:0] DATA: host byte bus in host mode (SEL=0), sensor vector in
          sensor mode (SEL=1) = [0]brake [1]wheel [2]impact [3]weigh
          [4]zenter [5]zexit [6]removal [7]spare

Header layout (see src/np_id.sv):
  [0]     ctl: bit0 reg_ok, bit1 tax_ok, bit2 ins_ok, bit3 class_ok
  [1..8]  serial (big endian)
  [9..13] plate string, 5 chars
  [14]    zone class (0..3)
  [15]    mileage x10 km
  [16..18] balance, 1/100 (big endian)
  [19..20] flat toll per passage, 1/100 (big endian)
  [21..31] reserved (0)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

CLK_NS = 10

# ui_in bits
UI_EN, UI_GO, UI_WR, UI_RD = 0, 1, 2, 3
UI_SEL, UI_PPS, UI_ZONE, UI_TAMPER = 4, 5, 6, 7

# uo_out bits
UO_BUSY, UO_SEALED, UO_ERR, UO_TAMPER = 0, 1, 2, 3
UO_BALOK, UO_IMMOB, UO_RDY, UO_VALID = 4, 5, 6, 7

# sensor vector bits (uio) used in sensor mode
S_BRAKE, S_WHEEL, S_IMPACT, S_WEIGH = 0, 1, 2, 3
S_ZENTER, S_ZEXIT, S_REMOVAL = 4, 5, 6

CTL_REG, CTL_TAX, CTL_INS, CTL_CLASS = 0x01, 0x02, 0x04, 0x08

# token ctl bits (see np_core.sv / np_audit.sv)
TOK_TAMPER, TOK_OVERWEIGHT, TOK_UNPAID, TOK_CLAIMED = 0x80, 0x10, 0x40, 0x08


class Plate:
    def __init__(self, dut):
        self.d = dut

    async def reset(self):
        d = self.d
        d.rst_n.value = 0
        d.ena.value = 0
        d.ui_in.value = 0
        d.uio_in.value = 0
        await Timer(5 * CLK_NS, units="ns")
        await RisingEdge(d.clk)
        d.rst_n.value = 1
        d.ena.value = 1
        d.ui_in.value = 1 << UI_EN  # EN must be high or the core is gated off
        await Timer(5 * CLK_NS, units="ns")

    def ui(self):
        return int(self.d.ui_in.value)

    def out(self):
        return int(self.d.uo_out.value)

    @staticmethod
    def bit(v, i):
        return (v >> i) & 1

    async def set_ui(self, mask, val=True):
        cur = self.ui()
        cur = (cur | (1 << mask)) if val else (cur & ~(1 << mask))
        self.d.ui_in.value = cur & 0xFF
        await Timer(1, units="ns")

    def set_bus(self, data):
        self.d.uio_in.value = data & 0xFF

    async def strobe_ui(self, mask):
        """Pulse a ui control high for one clock edge (host mode assumed)."""
        await self.set_ui(mask, True)
        await RisingEdge(self.d.clk)
        await self.set_ui(mask, False)
        await RisingEdge(self.d.clk)

    # ---- host port (SEL=0) ----
    async def host_mode(self):
        await self.set_ui(UI_SEL, False)

    async def write_byte(self, data):
        self.set_bus(data)
        await self.strobe_ui(UI_WR)

    async def header(self, ctl, serial, plate, zone=0, mileage=0, bal=0, fee=0):
        await self.host_mode()
        serial = bytes(serial)[:8].ljust(8, b"\x00")
        for i in range(32):
            if i == 0:
                b = ctl
            elif 1 <= i <= 8:
                b = serial[i - 1]
            elif 9 <= i < 9 + len(plate):
                b = plate[i - 9]
            elif i == 14:
                b = zone
            elif i == 15:
                b = mileage
            elif 16 <= i < 19:
                b = (bal >> (8 * (18 - i))) & 0xFF
            elif 19 <= i < 21:
                b = (fee >> (8 * (20 - i))) & 0xFF
            else:
                b = 0
            await self.write_byte(b)
        await self.seal()

    async def seal(self):
        await self.host_mode()
        await self.strobe_ui(UI_GO)

    async def issue_token(self, timeout=400):
        await self.host_mode()
        await self.strobe_ui(UI_GO)
        for _ in range(timeout):
            await RisingEdge(self.d.clk)
            if self.bit(self.out(), UO_RDY):
                break
        else:
            raise AssertionError("token never became RDY")
        return await self.read_token()

    async def read_token(self):
        await self.host_mode()
        out = []
        for _ in range(24):
            await self.set_ui(UI_RD, True)
            await RisingEdge(self.d.clk)
            await Timer(1, units="ns")
            out.append(int(self.d.uio_out.value) & 0xFF)
            await self.set_ui(UI_RD, False)
            await RisingEdge(self.d.clk)
        return out

    # ---- sensor injection (SEL=1) ----
    async def sensor(self, mask, n=1):
        """Assert the sensor vector for n clock edges with WR pulsed."""
        await self.set_ui(UI_SEL, True)
        self.set_bus(mask)
        for _ in range(n):
            await self.strobe_ui(UI_WR)
        self.set_bus(0)

    async def zone_trip(self, axles=0):
        """One passage: zenter, optional axles, zexit (sensor mode)."""
        await self.sensor(1 << S_ZENTER)
        for _ in range(axles):
            await self.sensor(1 << S_WEIGH)
        await self.sensor(1 << S_ZEXIT)


async def setup(dut):
    p = Plate(dut)
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await p.reset()
    return p


# ===================================================================== tests
@cocotb.test()
async def t_reset_outputs_clear(dut):
    p = await setup(dut)
    await Timer(5 * CLK_NS, units="ns")
    assert p.out() == 0, f"uo_out should be clear after reset, got {p.out():02x}"


@cocotb.test()
async def t_seal_requires_full_header(dut):
    p = await setup(dut)
    for _ in range(31):
        await p.write_byte(0)
    await p.seal()
    assert p.bit(p.out(), UO_ERR), "ERR should latch on short header"
    assert not p.bit(p.out(), UO_SEALED), "must not seal on short header"


@cocotb.test()
async def t_seal_and_token_identity(dut):
    p = await setup(dut)
    ctl = CTL_REG | CTL_TAX | CTL_INS | CTL_CLASS
    serial = bytes([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18])
    await p.header(ctl, serial, b"UAB12", bal=100_000, fee=250)
    assert p.bit(p.out(), UO_SEALED), "should seal after full header"
    assert p.bit(p.out(), UO_VALID), "valid plate should assert VALID"
    tok = await p.issue_token()
    assert tok[0:5] == list(b"UAB12"), f"plate in token = {tok[0:5]}"
    assert tok[5] & 0x0F == 0x0F, f"ctl nibble = {tok[5] & 0x0F:x}"
    assert ((tok[8] << 16) | (tok[9] << 8) | tok[10]) == 100_000, "balance"
    assert ((tok[11] << 8) | tok[12]) == 250, "fee"
    assert any(tok[16:24]), "digest must be non-zero"


@cocotb.test()
async def t_invalid_zone_class_errors(dut):
    p = await setup(dut)
    await p.header(CTL_REG | CTL_TAX, b"S" * 8, b"KLM99", zone=0x0F)
    assert p.bit(p.out(), UO_ERR), "zone_class>3 must set ERR"
    assert not p.bit(p.out(), UO_SEALED), "must not seal invalid class"


@cocotb.test()
async def t_toll_decrements_on_passage(dut):
    p = await setup(dut)
    bal, fee = 50_000, 500
    await p.header(CTL_REG | CTL_TAX | CTL_INS, b"S" * 8, b"TOLL1", bal=bal, fee=fee)
    await p.issue_token()
    await p.zone_trip()
    await p.zone_trip()
    tok = await p.issue_token()
    got = (tok[8] << 16) | (tok[9] << 8) | tok[10]
    assert got == bal - 2 * fee, f"balance {got} != {bal - 2 * fee}"
    assert ((tok[13] << 8) | tok[14]) == 2, f"passages = {(tok[13] << 8) | tok[14]}"


@cocotb.test()
async def t_toll_unpaid_latches(dut):
    p = await setup(dut)
    bal, fee = 300, 500
    await p.header(CTL_REG | CTL_TAX | CTL_INS, b"S" * 8, b"POOR1", bal=bal, fee=fee)
    await p.zone_trip()
    tok = await p.issue_token()
    assert tok[5] & TOK_UNPAID, "unpaid bit should be set"
    got = (tok[8] << 16) | (tok[9] << 8) | tok[10]
    assert got == bal, f"balance {got} != {bal} (must not go negative)"


@cocotb.test()
async def t_tamper_latches_via_tamper_pin(dut):
    p = await setup(dut)
    await p.header(CTL_REG | CTL_TAX | CTL_INS, b"S" * 8, b"TAMP1", bal=10_000, fee=100)
    await p.set_ui(UI_TAMPER, True)
    await Timer(2 * CLK_NS, units="ns")
    assert p.bit(p.out(), UO_TAMPER), "TAMPER should latch on seal_open"
    assert p.bit(p.out(), UO_IMMOB), "tamper should request immobilize"
    await p.set_ui(UI_TAMPER, False)
    await Timer(2 * CLK_NS, units="ns")
    assert p.bit(p.out(), UO_TAMPER), "TAMPER must not clear"
    tok = await p.issue_token()
    assert tok[5] & TOK_TAMPER, "tamper bit should be set in token"


@cocotb.test()
async def t_removal_shock_latches(dut):
    p = await setup(dut)
    await p.header(CTL_REG | CTL_TAX | CTL_INS, b"S" * 8, b"REMOV", bal=10_000, fee=100)
    await p.sensor(1 << S_REMOVAL)
    await Timer(2 * CLK_NS, units="ns")
    assert p.bit(p.out(), UO_TAMPER), "removal shock should latch tamper"
    assert not p.bit(p.out(), UO_VALID), "tampered plate must lose VALID"


@cocotb.test()
async def t_edr_counters(dut):
    p = await setup(dut)
    await p.header(CTL_REG | CTL_TAX | CTL_INS, b"S" * 8, b"EDR01", bal=10_000, fee=100)
    await p.sensor(1 << S_BRAKE, 3)
    await p.sensor(1 << S_IMPACT, 2)
    await p.sensor(1 << S_WHEEL, 40)
    await p.issue_token()


@cocotb.test()
async def t_axle_overweight_latches(dut):
    p = await setup(dut)
    await p.header(CTL_REG | CTL_TAX | CTL_INS, b"S" * 8, b"HEAVY", zone=2,
                   bal=10_000, fee=100)
    await p.zone_trip(axles=8)
    tok = await p.issue_token()
    assert tok[5] & TOK_OVERWEIGHT, "overweight bit should be set (8 axles > 6)"


@cocotb.test()
async def t_digest_deterministic_and_changing(dut):
    p = await setup(dut)
    await p.header(CTL_REG | CTL_TAX, b"HASH1", b"DET01", bal=4242, fee=7)
    a = await p.issue_token()
    b = await p.issue_token()
    assert a == b, "digest must be deterministic for the same state"
    await p.zone_trip()
    c = await p.issue_token()
    assert a[16:24] != c[16:24], "digest must change when the record changes"


@cocotb.test()
async def t_immobilize_on_expired(dut):
    p = await setup(dut)
    await p.header(CTL_REG, b"S" * 8, b"NOTAX", bal=10_000, fee=100)
    await p.issue_token()
    assert p.bit(p.out(), UO_IMMOB), "expired tax should immobilize"
    assert not p.bit(p.out(), UO_VALID), "must not be VALID without tax"

# Beta 5 Hardware Lexer

Standalone SystemVerilog implementation and regression suite for the Dynamic
Compiler Beta 5 lexer.

The current Beta 5c core accepts an 8-bit source-character stream and emits
16-bit token words compatible with the bundled software token ABI. Beta 5a
established reliable stream handshakes and EOF completion, Beta 5b added the
remaining planned keyword/operator/character modes, and Beta 5c added the full
fixture and boundary regression.

BRAM adapters, source-byte packing, token-memory writing, and FPGA integration
are future Beta 5d work. The current module is a standalone streaming core.

## Interface

| Direction | Signals | Meaning |
|---|---|---|
| Source to lexer | `i_char[7:0]`, `i_char_valid` | Source byte and availability |
| Lexer to source | `o_char_ready` | Lexer can accept the current byte |
| Lexer to consumer | `o_token[15:0]`, `o_token_valid` | Token word and availability |
| Consumer to lexer | `i_token_ready` | Consumer can accept the token |
| Control/status | `i_start`, `i_eof`, `o_done`, `o_error` | Transaction control and status |

A byte transfers on a rising edge when `i_char_valid && o_char_ready`. A token
transfers when `o_token_valid && i_token_ready`. The token word uses the token
type in bits `[15:8]` and an optional payload in bits `[7:0]`.

## Repository layout

```text
rtl/                         canonical synthesizable lexer
tb/                          directed and file-driven testbenches
tests/inputs/                12 C source fixtures
tests/expected_binary/       paired 16-bit expected token streams
reference/tokens.hpp         software token ABI reference
scripts/run-beta5c-tests.ps1 complete ModelSim regression
docs/                        design and verification notes
```

## Run the regression

Requirements:

- ModelSim commands `vlib`, `vlog`, and `vsim` on `PATH`
- Windows PowerShell

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run-beta5c-tests.ps1
```

Use `-SkipStress` to run one normal fixture pass without the second pass that
adds input gaps and periodic output stalls.

## Verified status

ModelSim Intel FPGA Edition 2020.1, 13 November 2026:

- All 36 hardware/software token IDs match.
- SystemVerilog compilation completed with 0 errors and 0 warnings.
- 31 directed tests passed.
- 12 of 12 software fixtures passed with normal timing.
- 12 of 12 fixtures passed with input gaps and output backpressure.
- 24 fixture simulations passed and 0 failed.

See [Beta 5c testing](docs/BETA5C_TESTING.md) for detailed behavior, oracle
policy, and known limits. See [the lexer FSM](docs/lexer-fsm.md) for the
control-state and recognition-mode diagrams.

## Reference material and licensing

`reference/tokens.hpp`, `tests/inputs`, and `tests/expected_binary` originate
from the Dynamic Compiler `SW_Lexer` project and are included under its MIT
license. See `LICENSE-SW-LEXER` and `NOTICE.md`.

No license is assigned here to the hardware RTL itself.

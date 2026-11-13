# Beta 5 Progress Log

This log records every Beta 5 lexer change, its reason, and its verification result. It is intentionally kept beside the lexer rather than in a separate project so the hardware implementation and its evidence stay together.

Paths and manual commands in the dated Beta 5a/5b sections describe the
original `dual_port_bram_integration` workspace. Use the root README and
`scripts/run-beta5c-tests.ps1` for the standalone repository.

## Development context

- Original development branch: `beta5c` in `dual_port_bram_integration`.
- Standalone publication was explicitly authorized on 13 November 2026.
- Beta 5a/5b behavior is retained. Beta 5c adds full-fixture and boundary verification; Beta 5d remains the future BRAM-integration stage.

## 2026-09-26 - Beta 5a baseline

### Starting point

- Baseline: `beta5` commit `9f99cd9`.
- The old lexer compiled, but `lexer_engine_tb.sv` failed on `add_func` at token index 3: it expected `TOK_INT_WORD` and received `TOK_IDENT`.
- Root cause: the source driver could present a byte while the lexer was in `LEX_EMIT` or was scheduling a pending delimiter token. The core had no input-ready signal, so it silently dropped the first byte of a following token.
- The old output was an 8-bit token type only. It did not match the C++ lexer's 16-bit binary token ABI and discarded identifier/integer payloads.
- The legacy `lexer.sv` and `lexer_tb.sv` remain untouched in Beta 5a. They define an incompatible module interface and are not part of the canonical Beta 5a compile command.

### C++ reference contract

Source of truth:

- `C:\Users\akhil\code\SW_Lexer\shared\tokens.hpp`
- `C:\Users\akhil\code\SW_Lexer\tests\inputs\add_func.c`
- `C:\Users\akhil\code\SW_Lexer\tests\expected_binary\add_func.hex`

Every output word is `token_type[15:8] | payload[7:0]`. Bare tokens use payload `8'hff`; a one-byte identifier uses its ASCII byte; an integer uses its low eight bits. The C++ `add_func` fixture contains 16 expected words. The C++ enum reserves `END_OF_FILE` (`8'h23`), but its binary fixtures do not append it; Beta 5a uses `o_done` as the completion signal.

### Beta 5a implementation targets

| Item | Why | Verification |
|---|---|---|
| 16-bit token ABI | Align hardware output with the parser-facing C++ binary fixtures. | Exact word-by-word `add_func` comparison. |
| Input valid/ready | Prevent a source byte from being dropped during token emission. | `add_func` drives bytes while the lexer may be busy and holds them until accepted. |
| Output valid/ready | Prevent a consumer from missing a one-cycle token pulse. | Testbench stalls the first output token for three cycles. |
| EOF flush and done | Emit a final identifier/number without requiring trailing whitespace. | `x` and `42` directed tests. |
| Sticky error signal | Expose malformed simultaneous EOF/input and buffer overflow. | Must remain low for all Beta 5a passing tests. |

### Commands to run

```powershell
Set-Location "C:\Users\akhil\code\dual_port_bram_integration\rtl\beta\beta5"
if (-not (Test-Path work_beta5a)) { vlib work_beta5a }
vlog -work work_beta5a -sv lexer_pkg.sv lexer_engine.sv lexer_engine_tb.sv
vsim -c work_beta5a.lexer_engine_tb -do "run -all; quit -f"
```

For the combined Beta 5a/5b regression, use a separate ModelSim library:

```powershell
Set-Location "C:\Users\akhil\code\dual_port_bram_integration\rtl\beta\beta5"
if (-not (Test-Path work_beta5b)) { vlib work_beta5b }
vlog -work work_beta5b -sv lexer_pkg.sv lexer_engine.sv lexer_engine_tb.sv
vsim -c work_beta5b.lexer_engine_tb -do "run -all; quit -f"
```

### Results

#### Implemented

- Added the local `beta5a` branch. No remote operation was performed.
- Updated `lexer_pkg.sv` to the exact numeric token IDs in `SW_Lexer/shared/tokens.hpp`; token words are now 16 bits.
- Replaced the old one-cycle input/output assumptions with `i_char_valid`/`o_char_ready` and `o_token_valid`/`i_token_ready` handshakes.
- Added `i_eof`, sticky `o_error`, and `o_done`. EOF emits a buffered identifier, integer, or string before completion; no `TOK_END_OF_FILE` word is written because the C++ binary fixtures do not include one.
- Changed identifier payload behavior to the C++ binary rule: one-character identifiers encode as `TOK_IDENT | ASCII`; a multi-character non-keyword identifier encodes as `TOK_NONE | 8'hff`.
- Replaced the older inline token-type-only testbench with a 16-bit binary-word scoreboard.
- Added the requested Mermaid architecture and state-machine diagrams in `lexer-fsm.md`.

#### Verification run

```text
ModelSim Intel FPGA Edition 2020.1
vlog -work work_beta5a -sv lexer_pkg.sv lexer_engine.sv lexer_engine_tb.sv
Compilation: 0 errors, 0 warnings

vsim -c work_beta5a.lexer_engine_tb -do "run -all; quit -f"
add_func_input_and_output_stall: pass
eof_identifier: pass
eof_integer: pass
identifier_plus_identifier: pass
keywords_number_and_punctuation: pass
float_assignment: pass
all_supported_punctuators: pass
multichar_identifier_cxx_abi: pass
directive: pass
string: pass
reset_recovery: pass
Beta 5a lexer tests passed
Simulation: 0 errors, 0 warnings
```

The `add_func` test uses the C++ source and all 16 expected binary words exactly. It holds source bytes through lexer-busy periods and stalls the first token consumer handshake for three cycles, proving that neither interface drops data.

### Bug and gap inventory

| ID | Finding | Beta 5a status |
|---|---|---|
| B5A-01 | Source bytes could be lost while a token or pending delimiter was emitted. | Fixed with input valid/ready. |
| B5A-02 | A one-cycle output pulse could be lost by a busy downstream stage. | Fixed with output valid/ready and stable token holding. |
| B5A-03 | A final identifier/number had no delimiter and was never emitted. | Fixed with `i_eof` flush and `o_done`. |
| B5A-04 | Hardware token numbers and width differed from the C++ parser-facing ABI. | Fixed with `shared/tokens.hpp` IDs and 16-bit words. |
| B5A-05 | Identifier and integer payloads were discarded. | Fixed for the C++ one-character-identifier and low-byte-integer rules. |
| B5A-06 | `lexer.sv` and `lexer_engine.sv` both declare `lexer_engine` with different ports. | Documented; legacy source remains untouched and must not be compiled with the canonical source list. |
| B5B-01 | Compound operators, char/void/else, character literals, and full C++ compound/char states are absent. | Deferred to Beta 5b. |
| B5B-02 | The synthesizable buffer is 32 bytes while C++ uses a dynamically sized buffer. | Sticky `o_error` reports overflow; final language policy is Beta 5b work. |
| B5D-01 | There is no BRAM reader/writer, byte packing, stage controller, Quartus source list, or FPGA integration. | Deferred to Beta 5d. |

#### Tooling observation

The local C++ source and fixtures were inspected directly. CMake is not installed or available on this machine, so the C++ executable was not rebuilt during this pass. This does not block Beta 5a because its checked-in `add_func.hex` fixture is the exact byte-level expected output used by the SystemVerilog regression.

## 2026-10-02 - Code walkthrough comments

Added concise `Beta 5a` comments to the changed SystemVerilog interfaces, state variables, token encoder, handshake guards, EOF flush, output hold behavior, reserved token IDs, and testbench scoreboarding/stall checks. These comments identify why the logic exists and connect it to the original lost-byte bug and the C++ fixture contract; they do not change behavior.

## 2026-10-02 - Bug labels and expanded regression

The fixed paths in `lexer_engine.sv` and their testbench checks now carry explicit labels:

- `BUG-B5A-01`: a byte following a buffered token boundary could be lost. `o_char_ready` prevents the next source transfer until the word and saved delimiter are emitted.
- `BUG-B5A-02`: a one-cycle output could be missed. `LEX_EMIT` retains `o_token_valid` and `o_token` until `i_token_ready` is high.
- `BUG-B5A-03`: EOF could discard an unfinished identifier, number, or string. EOF now flushes through the same output handshake before `o_done` rises.

The regression was extended beyond the C++ `add_func` fixture with directed checks for an identifier-to-operator boundary, keywords/number/punctuation, a float assignment, every currently supported single-character punctuator, the current C++ multi-character-identifier ABI behavior, directives, and strings. The source driver also waits for `o_char_ready` before asserting EOF, because EOF is consumed in `LEX_READ` after final-byte processing, not as a byte ready/valid transfer. These tests cover the Beta 5a feature set only; compound operators and character literals remain Beta 5b work.

## 2026-10-08 - Beta 5b language coverage

### Implemented

- Added `char`, `void`, and `else` keyword classification using the existing C++ token IDs.
- Added lookahead for `+=`, `-=`, and `!=`. If the next byte is not `=`, the lexer emits the single-character operator and replays that byte as the next input character.
- Added single-quoted character literals. A one-byte literal carries its ASCII payload; empty or multi-byte literals use payload `FF`, matching the current C++ emitter. Unterminated nonempty character literals flush at EOF like the C++ `run()` method.
- Added compound-operator EOF handling: a final `+`, `-`, or `!` flushes as the corresponding single operator.
- Replaced the punctuation-only pending-token path with a one-byte replay register. It preserves any non-whitespace boundary byte, including a quote, digit, identifier start, or operator lookahead.
- Defined the 32-byte buffer policy: bytes beyond capacity set sticky `o_error` and are not stored; scanning continues. Identifiers still classify as `TOK_NONE` when too long to match a keyword, strings still emit `STR`, and character literals emit `CHAR`. Integer payload uses a separate 8-bit decimal accumulator and wraps modulo 256. This is deterministic hardware behavior; the C++ reference uses signed `int`, whose overflow for sufficiently long literals is undefined, so very long integers are not a portable cross-language comparison.
- Expanded the testbench to check new keywords, all compound operators, single-operator fallback, character literal payloads/EOF, boundary-byte replay, and identifier/integer/string overflow reporting.

### Verification

The combined Beta 5a/5b testbench compiles with 0 errors and 0 warnings. All 22 directed cases pass, including the exact C++ `add_func` fixture and Beta 5a back-pressure/reset/EOF regressions. The focused overflow tests confirm `o_error` is raised while token framing and deterministic integer low-byte output remain correct.

### Deferred

- Beta 5c will run the full checked-in C++ fixture set and add broader boundary, malformed-input, and stress coverage.
- Beta 5d will connect the stream interface to BRAM and the production controller. No BRAM/FPGA integration is included in Beta 5b.

## Current known limits after Beta 5b

- Escape-sequence decoding in character literals is not implemented; the current C++ lexer also treats literal contents as raw bytes.
- `o_error` reports that token text exceeded the 32-byte scratch buffer; the lexer continues and emits a token using the fields it retained/accumulated. A production controller should inspect this signal.
- Beta 5c full-fixture regression and Beta 5d BRAM integration are still pending.
- The core is a byte-stream IP block only. BRAM input packing, output token storage, and HPS/FPGA integration are Beta 5d work.
- The C++ reference currently limits binary identifier payloads to one character. A multi-character non-keyword identifier produces `TOK_NONE` in the C++ binary ABI; Beta 5a preserves that behavior.

## 2026-10-23 - Beta 5c full regression

- Added `lexer_engine_fixture_tb.sv`, which reads a real C source file and its
  paired expected-token hex file, checks every accepted 16-bit word in order,
  and reports the first mismatching token index.
- Added `run-beta5c-tests.ps1`. It verifies all 36 token IDs against the
  software header, compiles the canonical RTL source list, runs the directed
  suite, and runs all 12 checked-in software fixtures twice: normal timing and
  stressed timing with input gaps/output backpressure.
- Expanded the directed suite from 22 to 31 cases. New coverage includes empty
  input, float/string/character EOF behavior, 31/32-byte boundaries, malformed
  simultaneous input/EOF, and the full-buffer decimal-point regression.
- Fixed `BUG-B5C-01`: a decimal point still marks a number as floating point
  when the scratch buffer is already full. Overflow remains sticky and the
  token is now correctly emitted as `TOK_FLOAT`.
- Verified with ModelSim Intel FPGA Edition 2020.1: compilation 0 errors and 0
  warnings; 31 directed cases passed; 12/12 fixtures passed normally; 12/12
  fixtures passed with gaps/stalls; 24 fixture simulations passed, 0 failed.
- Documented the test/reference origin of the bundled `SW_Lexer` fixtures and
  the C++ EOF inconsistency for unknown multi-character identifiers.
- No BRAM adapter, synthesis, FPGA measurement, remote push, merge, or pull
  request is part of Beta 5c.

Detailed commands and evidence are in `docs/BETA5C_TESTING.md`.

## 2026-11-13 - Standalone repository packaging

- Packaged the canonical Beta 5c RTL, both testbenches, regression runner,
  reference token header, and all 12 fixture pairs in a standalone repository.
- Excluded legacy conflicting lexer modules, presentation assets, ModelSim
  libraries, transcripts, and waveform files.
- Reran the standalone regression with ModelSim 2020.1: 36/36 token IDs
  matched, 31 directed cases passed, and 24/24 fixture simulations passed.

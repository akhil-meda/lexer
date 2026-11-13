# Beta 5c verification stage

Initial implementation: 23 October 2026

Standalone repository verification: 13 November 2026

Beta 5c broadens verification of the standalone byte-stream lexer. It does not
connect the lexer to BRAM; that remains Beta 5d.

## What Beta 5c adds

- A file-driven SystemVerilog testbench that reads a real `.c` source fixture
  and its paired expected 16-bit `.hex` token stream.
- A PowerShell runner that checks the shared 36-entry token ABI, compiles both
  testbenches, runs the directed regression, and executes all 12 fixtures.
- A second fixture pass with a one-cycle gap before every input byte and a
  periodic output stall every third cycle.
- Directed cases for empty input, each unfinished EOF mode, 31/32-byte buffer
  boundaries, malformed simultaneous input/EOF, and a decimal point arriving
  after the 32-byte buffer is full.
- First-mismatch diagnostics containing the fixture name, token index,
  expected word, and actual word.

## Bug fixed

`BUG-B5C-01`: in number mode, `has_dot` was set only when the decimal point
could be stored in the 32-byte scratch buffer. A number containing exactly 32
digits followed by `.` therefore raised overflow but could be emitted as an
integer. The lexer now records the decimal point independently of whether its
text fits in the scratch buffer. The regression
`oversized_float_decimal_boundary` expects `FLOAT/FF` and `o_error=1`.

## Run everything

From PowerShell:

```powershell
cd C:\Users\akhil\code\lexer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-beta5c-tests.ps1
```

The standalone repository includes the 12 input fixtures, expected token
streams, and the reference token header. Use `-FixtureRoot` only to test an
alternate compatible fixture directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run-beta5c-tests.ps1 `
  -FixtureRoot "D:\path\to\compatible-fixtures"
```

Use `-SkipStress` for one normal fixture pass only.

## Verified result

ModelSim Intel FPGA Edition 2020.1, last rerun from the standalone repository
on 13 November 2026:

- SystemVerilog compilation: 0 errors, 0 warnings.
- Shared token ABI: all 36 hardware/software IDs match.
- Directed tests: 31 passed.
- Software fixtures, normal timing: 12 of 12 passed.
- Software fixtures, input gaps and output stalls: 12 of 12 passed.
- Total fixture simulations: 24 passed, 0 failed.

The largest fixture is `matrix_mult.c`, with 103 expected token words.

## Dependency and oracle policy

The Beta 5c regression includes copies of `SW_Lexer` test inputs, expected
binary streams, and `shared/tokens.hpp` under `tests/` and `reference/`. These
are test/reference data under the included MIT notice. The synthesized lexer
has no C++ or Python dependency.

The checked-in expected hex files are the comparison oracle. The runner never
rewrites them. The C++ implementation has an EOF inconsistency for an unknown
multi-character identifier: its delimiter path produces `NONE/FF`, while its
direct EOF path can produce `IDENT/FF`. Hardware keeps the fixture-compatible
`NONE/FF` policy consistently; the discrepancy is documented rather than
silently changing expected output.

Very long integer strings are also not compared against C++ arithmetic because
the C++ implementation accumulates into signed `int`, where overflow is not a
portable oracle. Hardware deliberately computes the low byte modulo 256 and
raises `o_error` when the text buffer overflows.

## Exit condition and remaining work

Beta 5c's standalone verification exit condition is met by the results above.
Beta 5d must define BRAM byte packing, source length/EOF generation, read
latency, token-memory capacity, token count, error propagation, and stage-level
completion before the lexer can be called production-integrated.

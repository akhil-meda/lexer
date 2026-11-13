// synthesis translate_off
`timescale 1ns/1ps
import lexer_pkg::*;

module lexer_engine_tb;
  logic        clk = 1'b0;
  logic        rst_n;
  logic        i_start;
  logic [7:0]  i_char;
  logic        i_char_valid;
  logic        i_eof;
  logic        o_char_ready;
  logic [15:0] o_token;
  logic        o_token_valid;
  logic        i_token_ready;
  logic        o_done;
  logic        o_error;

  always #5 clk = ~clk;

  lexer_engine dut (
    .clk(clk),
    .rst_n(rst_n),
    .i_start(i_start),
    .i_char(i_char),
    .i_char_valid(i_char_valid),
    .i_eof(i_eof),
    .o_char_ready(o_char_ready),
    .o_token(o_token),
    .o_token_valid(o_token_valid),
    .i_token_ready(i_token_ready),
    .o_done(o_done),
    .o_error(o_error)
  );

  task automatic reset_dut;
    rst_n         = 1'b0;
    i_start       = 1'b0;
    i_char        = 8'd0;
    i_char_valid  = 1'b0;
    i_eof         = 1'b0;
    i_token_ready = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
  endtask

  task automatic start_dut;
    @(negedge clk);
    i_start = 1'b1;
    @(negedge clk);
    i_start = 1'b0;
  endtask

  // Models the source-side ready/valid contract. This specifically protects
  // BUG-B5A-01: the test driver must keep a byte stable while the lexer emits
  // the preceding token or its saved delimiter.
  task automatic send_char(input logic [7:0] c);
    @(negedge clk);
    i_char       = c;
    i_char_valid = 1'b1;
    do begin
      @(posedge clk);
    end while (!o_char_ready);
    @(negedge clk);
    i_char_valid = 1'b0;
  endtask

  task automatic send_source(input string source);
    int idx;
    start_dut();
    for (idx = 0; idx < source.len(); idx++) begin
      send_char(source[idx]);
    end

    // EOF is an event consumed only in LEX_READ. A final delimiter such as
    // `;` may still be producing its word (and a saved delimiter) after its
    // byte transfer, so wait for the source side to become ready again before
    // raising EOF. This prevents the test driver from violating the protocol.
    @(negedge clk);
    while (!o_char_ready) begin
      @(negedge clk);
    end
    i_eof = 1'b1;
    @(posedge clk);
    @(negedge clk);
    i_eof = 1'b0;
  endtask

  task automatic check_case(
    input string       name,
    input string       source,
    input logic [15:0] expected[],
    input int          expected_len,
    input bit          stall_first_token,
    input bit          expected_error
  );
    int exp_idx;
    int guard;
    exp_idx = 0;
    guard   = 0;

    // Run source driving, an optional downstream stall, and scoreboarding in
    // parallel. The checker counts only valid/ready token transfers, matching
    // the BUG-B5A-02 output contract rather than sampling a transient pulse.
    fork
      begin
        send_source(source);
      end
      begin
        if (stall_first_token) begin
          wait (o_token_valid);
          @(negedge clk);
          i_token_ready = 1'b0;
          repeat (3) @(negedge clk);
          i_token_ready = 1'b1;
        end
      end
      begin
        while (!o_done) begin
          @(posedge clk);
          if (o_token_valid && i_token_ready) begin
            if (exp_idx >= expected_len || o_token !== expected[exp_idx]) begin
              $error("%s token mismatch at %0d exp=%h got=%h", name, exp_idx,
                     exp_idx < expected_len ? expected[exp_idx] : 16'hxxxx, o_token);
              $finish;
            end
            exp_idx++;
          end
          guard++;
          if (guard > 4000) begin
            $error("%s timed out", name);
            $finish;
          end
        end

        if (exp_idx != expected_len) begin
          $error("%s ended after %0d tokens; expected %0d", name, exp_idx, expected_len);
          $finish;
        end
        if (o_error !== expected_error) begin
          $error("%s o_error mismatch; expected %0b got %0b", name, expected_error, o_error);
          $finish;
        end
      end
    join

    $display("%s: pass", name);
  endtask

  task automatic check_reset_recovery;
    // Begin an identifier, reset before its delimiter/EOF, then prove that
    // the stale partial token cannot appear in the next transaction.
    reset_dut();
    start_dut();
    send_char("z");

    @(negedge clk);
    rst_n        = 1'b0;
    i_char_valid = 1'b0;
    i_eof        = 1'b0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    check_case("reset_recovery", "x", eof_ident_expected, 1, 1'b0, 1'b0);
  endtask

  task automatic check_simultaneous_eof_and_input_error;
    // BUG-B5C-02 coverage: EOF is a separate control event and must not be
    // asserted in the same cycle as a valid source byte. The core reports the
    // protocol violation instead of silently accepting an ambiguous transfer.
    reset_dut();
    start_dut();
    @(negedge clk);
    while (!o_char_ready) @(negedge clk);
    i_char       = "x";
    i_char_valid = 1'b1;
    i_eof        = 1'b1;
    @(posedge clk);
    @(negedge clk);
    i_char_valid = 1'b0;
    i_eof        = 1'b0;

    if (!o_done || !o_error) begin
      $error("simultaneous_eof_and_input_error expected done=1 error=1; got done=%0b error=%0b",
             o_done, o_error);
      $finish;
    end
    $display("simultaneous_eof_and_input_error: pass");
  endtask

  // Exact C++ fixture: SW_Lexer/tests/inputs/add_func.c -> expected_binary/add_func.hex.
  // This contains the original problematic `d(` -> `int` boundary.
  logic [15:0] add_expected [0:15] = '{
    16'h15ff, 16'h1d64, 16'h01ff, 16'h15ff,
    16'h1d61, 16'h08ff, 16'h15ff, 16'h1d62,
    16'h02ff, 16'h03ff, 16'h1cff, 16'h1d61,
    16'h09ff, 16'h1d62, 16'h07ff, 16'h04ff
  };

  logic [15:0] eof_ident_expected [0:0] = '{16'h1d78};
  logic [15:0] eof_int_expected   [0:0] = '{16'h1e2a};
  logic [15:0] ident_plus_ident_expected [0:2] = '{
    16'h1d61, 16'h09ff, 16'h1d62
  };
  logic [15:0] keyword_number_expected [0:8] = '{
    16'h19ff, 16'h01ff, 16'h1d78, 16'h02ff, 16'h03ff,
    16'h1cff, 16'h1e07, 16'h07ff, 16'h04ff
  };
  logic [15:0] float_assignment_expected [0:4] = '{
    16'h16ff, 16'h1d66, 16'h0eff, 16'h1fff, 16'h07ff
  };
  logic [15:0] punctuator_expected [0:17] = '{
    16'h01ff, 16'h02ff, 16'h03ff, 16'h04ff, 16'h05ff, 16'h06ff,
    16'h08ff, 16'h07ff, 16'h09ff, 16'h0aff, 16'h0bff, 16'h0cff,
    16'h0dff, 16'h1d78, 16'h0eff, 16'h0fff, 16'h10ff, 16'h11ff
  };
  // This unusual result is intentional C++ ABI compatibility: only a
  // one-character non-keyword identifier fits in the current 16-bit word.
  logic [15:0] multichar_ident_expected [0:0] = '{16'h00ff};
  logic [15:0] directive_expected       [0:0] = '{16'h22ff};
  logic [15:0] string_expected          [0:0] = '{16'h21ff};
  logic [15:0] new_keywords_expected [0:2] = '{16'h17ff, 16'h18ff, 16'h1bff};
  logic [15:0] compound_expected [0:11] = '{
    16'h1d61, 16'h12ff, 16'h1e01, 16'h07ff,
    16'h1d62, 16'h13ff, 16'h1e02, 16'h07ff,
    16'h1d63, 16'h14ff, 16'h1e03, 16'h07ff
  };
  logic [15:0] char_literals_expected [0:2] = '{16'h2051, 16'h20ff, 16'h20ff};
  logic [15:0] char_eof_expected [0:0] = '{16'h207a};
  logic [15:0] identifier_then_string_expected [0:1] = '{16'h1d61, 16'h21ff};
  logic [15:0] compound_fallback_expected [0:2] = '{16'h09ff, 16'h1d78, 16'h0dff};
  logic [15:0] compound_eof_expected [0:0] = '{16'h0aff};
  logic [15:0] overflow_identifier_expected [0:0] = '{16'h00ff};
  logic [15:0] overflow_integer_expected [0:0] = '{16'h1e00};
  logic [15:0] overflow_string_expected [0:0] = '{16'h21ff};
  logic [15:0] overflow_char_expected [0:0] = '{16'h20ff};
  logic [15:0] no_tokens_expected [0:0] = '{16'h0000};
  logic [15:0] eof_float_expected [0:0] = '{16'h1fff};
  logic [15:0] eof_string_expected [0:0] = '{16'h21ff};
  logic [15:0] boundary_identifier_expected [0:0] = '{16'h00ff};
  logic [15:0] oversized_float_expected [0:0] = '{16'h1fff};

  initial begin
    $dumpfile("lexer_engine_tb.vcd");
    $dumpvars(0, lexer_engine_tb);

    reset_dut();
    // Stalling the first output verifies that o_token is held stable rather
    // than disappearing after one cycle.
    check_case(
      "add_func_input_and_output_stall",
      "int d(int a, int b) {\n    return a + b;\n}",
      add_expected,
      16,
      1'b1,
      1'b0
    );

    reset_dut();
    check_case("eof_identifier", "x", eof_ident_expected, 1, 1'b0, 1'b0);

    reset_dut();
    check_case("eof_integer", "42", eof_int_expected, 1, 1'b0, 1'b0);

    reset_dut();
    // A non-whitespace delimiter must be preserved behind the identifier.
    // This is a short, direct regression for the original BUG-B5A-01 path.
    check_case("identifier_plus_identifier", "a+b", ident_plus_ident_expected, 3, 1'b0, 1'b0);

    reset_dut();
    check_case("keywords_number_and_punctuation", "while(x){return 7;}",
               keyword_number_expected, 9, 1'b0, 1'b0);

    reset_dut();
    check_case("float_assignment", "float f=3.5;", float_assignment_expected, 5, 1'b0, 1'b0);

    reset_dut();
    check_case("all_supported_punctuators", "(){}[],;+-*/!x=><&",
               punctuator_expected, 18, 1'b0, 1'b0);

    reset_dut();
    check_case("multichar_identifier_cxx_abi", "abc", multichar_ident_expected, 1, 1'b0, 1'b0);

    reset_dut();
    check_case("directive", "#include", directive_expected, 1, 1'b0, 1'b0);

    reset_dut();
    check_case("string", "\"hi\"", string_expected, 1, 1'b0, 1'b0);

    reset_dut();
    check_case("beta5b_keywords", "char void else", new_keywords_expected, 3, 1'b0, 1'b0);

    reset_dut();
    check_case("compound_operators", "a+=1;b-=2;c!=3;", compound_expected, 12, 1'b0, 1'b0);

    reset_dut();
    check_case("character_literals", "'Q' 'ab' ''", char_literals_expected, 3, 1'b0, 1'b0);

    reset_dut();
    check_case("character_literal_eof", "'z", char_eof_expected, 1, 1'b0, 1'b0);

    reset_dut();
    check_case("identifier_followed_by_string", "a\"b\"",
               identifier_then_string_expected, 2, 1'b0, 1'b0);

    reset_dut();
    check_case("compound_single_fallback", "+x!", compound_fallback_expected, 3, 1'b0, 1'b0);

    reset_dut();
    check_case("compound_operator_eof", "-", compound_eof_expected, 1, 1'b0, 1'b0);

    reset_dut();
    check_case("identifier_buffer_overflow",
               "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               overflow_identifier_expected, 1, 1'b0, 1'b1);

    reset_dut();
    check_case("integer_buffer_overflow",
               "100000000000000000000000000000000",
               overflow_integer_expected, 1, 1'b0, 1'b1);

    reset_dut();
    check_case("string_buffer_overflow",
               "\"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq\"",
               overflow_string_expected, 1, 1'b0, 1'b1);

    reset_dut();
    check_case("character_buffer_overflow",
               "'qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'",
               overflow_char_expected, 1, 1'b0, 1'b1);

    check_reset_recovery();

    reset_dut();
    check_case("empty_source", "", no_tokens_expected, 0, 1'b0, 1'b0);

    reset_dut();
    check_case("eof_float", "1.5", eof_float_expected, 1, 1'b0, 1'b0);

    reset_dut();
    check_case("unterminated_string_eof", "\"abc", eof_string_expected, 1, 1'b0, 1'b0);

    reset_dut();
    check_case("empty_unterminated_string_eof", "\"", no_tokens_expected, 0, 1'b0, 1'b0);

    reset_dut();
    check_case("empty_unterminated_character_eof", "'", no_tokens_expected, 0, 1'b0, 1'b0);

    reset_dut();
    check_case("identifier_length_31",
               "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               boundary_identifier_expected, 1, 1'b0, 1'b0);

    reset_dut();
    check_case("identifier_length_32",
               "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               boundary_identifier_expected, 1, 1'b0, 1'b0);

    reset_dut();
    check_case("oversized_float_decimal_boundary",
               "11111111111111111111111111111111.",
               oversized_float_expected, 1, 1'b0, 1'b1);

    check_simultaneous_eof_and_input_error();

    $display("Beta 5a/5b/5c directed tests passed");
    $finish;
  end
endmodule
// synthesis translate_on

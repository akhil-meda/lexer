// synthesis translate_off
`timescale 1ns/1ps
import lexer_pkg::*;

// Beta 5c file-driven regression harness.
// One simulation reads one C source fixture and its paired expected .hex file.
// Paths and optional stress settings are supplied through plusargs by
// run-beta5c-tests.ps1.
module lexer_engine_fixture_tb;
  localparam int MAX_EXPECTED_TOKENS = 4096;

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

  string source_path;
  string expected_path;
  string case_name;
  integer input_gap_cycles;
  integer output_stall_period;

  logic [15:0] expected_words [0:MAX_EXPECTED_TOKENS-1];
  integer expected_count;
  integer observed_count;
  integer failed;

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

  task automatic load_expected_words;
    integer expected_fd;
    integer scan_status;
    integer discard_char;
    logic [15:0] scanned_word;
    begin
      expected_count = 0;
      expected_fd = $fopen(expected_path, "r");
      if (expected_fd == 0) begin
        $display("BETA5C_FIXTURE_FAIL %s: cannot open expected file %s",
                 case_name, expected_path);
        $finish;
      end

      while (!$feof(expected_fd)) begin
        scan_status = $fscanf(expected_fd, "%h", scanned_word);
        if (scan_status == 1) begin
          if (expected_count >= MAX_EXPECTED_TOKENS) begin
            $display("BETA5C_FIXTURE_FAIL %s: expected file exceeds %0d tokens",
                     case_name, MAX_EXPECTED_TOKENS);
            $finish;
          end
          expected_words[expected_count] = scanned_word;
          expected_count = expected_count + 1;
        end else begin
          discard_char = $fgetc(expected_fd);
        end
      end
      $fclose(expected_fd);
    end
  endtask

  task automatic reset_and_start;
    begin
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
      @(negedge clk);
      i_start = 1'b1;
      @(negedge clk);
      i_start = 1'b0;
    end
  endtask

  task automatic send_char(input logic [7:0] value);
    integer gap_index;
    begin
      for (gap_index = 0; gap_index < input_gap_cycles; gap_index = gap_index + 1)
        @(negedge clk);

      i_char       = value;
      i_char_valid = 1'b1;
      do begin
        @(posedge clk);
      end while (!o_char_ready);
      @(negedge clk);
      i_char_valid = 1'b0;
    end
  endtask

  task automatic drive_source_file;
    integer source_fd;
    integer next_char;
    begin
      source_fd = $fopen(source_path, "rb");
      if (source_fd == 0) begin
        $display("BETA5C_FIXTURE_FAIL %s: cannot open source file %s",
                 case_name, source_path);
        failed = 1;
      end else begin
        next_char = $fgetc(source_fd);
        while (next_char >= 0) begin
          send_char(next_char[7:0]);
          next_char = $fgetc(source_fd);
        end
        $fclose(source_fd);

        // EOF is a control event. Wait until all replay/output work caused by
        // the final source byte has released the source interface.
        @(negedge clk);
        while (!o_char_ready) @(negedge clk);
        i_eof = 1'b1;
        @(posedge clk);
        @(negedge clk);
        i_eof = 1'b0;
      end
    end
  endtask

  task automatic apply_output_stalls;
    integer cycle_count;
    begin
      cycle_count = 0;
      while (!o_done && !failed) begin
        @(negedge clk);
        if (output_stall_period > 0 &&
            cycle_count == output_stall_period - 1) begin
          i_token_ready = 1'b0;
          cycle_count   = 0;
        end else begin
          i_token_ready = 1'b1;
          cycle_count   = cycle_count + 1;
        end
      end
      i_token_ready = 1'b1;
    end
  endtask

  task automatic check_tokens;
    integer guard;
    begin
      observed_count = 0;
      guard          = 0;
      while (!o_done && !failed) begin
        @(posedge clk);
        if (o_token_valid && i_token_ready) begin
          if (observed_count >= expected_count) begin
            $display("BETA5C_FIXTURE_FAIL %s: unexpected token[%0d]=%04h",
                     case_name, observed_count, o_token);
            failed = 1;
          end else if (o_token !== expected_words[observed_count]) begin
            $display("BETA5C_FIXTURE_FAIL %s: token[%0d] expected=%04h got=%04h",
                     case_name, observed_count,
                     expected_words[observed_count], o_token);
            failed = 1;
          end
          observed_count = observed_count + 1;
        end

        guard = guard + 1;
        if (guard > 100000) begin
          $display("BETA5C_FIXTURE_FAIL %s: timed out after %0d cycles",
                   case_name, guard);
          failed = 1;
        end
      end

      if (!failed && observed_count != expected_count) begin
        $display("BETA5C_FIXTURE_FAIL %s: observed %0d tokens, expected %0d",
                 case_name, observed_count, expected_count);
        failed = 1;
      end
      if (!failed && o_error) begin
        $display("BETA5C_FIXTURE_FAIL %s: unexpected o_error", case_name);
        failed = 1;
      end
    end
  endtask

  initial begin
    failed              = 0;
    input_gap_cycles    = 0;
    output_stall_period = 0;

    if (!$value$plusargs("SOURCE=%s", source_path) ||
        !$value$plusargs("EXPECTED=%s", expected_path) ||
        !$value$plusargs("CASE=%s", case_name)) begin
      $display("BETA5C_FIXTURE_FAIL missing +SOURCE, +EXPECTED, or +CASE plusarg");
      $finish;
    end
    void'($value$plusargs("INPUT_GAP=%d", input_gap_cycles));
    void'($value$plusargs("STALL_PERIOD=%d", output_stall_period));

    load_expected_words();
    reset_and_start();

    fork
      drive_source_file();
      apply_output_stalls();
      check_tokens();
    join

    if (failed) begin
      $display("BETA5C_FIXTURE_RESULT FAIL %s", case_name);
    end else begin
      $display("BETA5C_FIXTURE_PASS %s tokens=%0d gap=%0d stall_period=%0d",
               case_name, observed_count, input_gap_cycles, output_stall_period);
    end
    $finish;
  end
endmodule

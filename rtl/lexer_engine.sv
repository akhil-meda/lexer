`timescale 1ns/1ps
import lexer_pkg::*;

// Beta 5c streaming lexer core. Beta 5a established the streaming protocol,
// Beta 5b added C++ small-C keyword/operator/literal modes, and Beta 5c adds
// full-fixture and boundary regression coverage.
// A source byte transfers only when i_char_valid && o_char_ready.
// A token transfers only when o_token_valid && i_token_ready.
module lexer_engine (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_start,       // Starts a new source stream from START or DONE.
  input  logic [7:0]  i_char,
  input  logic        i_char_valid,  // Source holds i_char stable until ready is high.
  input  logic        i_eof,         // Assert after final byte processing has returned ready.
  output logic        o_char_ready,  // High only when the core can accept one byte.
  output logic [15:0] o_token,       // {C++ token ID, payload}; held stable while stalled.
  output logic        o_token_valid, // Token is available when valid and ready are both high.
  input  logic        i_token_ready, // Future token-BRAM writer or parser back-pressure.
  output logic        o_done,        // Raised after the final token has been accepted.
  output logic        o_error        // Sticky protocol or fixed-buffer-overflow indication.
);

  localparam int BUF_MAX = 32;

  // Buffer policy: one shared 32-byte scratch buffer stores text needed for
  // classification/payload. Overflow sets sticky o_error, drops excess text,
  // and continues scanning. Integer payload is accumulated separately so a
  // long integer still matches the C++ low-byte token ABI.
  typedef enum logic [2:0] {
    MODE_IDLE     = 3'd0,
    MODE_IDENT    = 3'd1,
    MODE_NUMBER   = 3'd2,
    MODE_STRING   = 3'd3,
    MODE_COMPOUND = 3'd4,
    MODE_CHAR_LIT = 3'd5
  } lex_mode_e;

  lex_state_e state;
  lex_mode_e  mode;

  logic [7:0] buffer [0:BUF_MAX-1];
  logic [5:0] buf_len;
  logic       has_dot;
  logic       directive_flag;
  logic [7:0] integer_low_byte;
  logic [7:0] compound_start_char;
  logic [7:0] replay_char;
  logic       replay_valid;

  // BUG-B5A-03 (fixed): EOF may create one final token. Do not enter DONE
  // until that token has completed the same valid/ready handshake as normal.
  logic   finish_after_emit;
  logic   error_latched;     // Stays high until reset or a new i_start transaction.

  function automatic bit is_whitespace(input logic [7:0] c);
    return c == 8'h20 || c == 8'h09 || c == 8'h0a || c == 8'h0d;
  endfunction

  function automatic bit is_letter(input logic [7:0] c);
    return (c >= "A" && c <= "Z") || (c >= "a" && c <= "z");
  endfunction

  function automatic bit is_digit(input logic [7:0] c);
    return c >= "0" && c <= "9";
  endfunction

  // Matches the current C++ reference lexer exactly.
  function automatic bit is_ident_start(input logic [7:0] c);
    return is_letter(c) || c == 8'h5f || c == 8'h23;  // _ or #
  endfunction

  function automatic bit is_ident_char(input logic [7:0] c);
    return is_ident_start(c) || is_digit(c);
  endfunction

  function automatic token_e classify_char(input logic [7:0] c);
    unique case (c)
      "(": return TOK_LPAREN;
      ")": return TOK_RPAREN;
      "{": return TOK_LBRACK;
      "}": return TOK_RBRACK;
      "[": return TOK_LSQUARE;
      "]": return TOK_RSQUARE;
      ";": return TOK_SEMI;
      ",": return TOK_COMMA;
      "+": return TOK_PLUS;
      "-": return TOK_MINUS;
      "*": return TOK_MULT;
      "/": return TOK_DIV;
      "!": return TOK_NOT;
      "=": return TOK_EQUALS;
      ">": return TOK_GT;
      "<": return TOK_LT;
      "&": return TOK_ANDREF;
      default: return TOK_NONE;
    endcase
  endfunction

  function automatic token_e classify_identifier(
    input logic [7:0] bytes [0:BUF_MAX-1],
    input logic [5:0] length,
    input logic        is_directive
  );
    if (is_directive) return TOK_DIRECTIVE;
    if (length == 3 && bytes[0] == "i" && bytes[1] == "n" && bytes[2] == "t")
      return TOK_INT_WORD;
    if (length == 4 && bytes[0] == "c" && bytes[1] == "h" && bytes[2] == "a" &&
                       bytes[3] == "r")
      return TOK_CHAR_WORD;
    if (length == 4 && bytes[0] == "v" && bytes[1] == "o" && bytes[2] == "i" &&
                       bytes[3] == "d")
      return TOK_VOID_WORD;
    if (length == 4 && bytes[0] == "e" && bytes[1] == "l" && bytes[2] == "s" &&
                       bytes[3] == "e")
      return TOK_ELSE;
    if (length == 5 && bytes[0] == "f" && bytes[1] == "l" && bytes[2] == "o" &&
                       bytes[3] == "a" && bytes[4] == "t")
      return TOK_FLOAT_WORD;
    if (length == 5 && bytes[0] == "w" && bytes[1] == "h" && bytes[2] == "i" &&
                       bytes[3] == "l" && bytes[4] == "e")
      return TOK_WHILE;
    if (length == 2 && bytes[0] == "i" && bytes[1] == "f")
      return TOK_IF;
    if (length == 6 && bytes[0] == "r" && bytes[1] == "e" && bytes[2] == "t" &&
                       bytes[3] == "u" && bytes[4] == "r" && bytes[5] == "n")
      return TOK_RETURN;

    // The C++ binary ABI carries only one identifier byte in a token word.
    return length == 1 ? TOK_IDENT : TOK_NONE;
  endfunction

  function automatic logic [7:0] token_payload(
    input token_e     tok,
    input logic [7:0] bytes [0:BUF_MAX-1],
    input logic [5:0] length,
    input logic [7:0] int_low_byte
  );
    logic [7:0] value;
    value = 8'hff;

    // Shared software/hardware token ABI: one-byte IDENT/CHAR values and INT
    // values carry payloads; bare tokens and multi-byte values use FF.
    if (tok == TOK_IDENT && length == 1) begin
      value = bytes[0];
    end else if (tok == TOK_INT) begin
      value = int_low_byte;
    end else if (tok == TOK_CHAR && length == 1) begin
      value = bytes[0];
    end

    return value;
  endfunction

  // BUG-B5A-01 (fixed): Never accept a new source byte while a token is being
  // emitted. A boundary/lookahead byte already accepted from the source is
  // replayed internally before another source byte can be accepted.
  assign o_char_ready  = state == LEX_READ && !replay_valid;
  // BUG-B5A-02 (fixed): the old one-cycle output pulse could be missed by a
  // busy parser or token-BRAM writer. EMIT holds valid and o_token unchanged
  // until the consumer explicitly acknowledges it with i_token_ready.
  assign o_token_valid = state == LEX_EMIT;
  assign o_done        = state == LEX_DONE;
  assign o_error       = error_latched;

  always_ff @(posedge clk or negedge rst_n) begin : lexer_sequential
    token_e classified;
    token_e compound_tok;
    logic [7:0] active_char;
    int idx;

    if (!rst_n) begin
      state                 <= LEX_START;
      mode                  <= MODE_IDLE;
      buf_len               <= 6'd0;
      has_dot               <= 1'b0;
      directive_flag        <= 1'b0;
      integer_low_byte      <= 8'd0;
      compound_start_char   <= 8'd0;
      replay_char           <= 8'd0;
      replay_valid          <= 1'b0;
      finish_after_emit     <= 1'b0;
      error_latched         <= 1'b0;
      o_token               <= 16'h0000;
      for (idx = 0; idx < BUF_MAX; idx++) begin
        buffer[idx] <= 8'd0;
      end
    end else begin
      active_char = replay_valid ? replay_char : i_char;
      unique case (state)
        LEX_START: begin
          if (i_start) begin
            mode               <= MODE_IDLE;
            buf_len            <= 6'd0;
            has_dot            <= 1'b0;
            directive_flag     <= 1'b0;
            replay_valid       <= 1'b0;
            integer_low_byte   <= 8'd0;
            finish_after_emit  <= 1'b0;
            error_latched      <= 1'b0;
            state              <= LEX_READ;
          end
        end

        LEX_READ: begin
          // Replayed delimiters/lookahead bytes are handled before live input.
          if (i_eof && !replay_valid) begin
            // BUG-B5A-03 (fixed): EOF replaces the delimiter normally needed
            // to close a buffered identifier/number/string. The final token
            // still uses EMIT, so it cannot be lost during output backpressure.
            if (i_char_valid) begin
              // The source interface must not transfer a byte and EOF together.
              error_latched <= 1'b1;
            end

            unique case (mode)
              MODE_IDENT: begin
                if (buf_len != 0) begin
                  classified        = classify_identifier(buffer, buf_len, directive_flag);
                  o_token           <= {classified, token_payload(classified, buffer, buf_len, integer_low_byte)};
                  finish_after_emit <= 1'b1;
                  state             <= LEX_EMIT;
                end else begin
                  state <= LEX_DONE;
                end
              end

              MODE_NUMBER: begin
                if (buf_len != 0) begin
                  classified        = has_dot ? TOK_FLOAT : TOK_INT;
                  o_token           <= {classified, token_payload(classified, buffer, buf_len, integer_low_byte)};
                  finish_after_emit <= 1'b1;
                  state             <= LEX_EMIT;
                end else begin
                  state <= LEX_DONE;
                end
              end

              MODE_STRING: begin
                if (buf_len != 0) begin
                  o_token           <= {TOK_STR, 8'hff};
                  finish_after_emit <= 1'b1;
                  state             <= LEX_EMIT;
                end else begin
                  state <= LEX_DONE;
                end
              end

              MODE_CHAR_LIT: begin
                if (buf_len != 0) begin
                  o_token           <= {TOK_CHAR, token_payload(TOK_CHAR, buffer, buf_len, integer_low_byte)};
                  finish_after_emit <= 1'b1;
                  state             <= LEX_EMIT;
                end else begin
                  state <= LEX_DONE;
                end
              end

              MODE_COMPOUND: begin
                // Match C++ run(): unfinished +, -, ! become single tokens.
                unique case (compound_start_char)
                  "+": o_token <= {TOK_PLUS, 8'hff};
                  "-": o_token <= {TOK_MINUS, 8'hff};
                  default: o_token <= {TOK_NOT, 8'hff};
                endcase
                finish_after_emit <= 1'b1;
                state             <= LEX_EMIT;
              end

              default: state <= LEX_DONE;
            endcase

            mode           <= MODE_IDLE;
            buf_len        <= 6'd0;
            has_dot        <= 1'b0;
            directive_flag <= 1'b0;
          end else if (replay_valid || i_char_valid) begin
            if (replay_valid) replay_valid <= 1'b0;
            unique case (mode)
              MODE_IDENT: begin
                if (is_ident_char(active_char)) begin
                  if (buf_len < BUF_MAX) begin
                    buffer[buf_len] <= active_char;
                    buf_len         <= buf_len + 6'd1;
                  end else begin
                    error_latched <= 1'b1;
                  end
                end else begin
                  classified        = classify_identifier(buffer, buf_len, directive_flag);
                  o_token           <= {classified, token_payload(classified, buffer, buf_len, integer_low_byte)};
                  mode              <= MODE_IDLE;
                  buf_len           <= 6'd0;
                  directive_flag    <= 1'b0;
                  state             <= LEX_EMIT;

                  // Preserve the delimiter/following token byte. The earlier
                  // implementation saved only punctuation, losing other C++
                  // follow cases such as an adjacent quote or number.
                  if (!is_whitespace(active_char)) begin
                    replay_char  <= active_char;
                    replay_valid <= 1'b1;
                  end
                end
              end

              MODE_NUMBER: begin
                if (is_digit(active_char)) begin
                  integer_low_byte <= integer_low_byte * 8'd10 + (active_char - "0");
                  if (buf_len < BUF_MAX) begin
                    buffer[buf_len] <= active_char;
                    buf_len         <= buf_len + 6'd1;
                  end else begin
                    error_latched <= 1'b1;
                  end
                end else if (active_char == "." && !has_dot) begin
                  // BUG-B5C-01 (fixed): token classification must remember a
                  // decimal point even when the 32-byte text buffer is full.
                  // Storage overflow and FLOAT-vs-INT classification are
                  // separate concerns.
                  has_dot <= 1'b1;
                  if (buf_len < BUF_MAX) begin
                    buffer[buf_len] <= active_char;
                    buf_len         <= buf_len + 6'd1;
                  end else begin
                    error_latched <= 1'b1;
                  end
                end else begin
                  classified        = has_dot ? TOK_FLOAT : TOK_INT;
                  o_token           <= {classified, token_payload(classified, buffer, buf_len, integer_low_byte)};
                  mode              <= MODE_IDLE;
                  buf_len           <= 6'd0;
                  has_dot           <= 1'b0;
                  state             <= LEX_EMIT;

                  if (!is_whitespace(active_char)) begin
                    replay_char  <= active_char;
                    replay_valid <= 1'b1;
                  end
                end
              end

              MODE_STRING: begin
                if (active_char == "\"") begin
                  o_token <= {TOK_STR, 8'hff};
                  mode    <= MODE_IDLE;
                  buf_len <= 6'd0;
                  state   <= LEX_EMIT;
                end else if (buf_len < BUF_MAX) begin
                  buffer[buf_len] <= active_char;
                  buf_len         <= buf_len + 6'd1;
                end else begin
                  error_latched <= 1'b1;
                end
              end

              MODE_CHAR_LIT: begin
                if (active_char == "'") begin
                  o_token <= {TOK_CHAR, token_payload(TOK_CHAR, buffer, buf_len, integer_low_byte)};
                  mode    <= MODE_IDLE;
                  buf_len <= 6'd0;
                  state   <= LEX_EMIT;
                end else if (buf_len < BUF_MAX) begin
                  buffer[buf_len] <= active_char;
                  buf_len         <= buf_len + 6'd1;
                end else begin
                  error_latched <= 1'b1;
                end
              end

              MODE_COMPOUND: begin
                if (active_char == "=") begin
                  unique case (compound_start_char)
                    "+": compound_tok = TOK_PLUSEQ;
                    "-": compound_tok = TOK_MINEQ;
                    default: compound_tok = TOK_NEQ;
                  endcase
                  o_token <= {compound_tok, 8'hff};
                  mode    <= MODE_IDLE;
                  state   <= LEX_EMIT;
                end else begin
                  unique case (compound_start_char)
                    "+": o_token <= {TOK_PLUS, 8'hff};
                    "-": o_token <= {TOK_MINUS, 8'hff};
                    default: o_token <= {TOK_NOT, 8'hff};
                  endcase
                  // The character after +, -, or ! was accepted for
                  // lookahead; replay it after emitting the single operator.
                  replay_char  <= active_char;
                  replay_valid <= 1'b1;
                  mode         <= MODE_IDLE;
                  state        <= LEX_EMIT;
                end
              end

              default: begin
                if (is_whitespace(active_char)) begin
                  // Ignore whitespace.
                end else if (active_char == "\"") begin
                  mode    <= MODE_STRING;
                  buf_len <= 6'd0;
                end else if (active_char == "'") begin
                  mode    <= MODE_CHAR_LIT;
                  buf_len <= 6'd0;
                end else if (active_char == "+" || active_char == "-" || active_char == "!") begin
                  mode                <= MODE_COMPOUND;
                  compound_start_char <= active_char;
                end else if (is_ident_start(active_char)) begin
                  mode           <= MODE_IDENT;
                  directive_flag <= active_char == 8'h23;
                  buf_len        <= 6'd0;
                  if (active_char != 8'h23) begin
                    buffer[0] <= active_char;
                    buf_len   <= 6'd1;
                  end
                end else if (is_digit(active_char)) begin
                  mode      <= MODE_NUMBER;
                  has_dot   <= 1'b0;
                  integer_low_byte <= active_char - "0";
                  buffer[0] <= active_char;
                  buf_len   <= 6'd1;
                end else begin
                  classified = classify_char(active_char);
                  if (classified != TOK_NONE) begin
                    o_token <= {classified, 8'hff};
                    state   <= LEX_EMIT;
                  end
                end
              end
            endcase
          end
        end

        LEX_EMIT: begin
          // BUG-B5A-02 (fixed): Hold the token word unchanged for as many
          // cycles as needed; the sink owns it only on valid && ready.
          if (i_token_ready) begin
            if (finish_after_emit) begin
              finish_after_emit <= 1'b0;
              state             <= LEX_DONE;
            end else begin
              state <= LEX_READ;
            end
          end
        end

        LEX_DONE: begin
          if (i_start) begin
            mode               <= MODE_IDLE;
            buf_len            <= 6'd0;
            has_dot            <= 1'b0;
            directive_flag     <= 1'b0;
            replay_valid       <= 1'b0;
            integer_low_byte   <= 8'd0;
            finish_after_emit  <= 1'b0;
            error_latched      <= 1'b0;
            state              <= LEX_READ;
          end
        end

        default: state <= LEX_START;
      endcase
    end
  end
endmodule

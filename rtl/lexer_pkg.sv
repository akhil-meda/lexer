// Canonical token ABI for the hardware lexer.
// Keep this file numerically aligned with SW_Lexer/shared/tokens.hpp.
package lexer_pkg;
  typedef enum logic [7:0] {
    TOK_NONE        = 8'h00,
    TOK_LPAREN      = 8'h01,  // (
    TOK_RPAREN      = 8'h02,  // )
    TOK_LBRACK      = 8'h03,  // {
    TOK_RBRACK      = 8'h04,  // }
    TOK_LSQUARE     = 8'h05,  // [
    TOK_RSQUARE     = 8'h06,  // ]
    TOK_SEMI        = 8'h07,  // ;
    TOK_COMMA       = 8'h08,  // ,
    TOK_PLUS        = 8'h09,  // +
    TOK_MINUS       = 8'h0a,  // -
    TOK_MULT        = 8'h0b,  // *
    TOK_DIV         = 8'h0c,  // /
    TOK_NOT         = 8'h0d,  // !
    TOK_EQUALS      = 8'h0e,  // =
    TOK_GT          = 8'h0f,  // >
    TOK_LT          = 8'h10,  // <
    TOK_ANDREF      = 8'h11,  // &
    // Reserve Beta 5b IDs now so today's IDs remain identical to C++ as the
    // lexer grows; the current core does not yet recognize these constructs.
    TOK_PLUSEQ      = 8'h12,  // += (Beta 5b behavior)
    TOK_MINEQ       = 8'h13,  // -= (Beta 5b behavior)
    TOK_NEQ         = 8'h14,  // != (Beta 5b behavior)
    TOK_INT_WORD    = 8'h15,
    TOK_FLOAT_WORD  = 8'h16,
    TOK_CHAR_WORD   = 8'h17,  // Beta 5b behavior
    TOK_VOID_WORD   = 8'h18,  // Beta 5b behavior
    TOK_WHILE       = 8'h19,
    TOK_IF          = 8'h1a,
    TOK_ELSE        = 8'h1b,  // Beta 5b behavior
    TOK_RETURN      = 8'h1c,
    TOK_IDENT       = 8'h1d,
    TOK_INT         = 8'h1e,
    TOK_FLOAT       = 8'h1f,
    TOK_CHAR        = 8'h20,  // Beta 5b behavior
    TOK_STR         = 8'h21,
    TOK_DIRECTIVE   = 8'h22,
    TOK_END_OF_FILE = 8'h23   // Reserved; completion is signaled by o_done.
  } token_e;

  typedef enum logic [1:0] {
    LEX_START = 2'd0,
    LEX_READ  = 2'd1,
    LEX_EMIT  = 2'd2,
    LEX_DONE  = 2'd3
  } lex_state_e;
endpackage

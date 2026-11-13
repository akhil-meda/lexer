#pragma once
#include <cstdint>

enum class TokenType : uint8_t {
  NONE          = 0x00,
  LPAREN        = 0x01,
  RPAREN        = 0x02,
  LBRACK        = 0x03,  // {
  RBRACK        = 0x04,  // }
  LSQUARE       = 0x05,  // [
  RSQUARE       = 0x06,  // ]
  SEMI          = 0x07,
  COMMA         = 0x08,
  PLUS          = 0x09,
  MINUS         = 0x0a,
  MULT          = 0x0b,
  DIV           = 0x0c,
  NOT           = 0x0d,
  EQUALS        = 0x0e,
  GT            = 0x0f,
  LT            = 0x10,
  ANDREF        = 0x11,
  PLUSEQ        = 0x12,  // +=
  MINEQ         = 0x13,  // -=
  NEQ           = 0x14,  // !=
  INT_WORD      = 0x15,
  FLOAT_WORD    = 0x16,
  CHAR_WORD     = 0x17,
  VOID_WORD     = 0x18,
  WHILE         = 0x19,
  IF            = 0x1a,
  ELSE          = 0x1b,
  RETURN        = 0x1c,
  IDENT         = 0x1d,
  INT           = 0x1e,   // integer literal
  FLOAT         = 0x1f,   // float literal
  CHAR          = 0x20,   // char literal
  STR           = 0x21,
  DIRECTIVE     = 0x22,
  END_OF_FILE   = 0x23,
};

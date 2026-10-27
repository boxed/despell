// Prints the tokens Mojo's own lexer (Mojo/lib/MojoParser/Lexer.cpp) makes of
// a file, one per line: kind, start and end byte offsets, and the
// indentation of a token that starts a line (-1 otherwise). Errors are
// printed as `error <offset> <message>`. Used to check despell's tokenizer.
#include "Mojo/MojoParser/Lexer.h"
#include "Mojo/MojoParser/MojoDiags.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/raw_ostream.h"

using namespace M::KGEN::LIT;

static const char *kindName(Token::Kind kind) {
  switch (kind) {
#define TOK_MARKER(NAME)                                                       \
  case Token::NAME:                                                            \
    return #NAME;
#define TOK_IDENTIFIER(NAME)                                                   \
  case Token::NAME:                                                            \
    return #NAME;
#define TOK_LITERAL(NAME)                                                      \
  case Token::NAME:                                                            \
    return #NAME;
#define TOK_PUNCTUATION(NAME, SPELLING)                                        \
  case Token::NAME:                                                            \
    return #NAME;
#define TOK_KEYWORD(SPELLING)                                                  \
  case Token::kw_##SPELLING:                                                   \
    return "keyword";
#include "Mojo/MojoParser/TokenKinds.def"
  }
  return "?";
}

int main(int argc, char **argv) {
  if (argc != 2) {
    llvm::errs() << "usage: dump <file.mojo>\n";
    return 2;
  }
  auto file = llvm::MemoryBuffer::getFile(argv[1]);
  if (!file) {
    llvm::errs() << "can't read " << argv[1] << "\n";
    return 2;
  }
  llvm::SourceMgr sourceMgr;
  const llvm::MemoryBuffer *buffer = file->get();
  sourceMgr.AddNewSourceBuffer(std::move(*file), llvm::SMLoc());
  MojoDiags diags(sourceMgr);
  Lexer lexer(diags, buffer);
  const char *base = buffer->getBufferStart();
  for (;;) {
    const Token &tok = lexer.getToken();
    if (tok.getKind() == Token::eof)
      break;
    StringRef s = tok.getSpelling();
    auto indent = tok.getIndentation();
    llvm::outs() << kindName(tok.getKind()) << ' ' << (s.data() - base) << ' '
                 << (s.data() - base + s.size()) << ' '
                 << (indent ? (long)*indent : -1L) << '\n';
    if (tok.getKind() == Token::error)
      break;
    lexer.lexToken();
  }
  for (auto &e : diags.errors)
    llvm::outs() << "error " << (e.first - base) << ' ' << e.second << '\n';
  return 0;
}

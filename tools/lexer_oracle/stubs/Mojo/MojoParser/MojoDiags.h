// Stand-in for Modular's MojoDiags: errors are counted and kept, so the
// oracle can report them along with the tokens.
#pragma once
#include "Support/LLVMForwardDecls.h"
#include "llvm/Support/SMLoc.h"
#include "llvm/Support/SourceMgr.h"
#include <string>
#include <vector>

namespace M::KGEN::LIT {

class MojoInflightDiag {
public:
  template <typename T> MojoInflightDiag &operator<<(T &&) & { return *this; }
  template <typename T> MojoInflightDiag operator<<(T &&) && { return *this; }
  MojoInflightDiag &attachNote(llvm::SMLoc) & { return *this; }
};

struct MojoDiags {
  explicit MojoDiags(llvm::SourceMgr &sourceMgr) : sourceMgr(sourceMgr) {}
  llvm::SourceMgr &sourceMgr;
  std::vector<std::pair<const char *, std::string>> errors;

  MojoInflightDiag emitError(llvm::SMLoc loc, const Twine &message) {
    errors.emplace_back(loc.getPointer(), message.str());
    return {};
  }
  std::string translateLocation(llvm::SMLoc) { return ""; }
};

} // namespace M::KGEN::LIT

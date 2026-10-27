// Stand-in for Modular's Support/LLVMForwardDecls.h: the LLVM names the
// lexer uses unqualified.
#pragma once
#include "llvm/ADT/APInt.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/ADT/Twine.h"
#include "llvm/Support/raw_ostream.h"

namespace M {
// std::visit with a lambda per alternative
template <class... Ts> struct Overloaded : Ts... {
  using Ts::operator()...;
};
template <class... Ts> Overloaded(Ts...) -> Overloaded<Ts...>;

using llvm::APInt;
using llvm::ArrayRef;
using llvm::raw_ostream;
using llvm::SmallVector;
using llvm::SmallVectorImpl;
using llvm::StringRef;
using llvm::Twine;
} // namespace M
namespace M::KGEN::LIT {
using namespace M;
}

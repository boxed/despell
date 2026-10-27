// Stand-ins for Modular's arbitrary precision numbers: the lexer only builds
// them for a float literal's value, which the oracle doesn't look at.
#pragma once

namespace M {
class IPInt {
public:
  IPInt(long = 0) {}
  IPInt operator*(const IPInt &) const { return {}; }
  IPInt operator+(const IPInt &) const { return {}; }
  IPInt exponentiate(const IPInt &) const { return {}; }
};
class IPRational {
public:
  IPRational() = default;
  IPRational(const IPInt &, const IPInt &) {}
};
} // namespace M

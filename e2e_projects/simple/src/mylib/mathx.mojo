"""Small math helpers."""


def add(a: Int, b: Int) -> Int:
    return a + b


def clamp(x: Int, lo: Int, hi: Int) -> Int:
    """Clamp x into [lo, hi]."""
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x


def is_even(n: Int) -> Bool:
    return n % 2 == 0


def table_size() -> Int:
    return 4 * 4


comptime TABLE = table_size()


def sum_to(n: Int) -> Int:
    var total = 0
    for i in range(n):
        total += i
    return total


def scale[T: Intable](x: T, factor: Int) -> Int:
    return Int(x) * factor


def greeting(name: String) -> String:
    return "Hello, " + name


struct Counter(Copyable):
    var count: Int
    var step: Int

    def __init__(out self, step: Int):
        self.count = 0
        self.step = step

    def tick(mut self):
        self.count += self.step

    def is_done(self, limit: Int) -> Bool:
        return self.count >= limit and not self.count < 0


def countdown(n: Int) -> Int:
    var i = n
    var steps = 0
    while i > 0:
        i -= 1
        steps += 1
    return steps


def untested(x: Int) -> Int:
    return x * 7

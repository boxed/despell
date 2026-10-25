from std.collections import Dict


trait Shape:
    def area(self) -> Int:
        ...

    def describe(self) -> String:
        return "shape with area " + String(self.area())


@fieldwise_init
struct Rect(Shape, Copyable, Movable):
    var w: Int
    var h: Int

    def area(self) -> Int:
        return self.w * self.h

    @staticmethod
    def square(side: Int) -> Rect:
        return Rect(side, side)

    def __eq__(self, other: Rect) -> Bool:
        return self.w == other.w and self.h == other.h


def banner(title: String) -> String:
    var text = """
    ==
    title
    =="""
    return text.replace("title", title)


def apply_twice[f: def(Int) capturing -> Int](x: Int) -> Int:
    return f(f(x))


def nested(x: Int) -> Int:
    @parameter
    def inc(y: Int) -> Int:
        return y + x

    return apply_twice[inc](1)


def take_list(var items: List[Int]) -> List[Int]:
    items.append(len(items) * 2)
    return items^


def count_words(text: String) raises -> Dict[String, Int]:
    var counts = Dict[String, Int]()
    for word in text.split(" "):
        if word == "":
            continue
        var w = String(word).lower()
        counts[w] = counts.get(w, 0) + 1
    return counts^


def first_big(values: List[Int], limit: Int) -> Int:
    for v in values:
        if v > limit:
            return v
    return -1


def bits(x: Int) -> Int:
    return (x << 2) | (x & 3) ^ (x >> 1)


def pick(flag: Bool, a: Int, b: Int) -> Int:
    return a if flag else b


def float_math(x: Float64) -> Float64:
    return x * 2.5 - 0.5


def comptime_branch[n: Int]() -> Int:
    comptime if n > 2:
        return n * 10
    else:
        return n


def safe_div(a: Int, b: Int) raises -> Int:
    if b == 0:
        raise Error("division by zero")
    return a // b


def ignored(x: Int) -> Int:  # pragma: no mutate
    return x + 1


def partly_ignored(x: Int) -> Int:
    var y = x * 3  # pragma: no mutate
    return y - 1

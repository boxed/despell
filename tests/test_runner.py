from despell.runner import absolutize_imports, add_exports


def test_absolutize_imports():
    text = "from .canvas import Canvas\nfrom ..util.x import y\nfrom . import geometry\nfrom std.os import getenv\n"
    assert absolutize_imports(text, ("pkg", "sub")) == (
        "from pkg.sub.canvas import Canvas\nfrom pkg.util.x import y\nfrom pkg.sub import geometry\nfrom std.os import getenv\n"
    )


def test_add_exports():
    text = (
        "def _despell_active(fid: Int) -> Int:\n"
        "    return 0\n"
        "\n"
        "def f() -> Int:\n"
        "    return 1\n"
        "\n"
        "struct S:\n"
        "    @always_inline\n"
        "    def m(self) -> Int:\n"
        "        return 2\n"
        "    def g(self):\n"
        "        pass\n"
    )
    exported = add_exports(text, skip={2})
    assert exported.text == (
        "def _despell_active(fid: Int) -> Int:\n"
        "    return 0\n"
        "\n"
        '@export("despell_x_0")\n'
        "def f() -> Int:\n"
        "    return 1\n"
        "\n"
        "struct S:\n"
        "    @always_inline\n"
        '    @export("despell_x_1")\n'
        "    def m(self) -> Int:\n"
        "        return 2\n"
        "    def g(self):\n"
        "        pass\n"
    )
    assert exported.by_line == {3: 0, 4: 0, 9: 1, 10: 1}
    assert [exported.original_line(n) for n in (2, 4, 10, 12)] == [2, 3, 8, 10]

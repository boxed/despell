from despell.runner import absolutize_imports


def test_absolutize_imports():
    text = "from .canvas import Canvas\nfrom ..util.x import y\nfrom . import geometry\nfrom std.os import getenv\n"
    assert absolutize_imports(text, ("pkg", "sub")) == (
        "from pkg.sub.canvas import Canvas\nfrom pkg.util.x import y\nfrom pkg.sub import geometry\nfrom std.os import getenv\n"
    )

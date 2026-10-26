"""The `despell` executable."""

from std.sys import exit

from despell.cli import main_cli


def main():
    exit(main_cli())

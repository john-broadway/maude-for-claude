"""python3 -m maude_shell: a command on stdin, its parse as one JSON object on stdout."""
import json
import sys

from . import parse

if __name__ == "__main__":
    # bytes that are not UTF-8 are replaced, not fatal: the answer must always be JSON
    sys.stdout.write(json.dumps(parse(sys.stdin.buffer.read().decode("utf-8", "replace"))) + "\n")

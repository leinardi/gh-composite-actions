#!/usr/bin/env python3
#
# MIT License
#
# Copyright (c) 2026 Roberto Leinardi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Checks that every external image a Dockerfile pulls is pinned by digest, and that every download
# in it is verified:
#
#   check_pinned_bases.py [--build-arg NAME=VALUE]... [--tag-only REPOSITORY]... DOCKERFILE...
#
# A tag can be moved to other content at any time; a digest cannot. So every image the build pulls
# from outside the file must be named as <image>@sha256:<64 hex>: the base of each FROM, the image
# of a COPY --from or a RUN --mount from=, and the BuildKit frontend of a "# syntax=" directive.
# "scratch" and the earlier stages of the same file (by name, case-insensitively, or by index) are
# not external and are skipped. A FROM that names an ARG is resolved the way BuildKit does: from
# the ARGs declared before the first FROM, their defaults overridden by --build-arg. An ARG that
# cannot be resolved that way (no default and no --build-arg, declared only inside a stage, or a
# platform ARG only the builder knows) is reported as an error at its line, never guessed. Platform
# flags (--platform=$BUILDPLATFORM) are not part of the image reference and are ignored.
#
# --tag-only exempts a registry or repository (dhi.io, or dhi.io/rust) from the digest: its images
# pass with an explicit tag other than latest, for bases rebuilt too often to follow by digest.
#
# The second check is a heuristic for downloads: a curl or wget command, or an ADD of a URL, must be
# verified in the same instruction. The RUN script (its line continuations and heredocs included)
# is split into simple commands with quotes, comments and command substitutions understood, so a
# downloader counts only where it runs: as the command itself, behind wrappers (sudo, env,
# timeout 60, nice, xargs, busybox, exec, command, ...) or a leading backslash, inside $( ), or in
# a script given to sh/bash -c or eval; `apt-get install curl` and `echo "curl"` are not downloads.
# Each download must be followed, later in the same RUN, by sha256sum or sha512sum in check mode
# (-c or --check, as in `echo "<hash>  <file>" | sha256sum --check --strict -`) or shasum
# -a 256/512 -c, run as a command (a mention in a string does not count) on a path whose failure
# fails the RUN: Docker's /bin/sh -c has no errexit, so the check must be chained with && to the
# end of the RUN, be its last command, be followed by `|| exit N`, or run under errexit (set -e
# earlier in the RUN, or a SHELL or sh -c with -e), as the Propagation class below spells out.
# sha512 is accepted because some publishers (the npm registry's
# integrity field) give no sha256, and it is the stronger hash. A signature or fingerprint check is
# not a checksum and does not count. A COPY or ADD heredoc is a file the build may run, so its body
# is checked the same way. An ADD source is expanded with the stage's ARGs first: a URL in an ARG
# needs --checksum=sha256: (or sha384:/sha512:) too, and a source that cannot be resolved is
# reported, since it may be one.
#
# Each finding is one "FILE:LINE: message" line on stdout (also a ::error annotation when run in
# GitHub Actions); a summary goes to stderr. Exit status: 0 when every file passes, 1 on any
# finding, 2 when a file cannot be read or parsed, or the arguments are wrong. Standard library
# only, so it runs on any runner with python3.

import argparse
import bisect
import json
import os
import re
import shlex
import sys

DIGEST_RE = re.compile(r"@sha256:[0-9a-f]{64}$")
ARG_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
DIRECTIVE_RE = re.compile(r"^#\s*([A-Za-z]+)\s*=\s*(.*?)\s*$")
KNOWN_DIRECTIVES = {"syntax", "escape", "check"}
FLAG_RE = re.compile(r"\s*(--[A-Za-z][A-Za-z0-9-]*(?:=\S*)?)(?=\s|$)")
HEREDOC_RE = re.compile(r"(?<!<)<<(?!<)(-?)\s*([\"']?)([A-Za-z_][A-Za-z0-9_]*)\2")
URL_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")
CHECKSUM_RE = re.compile(r"^--checksum=sha(256|384|512):[0-9a-f]+$")
# Platform ARGs BuildKit sets on its own; their value depends on the builder, not on the file.
PLATFORM_ARGS = {
    "BUILDPLATFORM", "BUILDOS", "BUILDARCH", "BUILDVARIANT",
    "TARGETPLATFORM", "TARGETOS", "TARGETARCH", "TARGETVARIANT",
}
DOWNLOADERS = {"curl", "wget"}



class ParseError(Exception):
    """The file cannot be parsed: nothing about it can be checked."""


class Unresolved:
    """An ARG value that is not known from the file and the build args, with the reason."""

    def __init__(self, reason):
        self.reason = reason


class Instruction:
    """One instruction: its keyword, its arguments, and where each character came from."""

    def __init__(self, keyword, text, rest_start, line_starts, line_numbers, heredocs):
        self.keyword = keyword
        self.text = text
        self.rest_start = rest_start
        # (start, end) offsets in text of each heredoc body.
        self.heredocs = heredocs
        self._line_starts = line_starts
        self._line_numbers = line_numbers

    @property
    def line(self):
        return self._line_numbers[0]

    @property
    def rest(self):
        return self.text[self.rest_start:]

    def line_at(self, offset):
        """The physical line number of the character at offset in text."""
        index = bisect.bisect_right(self._line_starts, offset) - 1
        return self._line_numbers[max(index, 0)]


def read_directives(lines):
    """The parser directives at the top of the file: {name: (value, line)}."""
    directives = {}
    for number, line in enumerate(lines, start=1):
        match = DIRECTIVE_RE.match(line)
        if not match or match.group(1).lower() not in KNOWN_DIRECTIVES:
            break
        name = match.group(1).lower()
        if name in directives:
            break
        directives[name] = (match.group(2), number)
    return directives


def is_comment_or_blank(line):
    stripped = line.strip()
    return not stripped or stripped.startswith("#")


def continues(line, escape):
    stripped = line.rstrip()
    return stripped.endswith(escape), stripped[:-1] if stripped.endswith(escape) else line


def instructions(lines, escape):
    """The file's instructions, with line continuations joined and heredoc bodies attached."""
    result = []
    index = 0
    count = len(lines)
    while index < count:
        if is_comment_or_blank(lines[index]):
            index += 1
            continue
        text = ""
        line_starts = []
        line_numbers = []
        while True:
            more, part = continues(lines[index], escape)
            line_starts.append(len(text))
            line_numbers.append(index + 1)
            text += part
            index += 1
            if not more:
                break
            # BuildKit drops comment and blank lines inside a continued instruction.
            while index < count and is_comment_or_blank(lines[index]):
                index += 1
            if index >= count:
                break
        stripped = text.lstrip()
        keyword = stripped.split(None, 1)[0].upper()
        rest_start = len(text) - len(stripped) + len(stripped.split(None, 1)[0])
        heredoc_keyword = keyword
        heredocs = []
        if keyword == "ONBUILD":
            inner = stripped.split(None, 2)
            heredoc_keyword = inner[1].upper() if len(inner) > 1 else ""
        if heredoc_keyword in {"RUN", "COPY", "ADD"}:
            for match in HEREDOC_RE.finditer(text):
                strip_tabs, delimiter = match.group(1) == "-", match.group(3)
                body_start = None
                while True:
                    if index >= count:
                        raise ParseError(
                            f"{line_numbers[0]}: the heredoc <<{delimiter} is never closed")
                    body = lines[index]
                    index += 1
                    if (body.lstrip("\t") if strip_tabs else body) == delimiter:
                        break
                    text += "\n"
                    line_starts.append(len(text))
                    line_numbers.append(index)
                    if body_start is None:
                        body_start = len(text)
                    text += body
                heredocs.append((len(text) if body_start is None else body_start, len(text)))
        result.append(Instruction(keyword, text, rest_start, line_starts, line_numbers, heredocs))
    return result


def lookup(name, env):
    """The value of ARG name in env: a string, None when unset, or Unresolved."""
    if name not in env:
        if name in PLATFORM_ARGS:
            return Unresolved(f"{name} is a platform ARG that only the builder knows")
        return Unresolved(f"{name} is not declared before the first FROM")
    return env[name]


def expand(text, env):
    """Expands $NAME, ${NAME} and ${NAME:-word}, ${NAME-word}, ${NAME:+word}, ${NAME+word}.

    Returns (value, reasons): reasons lists why a variable could not be resolved, and value is
    None when there is any.
    """
    reasons = []
    out = []
    position = 0
    pattern = re.compile(r"\\\$|\$(?:\{([^}]*)\}|([A-Za-z_][A-Za-z0-9_]*))")
    for match in pattern.finditer(text):
        out.append(text[position:match.start()])
        position = match.end()
        if match.group(0) == "\\$":
            out.append("$")
            continue
        if match.group(2) is not None:
            name, operator, word = match.group(2), None, ""
        else:
            braced = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-+])(.*))?", match.group(1),
                                  re.S)
            if not braced:
                reasons.append(f"{match.group(0)} is not a substitution this check understands")
                continue
            name, operator, word = braced.group(1), braced.group(2), braced.group(3) or ""
        value = lookup(name, env)
        if isinstance(value, Unresolved):
            if operator in (":-", "-") and name not in env and name not in PLATFORM_ARGS:
                value = None
            else:
                reasons.append(value.reason)
                continue
        if operator is None:
            if value is None:
                reasons.append(
                    f"ARG {name} has no default before the first FROM and no build arg sets it")
                continue
            out.append(value)
            continue
        is_set = value is not None
        is_full = bool(value)
        use_word = {
            ":-": not is_full,
            "-": not is_set,
            ":+": is_full,
            "+": is_set,
        }[operator]
        if operator in (":-", "-"):
            if not use_word:
                out.append(value)
                continue
        elif not use_word:
            continue
        expanded, inner = expand(word, env)
        reasons.extend(inner)
        if expanded is not None:
            out.append(expanded)
    out.append(text[position:])
    if reasons:
        return None, reasons
    return "".join(out), []


def split_words(text):
    try:
        return shlex.split(text, comments=False, posix=True)
    except ValueError as error:
        raise ValueError(f"cannot split its arguments ({error})") from None


def leading_flags(rest):
    """The --flags at the start of an instruction's arguments, and the offset after them."""
    flags = []
    position = 0
    while True:
        match = FLAG_RE.match(rest, position)
        if not match:
            return flags, position
        flags.append(match.group(1))
        position = match.end()


def strip_quotes(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


class Word:
    """One shell word: its value with the quoting removed, and where it starts in the script."""

    def __init__(self, start):
        self.start = start
        self.parts = []
        self.quoted = False

    @property
    def value(self):
        return "".join(self.parts)


def closing(script, index, opener, closer):
    """The offset of the closer that matches the opener just before index, skipping quotes."""
    depth = 1
    quote = None
    length = len(script)
    while index < length:
        char = script[index]
        if char == "\\" and quote != "'":
            index += 2
            continue
        if quote:
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return length


def lex(script):
    """Splits a shell script into words and operators, and finds its command substitutions.

    A heuristic, not a shell parser: it knows quotes, backslashes, comments, $( ), ` `, ${ } and
    the list and pipeline operators, which is enough to tell `curl -o x URL` (a command) from
    `apt-get install curl` (an argument) or `echo "curl"` (a string). Returns (items, nested):
    items are Word objects and operator strings paired with their offset, nested the (start, end)
    of each command substitution's body.
    """
    items = []
    nested = []
    word = None
    index = 0
    length = len(script)

    def flush():
        nonlocal word
        if word is not None:
            items.append((word.start, word))
            word = None

    while index < length:
        char = script[index]
        if word is None:
            if char in " \t\r":
                index += 1
                continue
            if char == "#":
                newline = script.find("\n", index)
                index = length if newline < 0 else newline
                continue
            if script.startswith("\\\n", index):
                index += 2
                continue
            if script.startswith(("&&", "||", ";;"), index):
                items.append((index, script[index:index + 2]))
                index += 2
                continue
            if char in "\n;&|()":
                items.append((index, char))
                index += 1
                continue
            if char in "{}" and (index + 1 == length or script[index + 1] in " \t\r\n;"):
                items.append((index, char))
                index += 1
                continue
            word = Word(index)
        if char in " \t\r\n;&|()":
            flush()
            continue
        if char == "\\":
            if script.startswith("\\\n", index):
                index += 2
                continue
            word.parts.append(script[index + 1:index + 2])
            word.quoted = True
            index += 2
            continue
        if char == "'":
            end = script.find("'", index + 1)
            end = length if end < 0 else end
            word.parts.append(script[index + 1:end])
            word.quoted = True
            index = end + 1
            continue
        if char == '"':
            word.quoted = True
            index += 1
            while index < length and script[index] != '"':
                if script[index] == "\\" and index + 1 < length:
                    following = script[index + 1]
                    word.parts.append(following if following in '$`"\\' else "\\" + following)
                    index += 2
                elif script.startswith("$(", index):
                    end = closing(script, index + 2, "(", ")")
                    nested.append((index + 2, end))
                    word.parts.append(script[index:end + 1])
                    index = end + 1
                elif script[index] == "`":
                    end = script.find("`", index + 1)
                    end = length if end < 0 else end
                    nested.append((index + 1, end))
                    word.parts.append(script[index:end + 1])
                    index = end + 1
                else:
                    word.parts.append(script[index])
                    index += 1
            index += 1
            continue
        if script.startswith("$(", index):
            end = closing(script, index + 2, "(", ")")
            nested.append((index + 2, end))
            word.parts.append(script[index:end + 1])
            index = end + 1
            continue
        if script.startswith("${", index):
            end = closing(script, index + 2, "{", "}")
            word.parts.append(script[index:end + 1])
            index = end + 1
            continue
        if char == "`":
            end = script.find("`", index + 1)
            end = length if end < 0 else end
            nested.append((index + 1, end))
            word.parts.append(script[index:end + 1])
            index = end + 1
            continue
        word.parts.append(char)
        index += 1
    flush()
    return items, nested


def simple_commands(items):
    """The simple commands of lexed items: [(words, operator after them)]."""
    commands = []
    words = []
    for _, item in items:
        if isinstance(item, Word):
            words.append(item)
            continue
        commands.append((words, item))
        words = []
    commands.append((words, None))
    return [command for command in commands if command[0]]


def command_name(word):
    return os.path.basename(word.value).lower().removesuffix(".exe")


# Words that stand before the command they run. Each maps to the options that take a separate
# argument; timeout also takes a duration before the command.
WRAPPERS = {
    "sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U"},
    "doas": {"-u", "-C"},
    "exec": {"-a"},
    "command": set(),
    "builtin": set(),
    "time": {"-f", "-o"},
    "nice": {"-n"},
    "ionice": {"-c", "-n", "-p"},
    "nohup": set(),
    "setsid": set(),
    "stdbuf": {"-i", "-o", "-e"},
    "env": {"-u", "-C", "-S"},
    "timeout": {"-s", "-k"},
    "xargs": {"-I", "-n", "-P", "-L", "-d", "-a", "-E", "-s"},
    "busybox": set(),
    "chronic": set(),
    "unbuffer": set(),
}
KEYWORDS = {"!", "then", "do", "else", "elif", "if", "while", "until", "{", "}"}
SHELLS = {"sh", "bash", "ash", "dash", "zsh", "ksh", "mksh"}
CHECKSUM_TOOLS = {"sha256sum", "sha512sum", "shasum"}
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def effective_command(words):
    """The index of the word that is the command a simple command runs, past assignments and
    wrappers (sudo, env, timeout 60, xargs -n1, busybox, ...); None when there is none."""
    index = 0
    count = len(words)
    while index < count:
        word = words[index]
        name = command_name(word)
        if ASSIGNMENT_RE.match(word.value) or word.value in KEYWORDS:
            index += 1
            continue
        if name not in WRAPPERS:
            return index
        index += 1
        while index < count and words[index].value.startswith("-") and words[index].value != "-":
            option = words[index].value
            index += 1
            if option == "--":
                break
            if option in WRAPPERS[name] and index < count:
                index += 1
        if name == "timeout" and index < count:
            index += 1
    return None


def is_check_mode(tool, arguments):
    values = [word.value for word in arguments]
    if tool == "shasum":
        joined = " ".join(values)
        if not re.search(r"(?:^|\s)(?:-a\s*|--algorithm[=\s])(256|512)(?:\s|$)", joined):
            return False
    for value in values:
        if value == "--check" or value.startswith("--check="):
            return True
        if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", value) and not value.startswith("--"):
            return True
    return False


def shell_events(script, key=(), line_offset=None):
    """The downloads and checksum verifications a shell script runs, in order.

    Each event is (order key, offset of its line in script, kind, name), kind being "download" or
    "verify". A script passed to sh -c or eval is followed, its events placed at that word.
    """
    events = []
    items, nested = lex(script)
    commands = simple_commands(items)
    for number, (words, _) in enumerate(commands):
        events.extend(command_events(words, commands, number, key, line_offset))
    for start, end in nested:
        for event_key, offset, kind, name in shell_events(script[start:end]):
            shifted = (start + event_key[0],) + event_key[1:]
            events.append((key + shifted, start + offset if line_offset is None else line_offset,
                           kind, name))
    return sorted(events, key=lambda event: event[0])


def command_events(words, commands, number, key, line_offset):
    index = effective_command(words)
    if index is None:
        return []
    word = words[index]
    name = command_name(word)
    here = key + (word.start,)
    line = word.start if line_offset is None else line_offset
    arguments = words[index + 1:]
    if name in DOWNLOADERS:
        return [(here, line, "download", name)]
    if name in CHECKSUM_TOOLS:
        if is_check_mode(name, arguments):
            return [(here, line, "verify", name)]
        return []
    if name == "eval" and arguments:
        script = " ".join(argument.value for argument in arguments)
        return shell_events(script, here, line)
    if name in SHELLS:
        script_index, _, _ = shell_options([argument.value for argument in arguments])
        if script_index is not None:
            argument = arguments[script_index]
            return shell_events(argument.value, here + (argument.start,),
                                argument.start if line_offset is None else line_offset)
    return []


def shell_options(values, errexit=False, pipefail=False):
    """Reads shell (or set) options: (index of the -c command string or None, errexit, pipefail),
    starting from the given errexit and pipefail state."""
    command_string = False
    position = 0
    while position < len(values):
        value = values[position]
        position += 1
        match = re.fullmatch(r"([-+])([A-Za-z]+)", value)
        if not match:
            return (position - 1 if command_string else None), errexit, pipefail
        on = match.group(1) == "-"
        if "e" in match.group(2):
            errexit = on
        if "c" in match.group(2) and on:
            command_string = True
        if match.group(2).endswith("o") and position < len(values):
            # -o (or a cluster ending in o, as -euo) takes the option name as its argument.
            option = values[position]
            position += 1
            if option == "errexit":
                errexit = on
            elif option == "pipefail":
                pipefail = on
    return None, errexit, pipefail


# --- Whether a verification's failure fails the instruction ---------------------------------
#
# Docker runs a shell-form RUN as `/bin/sh -c` (or the stage's SHELL), with no errexit: in
# `curl ...; sha256sum --check ...; echo done` a mismatch is ignored and the RUN succeeds. So a
# checksum verification only counts when it runs on the executed path and its failure reaches the
# instruction's exit status: every separator after it is && (its failure is then the RUN's status),
# or errexit is active (set -e earlier in the same list, or a SHELL or sh -c with -e) and it ends
# its && / || list, or it is followed by `|| exit N` with N non-zero. It must not be negated,
# backgrounded, after a || in its list, or a non-final pipeline element (unless pipefail is on).
# Inside ( ) and { } groups and sh -c scripts the same rule applies within, and the group or
# command must then itself be propagated. A function's verifications count only when every call
# of it is a propagated command of the instruction's top-level list. Anything else (if, while,
# for, case, $( ), a verification only reached by a construct this does not model) does not count:
# when unsure, the download is reported.

COMPOUND_OPENERS = {"if", "while", "until", "for", "case", "select"}
COMPOUND_CLOSERS = {"fi", "done", "esac"}
LIST_SEPARATORS = {";", "\n", "&", "&&", "||", ";;"}
COMMAND_POSITION_WORDS = {"then", "do", "else", "elif", "if", "while", "until", "!"}


class Command:
    """One command of a pipeline: simple, a ( ) or { } group, a function definition, or other."""

    def __init__(self, kind, words=None, start=0, end=0, opener=None, name=None, body=None):
        self.kind = kind
        self.words = words or []
        self.start = start
        self.end = end
        self.opener = opener
        self.name = name
        self.body = body


class Pipeline:
    def __init__(self, commands, negated):
        self.commands = commands
        self.negated = negated
        self.separator = None


def is_operator(token, *values):
    return isinstance(token, str) and (not values or token in values)


def is_keyword(token, values):
    return isinstance(token, Word) and not token.quoted and token.value in values


def matching_operator(tokens, index, end, opener, closer):
    depth = 0
    for position in range(index, end):
        token = tokens[position][1]
        if is_operator(token, opener):
            depth += 1
        elif is_operator(token, closer):
            depth -= 1
            if depth == 0:
                return position
    return None


def matching_keyword(tokens, index, end):
    depth = 0
    for position in range(index, end):
        token = tokens[position][1]
        if not isinstance(token, Word) or token.quoted:
            continue
        previous = tokens[position - 1][1] if position > index else None
        if not (position == index or isinstance(previous, str)
                or is_keyword(previous, COMMAND_POSITION_WORDS)):
            continue
        if token.value in COMPOUND_OPENERS:
            depth += 1
        elif token.value in COMPOUND_CLOSERS:
            depth -= 1
            if depth == 0:
                return position + 1
    return end


def parse_list(tokens, index, end):
    pipelines = []
    while index < end:
        if is_operator(tokens[index][1], ";", "\n", "&", ";;"):
            index += 1
            continue
        pipeline, index = parse_pipeline(tokens, index, end)
        if index < end and is_operator(tokens[index][1]) and tokens[index][1] in LIST_SEPARATORS:
            pipeline.separator = tokens[index][1]
            index += 1
        pipelines.append(pipeline)
    return pipelines


def parse_pipeline(tokens, index, end):
    negated = False
    if is_keyword(tokens[index][1], {"!"}):
        negated = True
        index += 1
    commands = []
    while index < end:
        command, index = parse_command(tokens, index, end)
        commands.append(command)
        if index < end and is_operator(tokens[index][1], "|"):
            index += 1
            while index < end and is_operator(tokens[index][1], "\n"):
                index += 1
            continue
        break
    return Pipeline(commands, negated), index


def parse_command(tokens, index, end):
    if index >= end:
        return Command("other"), index
    token = tokens[index][1]
    if is_operator(token, "(", "{"):
        closer = ")" if token == "(" else "}"
        close = matching_operator(tokens, index, end, token, closer)
        if close is None:
            return Command("other"), end
        command = Command("group", start=index + 1, end=close, opener=token)
        index = close + 1
    elif is_keyword(token, COMPOUND_OPENERS):
        close = matching_keyword(tokens, index, end)
        command = Command("other", start=index, end=close)
        index = close
    elif (is_keyword(token, {"function"}) and index + 1 < end
          and isinstance(tokens[index + 1][1], Word)):
        name = tokens[index + 1][1].value
        index += 2
        if (index + 1 < end and is_operator(tokens[index][1], "(")
                and is_operator(tokens[index + 1][1], ")")):
            index += 2
        command, index = function_body(tokens, index, end, name)
    elif (isinstance(token, Word) and index + 2 < end and is_operator(tokens[index + 1][1], "(")
          and is_operator(tokens[index + 2][1], ")")):
        command, index = function_body(tokens, index + 3, end, token.value)
    elif isinstance(token, str):
        return Command("other"), index + 1
    else:
        words = []
        while index < end and isinstance(tokens[index][1], Word):
            words.append(tokens[index][1])
            index += 1
        return Command("simple", words=words), index
    # Redirections after a compound command.
    while index < end and isinstance(tokens[index][1], Word):
        index += 1
    return command, index


def function_body(tokens, index, end, name):
    while index < end and is_operator(tokens[index][1], "\n"):
        index += 1
    body, index = parse_command(tokens, index, end)
    return Command("function", name=name, body=body), index


def option_effect(words, index, state):
    """(errexit, pipefail) after the simple command whose command word is words[index], from
    state. `set` changes them (only options: `set --` starts the positional arguments); a `set`
    behind a wrapper, `.`/`source`, `eval` and `shopt -o` may change them in ways not read here,
    so they make both unknown. Anything else, `bash -c 'set -e'` included, leaves them alone."""
    name = command_name(words[index])
    arguments = [word.value for word in words[index + 1:]]
    if name == "set":
        if index != 0:
            return None, None
        _, errexit, pipefail = shell_options(arguments, *state)
        return errexit, pipefail
    if name in {".", "source"} or (name == "eval" and arguments):
        return None, None
    if name == "shopt" and any(argument.startswith("-") and "o" in argument
                               for argument in arguments):
        return None, None
    return state


class Propagation:
    """Walks one script's command lists and collects the verifications that fail it on failure."""

    def __init__(self, script, tokens):
        self.script = script
        self.tokens = tokens
        self.functions = {}
        self.calls = {}

    def evaluate(self, start, end, errexit, pipefail, key, top, ignored=False):
        """(status, exits, errexit, pipefail) of the list in tokens[start:end]: the verification
        keys whose failure makes the list's status non-zero, those whose failure exits the shell,
        and the shell options after it.

        errexit and pipefail are True, False or None (unknown). They change only through a command
        certain to run in this shell: the first of its and-or list (nothing before it can skip
        it), not negated, backgrounded or in a pipeline (a subshell). A `set`, a `{ }` group or
        a construct that may change them anywhere else makes them unknown, and with errexit
        unknown no verification counts through errexit. ignored is true where bash ignores -e
        (inside a command that is negated or not the last of an && / || list).
        """
        pipelines = parse_list(self.tokens, start, end)
        status, exits = set(), set()
        for number, pipeline in enumerate(pipelines):
            separator = pipeline.separator
            first = self.first_in_list(pipelines, number)
            clean = not pipeline.negated and separator != "&" and self.no_or_before(pipelines,
                                                                                    number)
            to_end = all(other.separator == "&&" for other in pipelines[number:-1])
            backgrounded = pipelines[-1].separator == "&"
            status_propagated = clean and to_end and not backgrounded
            exit_propagated = clean and (
                (errexit is True and not ignored and separator not in ("&&", "||"))
                or self.or_exit(pipelines, number))
            inner_ignored = ignored or pipeline.negated or separator in ("&&", "||")
            last = len(pipeline.commands) - 1
            in_pipeline = last > 0
            for position, command in enumerate(pipeline.commands):
                reaches = position == last or pipefail is True
                propagated = reaches and (status_propagated or exit_propagated)
                command_status, command_exits, after = self.command(
                    command, errexit, pipefail, key, top and not in_pipeline,
                    propagated, in_pipeline, inner_ignored)
                if in_pipeline:
                    command_status |= command_exits
                    command_exits = set()
                exits |= command_exits
                if reaches:
                    if status_propagated:
                        status |= command_status
                    if exit_propagated:
                        exits |= command_status
                if in_pipeline or separator == "&" or after == (errexit, pipefail):
                    continue  # A subshell's options do not reach this shell.
                if first and not pipeline.negated:
                    errexit, pipefail = after
                else:
                    errexit = errexit if after[0] == errexit else None
                    pipefail = pipefail if after[1] == pipefail else None
        return status, exits, errexit, pipefail

    @staticmethod
    def first_in_list(pipelines, number):
        """Whether nothing before the pipeline in its && / || list can skip it."""
        return number == 0 or pipelines[number - 1].separator not in ("&&", "||")

    def touches_options(self, start, end):
        """Whether any command in tokens[start:end] may change errexit or pipefail."""
        for words, _ in simple_commands(self.tokens[start:end]):
            index = effective_command(words)
            if index is not None and option_effect(words, index, (False, False)) != (
                    False, False):
                return True
            if index is not None and option_effect(words, index, (True, True)) != (True, True):
                return True
        return False

    @staticmethod
    def no_or_before(pipelines, number):
        position = number - 1
        while position >= 0 and pipelines[position].separator in ("&&", "||"):
            if pipelines[position].separator == "||":
                return False
            position -= 1
        return True

    @staticmethod
    def or_exit(pipelines, number):
        """Whether the pipeline is followed by `|| exit N`, N non-zero."""
        if pipelines[number].separator != "||" or number + 1 >= len(pipelines):
            return False
        following = pipelines[number + 1]
        if following.negated or len(following.commands) != 1:
            return False
        words = following.commands[0].words
        return (following.commands[0].kind == "simple" and len(words) >= 2
                and words[0].value == "exit" and words[1].value.isdigit()
                and int(words[1].value) != 0)

    def command(self, command, errexit, pipefail, key, top, propagated, in_pipeline, ignored):
        """(status, exits, (errexit, pipefail) after it) of one command."""
        state = (errexit, pipefail)
        if command.kind == "group":
            status, exits, *after = self.evaluate(command.start, command.end, errexit, pipefail,
                                                  key, False, ignored)
            if command.opener == "(":
                return status | exits, set(), state
            return status, exits, tuple(after)
        if command.kind == "function":
            if top and command.body is not None and command.body.kind == "group":
                self.functions[command.name] = command.body
            return set(), set(), state
        if command.kind != "simple":
            if command.end > command.start and self.touches_options(command.start, command.end):
                return set(), set(), (None, None)
            return set(), set(), state
        words = command.words
        index = effective_command(words)
        if index is None:
            return set(), set(), state
        word = words[index]
        name = command_name(word)
        arguments = words[index + 1:]
        here = key + (word.start,)
        if name in CHECKSUM_TOOLS and is_check_mode(name, arguments):
            return {here}, set(), state
        if word.value in self.functions and index == 0:
            # The verification runs where the function is called, so it counts at the call.
            body = self.functions[word.value]
            status, exits, _, _ = self.evaluate(body.start, body.end, errexit, pipefail, key,
                                                False, ignored)
            effective = bool(exits and not in_pipeline) or bool(propagated and (status or exits))
            self.calls.setdefault(word.value, []).append((here, top and effective))
            after = (None, None) if self.touches_options(body.start, body.end) else state
            return set(), set(), after
        effect = option_effect(words, index, state)
        if name == "eval" and arguments:
            inner = " ".join(argument.value for argument in arguments)
            return propagated_verifications(inner, errexit is True and not ignored,
                                            pipefail is True, here), set(), effect
        if name in SHELLS:
            # A child shell: its options die with it.
            values = [argument.value for argument in arguments]
            script_index, inner_errexit, inner_pipefail = shell_options(values)
            if script_index is not None:
                argument = arguments[script_index]
                return propagated_verifications(argument.value, inner_errexit, inner_pipefail,
                                                here + (argument.start,)), set(), state
        return set(), set(), effect

    def function_keys(self, items):
        """The call keys of the functions whose every call is a propagated top-level command
        that runs a propagated verification."""
        counts = {}
        for words, operator in simple_commands(items):
            index = effective_command(words)
            if index is None or operator == "(" and len(words) == 1:
                continue
            counts[words[index].value] = counts.get(words[index].value, 0) + 1
        keys = set()
        for name, results in self.calls.items():
            if len(results) == counts.get(name, 0) and all(ok for _, ok in results):
                keys |= {call for call, _ in results}
        return keys


def propagated_verifications(script, errexit=False, pipefail=False, key=()):
    """The keys of the verifications in a script whose failure fails the script."""
    items, _ = lex(script)
    propagation = Propagation(script, items)
    status, exits, _, _ = propagation.evaluate(0, len(items), errexit, pipefail, key, True)
    return status | exits | propagation.function_keys(items)


def function_calls(script):
    """The keys of every top-level call of a function the script defines: where its body's
    verifications run, effective or not."""
    items, _ = lex(script)
    propagation = Propagation(script, items)
    propagation.evaluate(0, len(items), False, False, (), True)
    return [call for results in propagation.calls.values() for call, _ in results]


def unverified_downloads(script, errexit=False, pipefail=False):
    """(offset, command, reason) of each download in a script that no effective checksum
    verification follows; reason is "none" or "ineffective" (a check follows, but its failure
    would not fail the script)."""
    events = shell_events(script)
    mentioned = [event[0] for event in events if event[2] == "verify"] + function_calls(script)
    effective = propagated_verifications(script, errexit, pipefail)
    found = []
    for event_key, offset, kind, name in events:
        if kind != "download" or any(check > event_key for check in effective):
            continue
        reason = "ineffective" if any(check > event_key for check in mentioned) else "none"
        found.append((offset, name, reason))
    return found


class Checker:
    """Checks one Dockerfile; collects (line, message) findings."""

    def __init__(self, build_args, tag_only=()):
        self.build_args = build_args
        self.tag_only = tuple(tag_only)
        self.findings = []

    def report(self, line, message):
        self.findings.append((line, message))

    def check_file(self, lines):
        directives = read_directives(lines)
        escape = "\\"
        if "escape" in directives:
            escape, line = directives["escape"]
            if escape not in ("\\", "`"):
                raise ParseError(f"{line}: the escape directive must be \\ or `, got {escape!r}")
        if "syntax" in directives:
            frontend, line = directives["syntax"]
            if not DIGEST_RE.search(frontend):
                self.report(line, f"# syntax={frontend} is not pinned by digest: use "
                                  f"{frontend}@sha256:<digest>")

        global_args = {}
        stage_args = {}
        stages = []
        # (errexit, pipefail) of each stage's RUN shell: /bin/sh -c until a SHELL changes it. A
        # stage built FROM an earlier stage inherits that stage's SHELL, as its image config does;
        # one FROM an external image is assumed to run /bin/sh -c.
        shells = []
        for instruction in instructions(lines, escape):
            keyword = instruction.keyword
            rest = instruction.rest
            rest_offset = instruction.rest_start
            shell = shells[-1] if shells else (False, False)
            if keyword == "ONBUILD":
                # Runs in a later build, whose SHELL is unknown here.
                shell = (False, False)
                inner = rest.lstrip()
                parts = inner.split(None, 1)
                if not parts:
                    continue
                keyword = parts[0].upper()
                rest_offset += len(rest) - len(inner) + len(parts[0])
                rest = instruction.text[rest_offset:]
            if keyword == "ARG":
                self.declare(instruction, rest, global_args if not stages else stage_args,
                             global_args, in_stage=bool(stages))
            elif keyword == "FROM":
                resolved = self.check_from(instruction, rest, global_args, stages)
                stage_args = {}
                inherited = (False, False)
                for number, name in enumerate(stages[:-1]):
                    if resolved and name == resolved.lower():
                        inherited = shells[number]
                shells.append(inherited)
            elif keyword == "SHELL" and instruction.keyword != "ONBUILD" and shells:
                shells[-1] = self.parse_shell(instruction, rest)
            elif keyword == "COPY":
                self.check_copy(instruction, rest, stages, stage_args, global_args)
                self.check_heredocs(instruction, "COPY")
            elif keyword == "RUN":
                self.check_run(instruction, rest, rest_offset, stages, stage_args, global_args,
                               shell)
            elif keyword == "ADD":
                self.check_add(instruction, rest, stage_args)

    def declare(self, instruction, rest, env, global_args, in_stage):
        try:
            words = split_words(rest)
        except ValueError as error:
            raise ParseError(f"{instruction.line}: ARG {error}") from None
        for word in words:
            name, has_default, default = word.partition("=")
            if not ARG_NAME_RE.match(name):
                raise ParseError(f"{instruction.line}: ARG {word!r} is not a valid declaration")
            if name in self.build_args:
                env[name] = self.build_args[name]
            elif has_default:
                # A default can use the ARGs declared before it: the global ones in a stage too,
                # once the stage redeclares them.
                scope = dict(global_args)
                scope.update(env)
                value, reasons = expand(default, scope)
                env[name] = (Unresolved(f"the default of ARG {name}: " + "; ".join(reasons))
                             if reasons else value)
            elif in_stage and name in global_args:
                env[name] = global_args[name]
            else:
                env[name] = None

    def check_from(self, instruction, rest, global_args, stages):
        # The flags (--platform) select a platform, not the image: only the operands matter.
        operands = [word for word in rest.split() if not word.startswith("--")]
        if len(operands) == 3 and operands[1].lower() == "as":
            image, name = operands[0], operands[2].lower()
        elif len(operands) == 1:
            image, name = operands[0], None
        else:
            raise ParseError(f"{instruction.line}: FROM {rest.strip()!r} is not "
                             "FROM [--flags] <image> [AS <name>]")
        resolved, reasons = expand(image, global_args)
        if reasons:
            for reason in reasons:
                self.report(instruction.line, f"FROM {image}: cannot resolve the image: {reason}")
        else:
            self.check_image(instruction.line, f"FROM {image}", image, resolved, stages,
                             allow_scratch=True)
        stages.append(name)
        return resolved

    @staticmethod
    def parse_shell(instruction, rest):
        """(errexit, pipefail) of a SHELL instruction's shell; neither for a shell it cannot
        read."""
        try:
            argv = json.loads(rest.strip())
        except ValueError:
            raise ParseError(f"{instruction.line}: SHELL must be a JSON array") from None
        if (not isinstance(argv, list) or not argv
                or not all(isinstance(arg, str) for arg in argv)):
            raise ParseError(f"{instruction.line}: SHELL must be a JSON array of strings")
        if os.path.basename(argv[0]) not in SHELLS:
            return False, False
        _, errexit, pipefail = shell_options(argv[1:])
        return errexit, pipefail

    def check_image(self, line, what, written, resolved, stages, allow_scratch=False):
        shown = what if written == resolved else f"{what} (= {resolved})"
        if not resolved:
            self.report(line, f"{shown} resolves to an empty image reference")
            return
        lowered = resolved.lower()
        if allow_scratch and lowered == "scratch":
            return
        if lowered in (name for name in stages if name):
            return
        if "@" in resolved and not DIGEST_RE.search(resolved):
            self.report(line, f"{shown} has a malformed digest: want @sha256: and 64 lowercase "
                              "hex digits")
        elif "@" not in resolved and is_tag_only(resolved, self.tag_only):
            repository, tag = split_reference(resolved)
            if not tag or tag == "latest":
                self.report(line, f"{shown} may be pinned by tag only ({repository} is in "
                                  "tag-only-images), but needs an explicit tag other than latest")
        elif not DIGEST_RE.search(resolved):
            where = ("" if written == resolved
                     else " where its value comes from (the ARG default or the build arg)")
            self.report(line, f"{shown} is an external image that is not pinned by digest: pin it"
                              f"{where} as {resolved}@sha256:<digest>")

    def check_source(self, line, what, value, stages, stage_args, global_args):
        """A --from of COPY or RUN --mount: an earlier stage, by name or index, or an image."""
        scope = dict(global_args)
        scope.update(stage_args)
        resolved, reasons = expand(value, scope)
        if reasons:
            for reason in reasons:
                self.report(line, f"{what}: cannot resolve the source: {reason}")
            return
        earlier = stages[:-1]
        if resolved.isdigit():
            if int(resolved) >= len(earlier):
                self.report(line, f"{what} refers to stage {resolved}, which is not an earlier "
                                  "stage")
            return
        self.check_image(line, what, value, resolved, earlier)

    def check_copy(self, instruction, rest, stages, stage_args, global_args):
        flags, _ = leading_flags(rest)
        for flag in flags:
            if flag.startswith("--from="):
                value = strip_quotes(flag[len("--from="):])
                self.check_source(instruction.line, f"COPY --from={value}", value, stages,
                                  stage_args, global_args)

    def check_run(self, instruction, rest, rest_offset, stages, stage_args, global_args, shell):
        flags, after = leading_flags(rest)
        for flag in flags:
            if not flag.startswith("--mount="):
                continue
            for option in strip_quotes(flag[len("--mount="):]).split(","):
                key, _, value = strip_quotes(option).partition("=")
                if key.lower() == "from":
                    self.check_source(instruction.line, f"RUN --mount=...from={value}", value,
                                      stages, stage_args, global_args)
        command_offset = rest_offset + after
        command = instruction.text[command_offset:]
        stripped = command.strip()
        if stripped.startswith("["):
            try:
                argv = json.loads(stripped)
            except ValueError:
                argv = None
            if isinstance(argv, list) and argv and all(isinstance(arg, str) for arg in argv):
                # The exec form: each element is one word, unquoted already, so it is quoted for
                # the shell analysis and the line is the instruction's.
                script = " ".join(shlex.quote(arg) for arg in argv)
                for _, name, _ in unverified_downloads(script):
                    self.report(instruction.line,
                                f"RUN [...] runs {name} with no checksum verification after it "
                                "(the exec form cannot verify it: use a shell RUN with "
                                "sha256sum --check)")
                return
        self.check_script(instruction, command, command_offset, "a RUN", shell)

    def check_script(self, instruction, script, offset, where, shell=(False, False)):
        for position, command, reason in unverified_downloads(script, *shell):
            line = instruction.line_at(offset + position)
            if reason == "ineffective":
                self.report(line, f"{command} downloads in {where} whose checksum verification "
                                  "is not on a path whose failure fails the instruction: chain "
                                  "it with && to the end, or run it under set -e")
            else:
                self.report(line, f"{command} downloads in {where} with no checksum verification "
                                  "after it: add `sha256sum --check` of the file after the "
                                  "download, in the same instruction")

    def check_heredocs(self, instruction, keyword):
        """A COPY or ADD heredoc becomes a file the build may run: it is checked as a script."""
        for start, end in instruction.heredocs:
            self.check_script(instruction, instruction.text[start:end], start,
                              f"a {keyword} heredoc")

    def check_add(self, instruction, rest, stage_args):
        self.check_heredocs(instruction, "ADD")
        # In a stage, only the ARGs the stage declares are set, as in the build.
        flags, after = leading_flags(rest)
        for flag in flags:
            if flag.startswith("--checksum="):
                value, reasons = expand(strip_quotes(flag), stage_args)
                if not reasons and CHECKSUM_RE.match(value):
                    return
        operands = rest[after:].strip()
        sources = None
        if operands.startswith("["):
            try:
                parsed = json.loads(operands)
                if isinstance(parsed, list):
                    sources = [source for source in parsed[:-1] if isinstance(source, str)]
            except ValueError:
                sources = None
        if sources is None:
            try:
                sources = split_words(operands)[:-1]
            except ValueError as error:
                raise ParseError(f"{instruction.line}: ADD {error}") from None
        for source in sources:
            resolved, reasons = expand(source, stage_args)
            if reasons:
                self.report(instruction.line,
                            f"ADD {source}: cannot resolve the source, which may be a URL "
                            f"downloaded with no checksum: {'; '.join(reasons)}")
            elif URL_RE.match(resolved):
                shown = source if source == resolved else f"{source} (= {resolved})"
                self.report(instruction.line, f"ADD {shown} downloads with no checksum: add "
                                              "--checksum=sha256:<hash>")


def escape_annotation(text, is_property=False):
    text = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    if is_property:
        text = text.replace(":", "%3A").replace(",", "%2C")
    return text


def split_reference(reference):
    """(repository, tag) of an image reference with no digest; tag is "" when it has none. A colon
    after the last slash starts the tag; one before it is a registry port."""
    slash = reference.rfind("/")
    colon = reference.rfind(":")
    if colon > slash:
        return reference[:colon], reference[colon + 1:]
    return reference, ""


def is_tag_only(reference, prefixes):
    """Whether the reference's repository is one of the tag-only entries, or under one: "dhi.io"
    matches dhi.io/static, "dhi.io/rust" matches only that repository. Matched as written, with
    no docker.io normalisation."""
    repository, _ = split_reference(reference)
    repository = repository.lower()
    return any(repository == prefix or repository.startswith(prefix + "/")
               for prefix in prefixes)


def parse_tag_only(values):
    prefixes = []
    for value in values:
        prefix = value.strip().lower().rstrip("/")
        if not prefix or any(char in prefix for char in ":@ \t"):
            raise ValueError(f"--tag-only {value!r} is not a registry or repository (no tag, no "
                             "digest)")
        prefixes.append(prefix)
    return prefixes


def parse_build_args(values):
    build_args = {}
    for value in values:
        name, has_value, content = value.partition("=")
        if not has_value or not ARG_NAME_RE.match(name):
            raise ValueError(f"--build-arg {value!r} is not NAME=VALUE")
        build_args[name] = content
    return build_args


def main(argv):
    if sys.version_info < (3, 9):
        print("check-pinned-bases: needs Python 3.9 or later. Nothing was checked.",
              file=sys.stderr)
        return 2
    parser = argparse.ArgumentParser(
        description="Checks that every external image in each Dockerfile is pinned by digest "
                    "and every download is verified by checksum.")
    parser.add_argument("--build-arg", action="append", default=[], metavar="NAME=VALUE",
                        help="a build arg, as docker build --build-arg (repeatable)")
    parser.add_argument("--tag-only", action="append", default=[], metavar="REPOSITORY",
                        help="a registry or repository whose images may be pinned by tag only "
                             "(repeatable)")
    parser.add_argument("dockerfiles", nargs="+", metavar="DOCKERFILE")
    arguments = parser.parse_args(argv)
    try:
        build_args = parse_build_args(arguments.build_arg)
        tag_only = parse_tag_only(arguments.tag_only)
    except ValueError as error:
        print(f"check-pinned-bases: {error}", file=sys.stderr)
        return 2

    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    total = 0
    for path in arguments.dockerfiles:
        try:
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        except (OSError, UnicodeDecodeError) as error:
            print(f"check-pinned-bases: cannot read {path}: {error}. Nothing was checked.",
                  file=sys.stderr)
            return 2
        checker = Checker(build_args, tag_only)
        try:
            checker.check_file(lines)
        except ParseError as error:
            print(f"{path}:{error}. The file was not checked.", file=sys.stderr)
            if annotate:
                print(f"::error file={escape_annotation(path, True)}::"
                      f"{escape_annotation(str(error))}")
            return 2
        for line, message in sorted(checker.findings, key=lambda finding: finding[0]):
            print(f"{path}:{line}: {message}")
            if annotate:
                print(f"::error file={escape_annotation(path, True)},line={line}::"
                      f"{escape_annotation(message)}")
        total += len(checker.findings)

    count = len(arguments.dockerfiles)
    if total:
        print(f"check-pinned-bases: {total} finding(s) in {count} Dockerfile(s).", file=sys.stderr)
        return 1
    pinned = ("by digest, or by tag where tag-only-images allows it," if tag_only
              else "by digest")
    print(f"check-pinned-bases: {count} Dockerfile(s) pin every external image {pinned} and "
          "verify every download.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

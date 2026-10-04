"""Luau lexer. Source is handled as latin-1 decoded text so that every
character corresponds to exactly one byte (Lua string semantics)."""

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true",
    "until", "while",
}

# longest first
OPERATORS = [
    "...", "//=", "..=",
    "==", "~=", "<=", ">=", "..", "::", "->", "+=", "-=", "*=", "/=", "%=", "^=", "//",
    "+", "-", "*", "/", "%", "^", "#", "<", ">", "=", "(", ")", "{", "}", "[", "]",
    ";", ":", ",", ".", "&", "|", "?", "@",
]


class LexError(Exception):
    def __init__(self, msg, line):
        super().__init__(msg)
        self.line = line


class Token:
    __slots__ = ("kind", "value", "line", "col", "pos")

    def __init__(self, kind, value, line, col, pos):
        self.kind = kind  # name, number, string, keyword, op, interp_begin/mid/end/simple, eof
        self.value = value
        self.line = line
        self.col = col
        self.pos = pos

    def __repr__(self):
        return f"Token({self.kind},{self.value!r},{self.line})"


def _utf8(cp):
    return chr(cp).encode("utf-8").decode("latin-1")


class Lexer:
    def __init__(self, src, chunkname="?"):
        self.src = src
        self.n = len(src)
        self.i = 0
        self.line = 1
        self.line_start = 0
        self.chunk = chunkname
        self.tokens = []
        # stack of brace depth for active string interpolations
        self.interp_stack = []

    def err(self, msg):
        raise LexError(f"{self.chunk}:{self.line}: {msg}", self.line)

    def peek(self, k=0):
        j = self.i + k
        return self.src[j] if j < self.n else ""

    def newline(self):
        self.line += 1
        self.line_start = self.i

    def add(self, kind, value, line, col, pos):
        self.tokens.append(Token(kind, value, line, col, pos))

    def long_bracket_level(self):
        # at '[' ; returns level or -1
        j = self.i + 1
        lvl = 0
        while j < self.n and self.src[j] == "=":
            lvl += 1
            j += 1
        if j < self.n and self.src[j] == "[":
            return lvl
        return -1

    def read_long(self, lvl):
        # self.i at first '['
        self.i += lvl + 2
        # skip first newline
        if self.peek() == "\r":
            self.i += 1
            if self.peek() == "\n":
                self.i += 1
            self.newline()
        elif self.peek() == "\n":
            self.i += 1
            if self.peek() == "\r":
                self.i += 1
            self.newline()
        close = "]" + "=" * lvl + "]"
        start = self.i
        out = []
        while True:
            if self.i >= self.n:
                self.err("unfinished long string/comment")
            c = self.src[self.i]
            if c == "]" and self.src.startswith(close, self.i):
                out.append(self.src[start:self.i])
                self.i += len(close)
                return "".join(out)
            if c == "\n":
                self.i += 1
                self.newline()
                continue
            self.i += 1

    def read_escape(self, quote_char):
        # at backslash
        self.i += 1
        c = self.peek()
        simple = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v",
                  "\\": "\\", '"': '"', "'": "'", "`": "`", "{": "{", "}": "}"}
        if c in simple:
            self.i += 1
            return simple[c]
        if c == "\n":
            self.i += 1
            self.newline()
            return "\n"
        if c == "\r":
            self.i += 1
            if self.peek() == "\n":
                self.i += 1
            self.newline()
            return "\n"
        if c == "x":
            h = self.src[self.i + 1:self.i + 3]
            try:
                v = int(h, 16)
            except ValueError:
                self.err("invalid hex escape")
            self.i += 3
            return chr(v)
        if c == "z":
            self.i += 1
            while self.i < self.n and self.src[self.i] in " \t\r\n\f\v":
                if self.src[self.i] == "\n":
                    self.i += 1
                    self.newline()
                else:
                    self.i += 1
            return ""
        if c.isdigit():
            j = self.i
            while j < self.n and j - self.i < 3 and self.src[j].isdigit():
                j += 1
            v = int(self.src[self.i:j])
            if v > 255:
                self.err("decimal escape too large")
            self.i = j
            return chr(v)
        if c == "u":
            if self.peek(1) != "{":
                self.err("invalid unicode escape")
            j = self.src.find("}", self.i)
            if j < 0:
                self.err("invalid unicode escape")
            v = int(self.src[self.i + 2:j], 16)
            self.i = j + 1
            return _utf8(v)
        self.err(f"invalid escape sequence '\\{c}'")

    def read_string(self, q):
        line, col, pos = self.line, self.i - self.line_start, self.i
        self.i += 1
        out = []
        while True:
            if self.i >= self.n:
                self.err("unfinished string")
            c = self.src[self.i]
            if c == q:
                self.i += 1
                break
            if c == "\n":
                self.err("unfinished string")
            if c == "\\":
                out.append(self.read_escape(q))
                continue
            out.append(c)
            self.i += 1
        self.add("string", "".join(out), line, col, pos)

    def read_interp_segment(self, first):
        """Reads an interpolated string segment. self.i is right after '`' (first)
        or right after the closing '}' of an expression."""
        line, col, pos = self.line, self.i - self.line_start, self.i
        out = []
        while True:
            if self.i >= self.n:
                self.err("unfinished interpolated string")
            c = self.src[self.i]
            if c == "`":
                self.i += 1
                self.add("interp_simple" if first else "interp_end", "".join(out), line, col, pos)
                return
            if c == "{":
                if self.peek(1) == "{":
                    self.err("double braces in interpolated string are not permitted")
                self.i += 1
                self.add("interp_begin" if first else "interp_mid", "".join(out), line, col, pos)
                self.interp_stack.append(0)
                return
            if c == "\n":
                self.err("unfinished interpolated string")
            if c == "\\":
                out.append(self.read_escape("`"))
                continue
            out.append(c)
            self.i += 1

    def read_number(self):
        line, col, pos = self.line, self.i - self.line_start, self.i
        s = self.src
        j = self.i
        if s[j] == "0" and j + 1 < self.n and s[j + 1] in "xX":
            j += 2
            st = j
            while j < self.n and (s[j] in "0123456789abcdefABCDEF_"):
                j += 1
            txt = s[st:j].replace("_", "")
            val = float(int(txt, 16))
        elif s[j] == "0" and j + 1 < self.n and s[j + 1] in "bB":
            j += 2
            st = j
            while j < self.n and s[j] in "01_":
                j += 1
            val = float(int(s[st:j].replace("_", ""), 2))
        else:
            st = j
            while j < self.n and (s[j].isdigit() or s[j] == "_"):
                j += 1
            if j < self.n and s[j] == "." and not (j + 1 < self.n and s[j + 1] == "."):
                j += 1
                while j < self.n and (s[j].isdigit() or s[j] == "_"):
                    j += 1
            if j < self.n and s[j] in "eE":
                j += 1
                if j < self.n and s[j] in "+-":
                    j += 1
                while j < self.n and s[j].isdigit():
                    j += 1
            txt = s[st:j].replace("_", "")
            try:
                val = float(txt)
            except ValueError:
                self.err(f"malformed number '{s[st:j]}'")
        if j < self.n and (s[j].isalpha() or s[j] == "_"):
            self.err(f"malformed number near '{s[pos:j+1]}'")
        self.i = j
        self.add("number", val, line, col, pos)

    def tokenize(self):
        s = self.src
        n = self.n
        while True:
            # skip whitespace and comments
            while self.i < n:
                c = s[self.i]
                if c == "\n":
                    self.i += 1
                    self.newline()
                elif c in " \t\r\f\v":
                    self.i += 1
                elif c == "-" and self.peek(1) == "-":
                    self.i += 2
                    if self.peek() == "[":
                        lvl = self.long_bracket_level()
                        if lvl >= 0:
                            self.read_long(lvl)
                            continue
                    while self.i < n and s[self.i] != "\n":
                        self.i += 1
                elif c == "#" and self.i == 0 and self.peek(1) == "!":
                    while self.i < n and s[self.i] != "\n":
                        self.i += 1
                else:
                    break
            if self.i >= n:
                if self.interp_stack:
                    self.err("unfinished interpolated string")
                self.add("eof", None, self.line, self.i - self.line_start, self.i)
                return self.tokens
            c = s[self.i]
            line, col, pos = self.line, self.i - self.line_start, self.i
            if c.isalpha() or c == "_":
                j = self.i + 1
                while j < n and (s[j].isalnum() or s[j] == "_"):
                    j += 1
                word = s[self.i:j]
                self.i = j
                self.add("keyword" if word in KEYWORDS else "name", word, line, col, pos)
                continue
            if c.isdigit() or (c == "." and self.peek(1).isdigit()):
                self.read_number()
                continue
            if c == '"' or c == "'":
                self.read_string(c)
                continue
            if c == "`":
                self.i += 1
                self.read_interp_segment(True)
                continue
            if c == "[":
                lvl = self.long_bracket_level()
                if lvl >= 0:
                    txt = self.read_long(lvl)
                    self.add("string", txt, line, col, pos)
                    continue
            if c == "{" and self.interp_stack:
                self.interp_stack[-1] += 1
            if c == "}" and self.interp_stack:
                if self.interp_stack[-1] == 0:
                    self.interp_stack.pop()
                    self.i += 1
                    self.read_interp_segment(False)
                    continue
                self.interp_stack[-1] -= 1
            for op in OPERATORS:
                if s.startswith(op, self.i):
                    self.i += len(op)
                    self.add("op", op, line, col, pos)
                    break
            else:
                self.err(f"unexpected symbol '{c}'")


def tokenize(src, chunkname="?"):
    return Lexer(src, chunkname).tokenize()

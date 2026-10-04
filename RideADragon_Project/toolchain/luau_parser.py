"""Recursive-descent parser for Luau (including type annotation syntax,
which is parsed and discarded). Produces a tuple-based AST:

  node = (kind, line, *fields)
"""
from luau_lexer import tokenize, LexError


class ParseError(Exception):
    def __init__(self, msg, line):
        super().__init__(msg)
        self.line = line


BINARY_PRIORITY = {
    "+": (6, 6), "-": (6, 6),
    "*": (7, 7), "/": (7, 7), "//": (7, 7), "%": (7, 7),
    "^": (10, 9),
    "..": (5, 4),
    "==": (3, 3), "~=": (3, 3), "<": (3, 3), "<=": (3, 3), ">": (3, 3), ">=": (3, 3),
    "and": (2, 2), "or": (1, 1),
}
UNARY_PRIORITY = 8
COMPOUND_OPS = {"+=": "+", "-=": "-", "*=": "*", "/=": "/", "//=": "//", "%=": "%", "^=": "^", "..=": ".."}
BLOCK_END = {"end", "else", "elseif", "until", "eof"}


class Parser:
    def __init__(self, src, chunkname="?"):
        self.chunk = chunkname
        self.toks = tokenize(src, chunkname)
        self.p = 0
        self.loop_depth = 0

    # ---------------------------------------------------------------- helpers
    @property
    def tok(self):
        return self.toks[self.p]

    def peek(self, k=1):
        j = self.p + k
        return self.toks[j] if j < len(self.toks) else self.toks[-1]

    def err(self, msg, tok=None):
        tok = tok or self.tok
        near = tok.value if tok.kind != "eof" else "<eof>"
        raise ParseError(f"{self.chunk}:{tok.line}: {msg} near '{near}'", tok.line)

    def check(self, kind, value=None):
        t = self.tok
        if value is None:
            return t.kind == kind
        return t.kind == kind and t.value == value

    def is_op(self, value):
        t = self.tok
        return t.kind == "op" and t.value == value

    def is_kw(self, value):
        t = self.tok
        return t.kind == "keyword" and t.value == value

    def accept_op(self, value):
        if self.is_op(value):
            self.p += 1
            return True
        return False

    def accept_kw(self, value):
        if self.is_kw(value):
            self.p += 1
            return True
        return False

    def expect_op(self, value, what=None):
        if not self.is_op(value):
            self.err(f"'{value}' expected" + (f" ({what})" if what else ""))
        self.p += 1

    def expect_kw(self, value, opener=None):
        if not self.is_kw(value):
            if opener is not None:
                self.err(f"'{value}' expected (to close '{opener[0]}' at line {opener[1]})")
            self.err(f"'{value}' expected")
        self.p += 1

    def expect_name(self):
        t = self.tok
        if t.kind != "name":
            self.err("<name> expected")
        self.p += 1
        return t.value

    def block_follow(self):
        t = self.tok
        if t.kind == "eof":
            return True
        return t.kind == "keyword" and t.value in ("end", "else", "elseif", "until")

    # ---------------------------------------------------------------- chunk
    def parse_chunk(self):
        body = self.parse_block()
        if not self.check("eof"):
            self.err("'<eof>' expected")
        return ("Block", 1, body)

    def parse_block(self):
        stats = []
        while not self.block_follow():
            if self.is_kw("return"):
                stats.append(self.parse_return())
                break
            st = self.parse_statement()
            if st is not None:
                stats.append(st)
        return stats

    def parse_return(self):
        line = self.tok.line
        self.p += 1
        exprs = []
        if not self.block_follow() and not self.is_op(";"):
            exprs = self.parse_exprlist()
        self.accept_op(";")
        if not self.block_follow():
            self.err("'<eof>' or block end expected after return")
        return ("Return", line, exprs)

    # ---------------------------------------------------------------- statements
    def parse_statement(self):
        t = self.tok
        line = t.line
        if t.kind == "op":
            if t.value == ";":
                self.p += 1
                return None
            if t.value == "@":
                self.parse_attributes()
                return self.parse_statement()
        if t.kind == "keyword":
            v = t.value
            if v == "if":
                return self.parse_if()
            if v == "while":
                self.p += 1
                cond = self.parse_expr()
                self.expect_kw("do")
                self.loop_depth += 1
                body = self.parse_block()
                self.loop_depth -= 1
                self.expect_kw("end", ("while", line))
                return ("While", line, cond, body)
            if v == "do":
                self.p += 1
                body = self.parse_block()
                self.expect_kw("end", ("do", line))
                return ("Do", line, body)
            if v == "for":
                return self.parse_for()
            if v == "repeat":
                self.p += 1
                self.loop_depth += 1
                body = self.parse_block()
                self.loop_depth -= 1
                self.expect_kw("until", ("repeat", line))
                cond = self.parse_expr()
                return ("Repeat", line, body, cond)
            if v == "function":
                return self.parse_function_stat()
            if v == "local":
                self.p += 1
                if self.accept_kw("function"):
                    name = self.expect_name()
                    fb = self.parse_funcbody(line, name, False)
                    return ("LocalFunc", line, name, fb)
                names = []
                while True:
                    names.append(self.expect_name())
                    if self.accept_op(":"):
                        self.parse_type()
                    if not self.accept_op(","):
                        break
                exprs = []
                if self.accept_op("="):
                    exprs = self.parse_exprlist()
                return ("Local", line, names, exprs)
            if v == "return":
                self.err("unexpected return")
            if v == "break":
                self.p += 1
                if self.loop_depth == 0:
                    self.err("break outside a loop", t)
                return ("Break", line)
        if t.kind == "name":
            v = t.value
            nxt = self.peek()
            if v == "continue" and not (nxt.kind == "op" and nxt.value in ("(", ".", "[", ":", "=", ",", "{") or nxt.kind == "string" or (nxt.kind == "op" and nxt.value in COMPOUND_OPS)):
                self.p += 1
                if self.loop_depth == 0:
                    self.err("continue outside a loop", t)
                return ("Continue", line)
            if v == "type" and nxt.kind == "name":
                self.parse_type_alias()
                return None
            if v == "type" and nxt.kind == "keyword" and nxt.value == "function":
                self.err("type functions are not supported by this toolchain")
            if v == "export" and nxt.kind == "name" and nxt.value == "type":
                self.p += 1
                self.parse_type_alias()
                return None
        # expression statement / assignment
        e = self.parse_suffixed_expr()
        if self.is_op("=") or self.is_op(","):
            targets = [e]
            while self.accept_op(","):
                targets.append(self.parse_suffixed_expr())
            self.expect_op("=")
            for tg in targets:
                if tg[0] not in ("Name", "Index"):
                    self.err("syntax error: cannot assign to this expression")
            exprs = self.parse_exprlist()
            return ("Assign", line, targets, exprs)
        if self.tok.kind == "op" and self.tok.value in COMPOUND_OPS:
            op = COMPOUND_OPS[self.tok.value]
            if e[0] not in ("Name", "Index"):
                self.err("syntax error: cannot assign to this expression")
            self.p += 1
            rhs = self.parse_expr()
            return ("Compound", line, op, e, rhs)
        if e[0] not in ("Call", "Method"):
            self.err("syntax error: expression is not a statement")
        return ("CallStat", line, e)

    def parse_attributes(self):
        while self.accept_op("@"):
            self.expect_name()

    def parse_type_alias(self):
        self.p += 1  # 'type'
        self.expect_name()
        if self.accept_op("<"):
            self.parse_generic_list(defaults=True)
        self.expect_op("=")
        self.parse_type()

    def parse_if(self):
        line = self.tok.line
        self.p += 1
        clauses = []
        cond = self.parse_expr()
        self.expect_kw("then")
        body = self.parse_block()
        clauses.append((cond, body))
        else_body = None
        while True:
            if self.is_kw("elseif"):
                self.p += 1
                c = self.parse_expr()
                self.expect_kw("then")
                b = self.parse_block()
                clauses.append((c, b))
                continue
            if self.is_kw("else"):
                self.p += 1
                else_body = self.parse_block()
            self.expect_kw("end", ("if", line))
            break
        return ("If", line, clauses, else_body)

    def parse_for(self):
        line = self.tok.line
        self.p += 1
        n1 = self.expect_name()
        if self.accept_op(":"):
            self.parse_type()
        if self.accept_op("="):
            start = self.parse_expr()
            self.expect_op(",")
            stop = self.parse_expr()
            step = None
            if self.accept_op(","):
                step = self.parse_expr()
            self.expect_kw("do")
            self.loop_depth += 1
            body = self.parse_block()
            self.loop_depth -= 1
            self.expect_kw("end", ("for", line))
            return ("NumFor", line, n1, start, stop, step, body)
        names = [n1]
        while self.accept_op(","):
            names.append(self.expect_name())
            if self.accept_op(":"):
                self.parse_type()
        self.expect_kw("in")
        exprs = self.parse_exprlist()
        self.expect_kw("do")
        self.loop_depth += 1
        body = self.parse_block()
        self.loop_depth -= 1
        self.expect_kw("end", ("for", line))
        return ("GenFor", line, names, exprs, body)

    def parse_function_stat(self):
        line = self.tok.line
        self.p += 1
        n = self.expect_name()
        target = ("Name", line, n)
        fullname = n
        is_method = False
        while True:
            if self.accept_op("."):
                k = self.expect_name()
                target = ("Index", line, target, ("Str", line, k))
                fullname += "." + k
                continue
            if self.accept_op(":"):
                k = self.expect_name()
                target = ("Index", line, target, ("Str", line, k))
                fullname += ":" + k
                is_method = True
            break
        fb = self.parse_funcbody(line, fullname, is_method)
        return ("FuncStat", line, target, fb)

    def parse_generic_list(self, defaults=False):
        # after '<'
        while True:
            if self.tok.kind == "name":
                self.p += 1
                if self.accept_op("..."):
                    pass
                if defaults and self.accept_op("="):
                    self.parse_type_or_pack()
            elif self.is_op(">"):
                break
            else:
                self.err("generic name expected")
            if not self.accept_op(","):
                break
        self.expect_op(">")

    def parse_funcbody(self, line, name, is_method):
        if self.accept_op("<"):
            self.parse_generic_list()
        self.expect_op("(")
        params = ["self"] if is_method else []
        vararg = False
        if not self.is_op(")"):
            while True:
                if self.accept_op("..."):
                    vararg = True
                    if self.accept_op(":"):
                        self.parse_type_or_pack(allow_generic_pack=True)
                    break
                params.append(self.expect_name())
                if self.accept_op(":"):
                    self.parse_type()
                if not self.accept_op(","):
                    break
        self.expect_op(")")
        if self.accept_op(":"):
            self.parse_return_type()
        saved = self.loop_depth
        self.loop_depth = 0
        body = self.parse_block()
        self.loop_depth = saved
        end_line = self.tok.line
        self.expect_kw("end", ("function", line))
        return ("FuncBody", line, params, vararg, body, name, end_line)

    # ---------------------------------------------------------------- expressions
    def parse_exprlist(self):
        exprs = [self.parse_expr()]
        while self.accept_op(","):
            exprs.append(self.parse_expr())
        return exprs

    def parse_expr(self, limit=0):
        t = self.tok
        line = t.line
        if (t.kind == "keyword" and t.value == "not") or (t.kind == "op" and t.value in ("-", "#")):
            self.p += 1
            operand = self.parse_expr(UNARY_PRIORITY)
            left = ("Un", line, t.value, operand)
        else:
            left = self.parse_simple_expr()
            if self.is_op("::"):
                self.p += 1
                self.parse_type()
                left = ("Cast", line, left)
        while True:
            t = self.tok
            op = None
            if t.kind == "op" and t.value in BINARY_PRIORITY:
                op = t.value
            elif t.kind == "keyword" and t.value in ("and", "or"):
                op = t.value
            if op is None:
                break
            lp, rp = BINARY_PRIORITY[op]
            if lp <= limit:
                break
            self.p += 1
            right = self.parse_expr(rp)
            if op == "and":
                left = ("And", t.line, left, right)
            elif op == "or":
                left = ("Or", t.line, left, right)
            else:
                left = ("Bin", t.line, op, left, right)
        return left

    def parse_simple_expr(self):
        t = self.tok
        line = t.line
        k = t.kind
        if k == "number":
            self.p += 1
            return ("Num", line, t.value)
        if k == "string":
            self.p += 1
            return ("Str", line, t.value)
        if k == "interp_simple":
            self.p += 1
            return ("Str", line, t.value)
        if k == "interp_begin":
            return self.parse_interp()
        if k == "keyword":
            v = t.value
            if v == "nil":
                self.p += 1
                return ("Nil", line)
            if v == "true":
                self.p += 1
                return ("True", line)
            if v == "false":
                self.p += 1
                return ("False", line)
            if v == "function":
                self.p += 1
                fb = self.parse_funcbody(line, "<anonymous>", False)
                return ("Function", line, fb)
            if v == "if":
                return self.parse_if_expr()
        if k == "op":
            v = t.value
            if v == "...":
                self.p += 1
                return ("Vararg", line)
            if v == "{":
                return self.parse_table()
            if v == "@":
                self.parse_attributes()
                if not self.is_kw("function"):
                    self.err("function expected after attribute")
                self.p += 1
                fb = self.parse_funcbody(line, "<anonymous>", False)
                return ("Function", line, fb)
        return self.parse_suffixed_expr()

    def parse_interp(self):
        line = self.tok.line
        parts = [self.tok.value]
        exprs = []
        self.p += 1
        while True:
            exprs.append(self.parse_expr())
            t = self.tok
            if t.kind == "interp_mid":
                parts.append(t.value)
                self.p += 1
                continue
            if t.kind == "interp_end":
                parts.append(t.value)
                self.p += 1
                break
            self.err("malformed interpolated string, expected '}'")
        return ("Interp", line, parts, exprs)

    def parse_if_expr(self):
        line = self.tok.line
        self.p += 1
        clauses = []
        cond = self.parse_expr()
        self.expect_kw("then")
        val = self.parse_expr()
        clauses.append((cond, val))
        while self.accept_kw("elseif"):
            c = self.parse_expr()
            self.expect_kw("then")
            v = self.parse_expr()
            clauses.append((c, v))
        self.expect_kw("else")
        else_val = self.parse_expr()
        return ("IfExpr", line, clauses, else_val)

    def parse_table(self):
        line = self.tok.line
        self.expect_op("{")
        items = []
        while not self.is_op("}"):
            t = self.tok
            if t.kind == "op" and t.value == "[":
                self.p += 1
                key = self.parse_expr()
                self.expect_op("]")
                self.expect_op("=")
                val = self.parse_expr()
                items.append(("keyed", key, val, t.line))
            elif t.kind == "name" and self.peek().kind == "op" and self.peek().value == "=":
                self.p += 2
                val = self.parse_expr()
                items.append(("named", t.value, val, t.line))
            else:
                val = self.parse_expr()
                items.append(("pos", val, None, t.line))
            if not (self.accept_op(",") or self.accept_op(";")):
                break
        self.expect_op("}", "to close table constructor")
        return ("Table", line, items)

    def parse_primary_expr(self):
        t = self.tok
        if t.kind == "name":
            self.p += 1
            return ("Name", t.line, t.value)
        if t.kind == "op" and t.value == "(":
            self.p += 1
            e = self.parse_expr()
            self.expect_op(")")
            return ("Paren", t.line, e)
        self.err("unexpected symbol")

    def parse_suffixed_expr(self):
        e = self.parse_primary_expr()
        while True:
            t = self.tok
            if t.kind == "op":
                v = t.value
                if v == ".":
                    self.p += 1
                    name = self.expect_name()
                    e = ("Index", t.line, e, ("Str", t.line, name))
                    continue
                if v == "[":
                    self.p += 1
                    key = self.parse_expr()
                    self.expect_op("]")
                    e = ("Index", t.line, e, key)
                    continue
                if v == ":":
                    self.p += 1
                    name = self.expect_name()
                    args = self.parse_call_args()
                    e = ("Method", t.line, e, name, args)
                    continue
                if v == "(" or v == "{":
                    # ambiguity: '(' on a new line is still a call in Luau (warns); accept.
                    args = self.parse_call_args()
                    e = ("Call", t.line, e, args)
                    continue
            if t.kind == "string" or t.kind == "interp_simple":
                args = self.parse_call_args()
                e = ("Call", t.line, e, args)
                continue
            return e

    def parse_call_args(self):
        t = self.tok
        if t.kind == "string" or t.kind == "interp_simple":
            self.p += 1
            return [("Str", t.line, t.value)]
        if t.kind == "op" and t.value == "{":
            return [self.parse_table()]
        if t.kind == "op" and t.value == "(":
            self.p += 1
            if self.accept_op(")"):
                return []
            args = self.parse_exprlist()
            self.expect_op(")", "to close function arguments")
            return args
        self.err("function arguments expected")

    # ---------------------------------------------------------------- types
    def parse_return_type(self):
        self.parse_type_or_pack(allow_generic_pack=True)

    def parse_type_or_pack(self, allow_generic_pack=True):
        # variadic '...T'
        if self.accept_op("..."):
            self.parse_type()
            return
        # generic pack 'T...'
        if self.tok.kind == "name" and self.peek().kind == "op" and self.peek().value == "...":
            self.p += 2
            return
        self.parse_type()

    def parse_type(self):
        # optional leading | or &
        if self.is_op("|") or self.is_op("&"):
            self.p += 1
        self.parse_simple_type_with_suffix()
        while True:
            if self.accept_op("|") or self.accept_op("&"):
                self.parse_simple_type_with_suffix()
                continue
            break

    def parse_simple_type_with_suffix(self):
        self.parse_simple_type()
        while self.accept_op("?"):
            pass

    def parse_simple_type(self):
        t = self.tok
        if t.kind == "keyword" and t.value in ("nil", "true", "false"):
            self.p += 1
            return
        if t.kind == "string" or t.kind == "interp_simple":
            self.p += 1
            return
        if t.kind == "name":
            if t.value == "typeof" and self.peek().kind == "op" and self.peek().value == "(":
                self.p += 2
                self.parse_expr()
                self.expect_op(")")
                return
            self.p += 1
            if self.accept_op("."):
                self.expect_name()
            if self.is_op("<"):
                self.p += 1
                self.parse_type_params()
            return
        if t.kind == "keyword" and t.value == "function":
            self.err("unexpected 'function' in type")
        if t.kind == "op":
            if t.value == "{":
                self.parse_table_type()
                return
            if t.value == "(" or t.value == "<":
                self.parse_function_or_paren_type()
                return
        self.err("type expected")

    def parse_type_params(self):
        # after '<'
        if self.accept_op(">"):
            return
        while True:
            if self.is_op("("):
                # type pack or function type
                self.parse_function_or_paren_type(pack_ok=True)
            elif self.is_op("..."):
                self.p += 1
                self.parse_type()
            elif self.tok.kind == "name" and self.peek().kind == "op" and self.peek().value == "...":
                self.p += 2
            else:
                self.parse_type()
            if not self.accept_op(","):
                break
        self.expect_op(">")

    def parse_function_or_paren_type(self, pack_ok=False):
        if self.accept_op("<"):
            self.parse_generic_list()
        self.expect_op("(")
        if not self.is_op(")"):
            while True:
                if self.accept_op("..."):
                    self.parse_type()
                elif self.tok.kind == "name" and self.peek().kind == "op" and self.peek().value == ":":
                    self.p += 2
                    self.parse_type()
                elif self.tok.kind == "name" and self.peek().kind == "op" and self.peek().value == "...":
                    self.p += 2
                else:
                    self.parse_type()
                if not self.accept_op(","):
                    break
        self.expect_op(")")
        if self.accept_op("->"):
            self.parse_return_type()

    def parse_table_type(self):
        self.expect_op("{")
        if self.is_op("}"):
            self.p += 1
            return
        # array type '{ T }' or props
        first = True
        while not self.is_op("}"):
            t = self.tok
            # access modifiers
            if t.kind == "name" and t.value in ("read", "write") and (
                    self.peek().kind == "name" or (self.peek().kind == "op" and self.peek().value == "[")):
                self.p += 1
                t = self.tok
            if t.kind == "op" and t.value == "[":
                self.p += 1
                self.parse_type()
                self.expect_op("]")
                self.expect_op(":")
                self.parse_type()
            elif t.kind == "name" and self.peek().kind == "op" and self.peek().value == ":":
                self.p += 2
                self.parse_type()
            elif first:
                # array shorthand
                self.parse_type()
                self.accept_op(",")
                break
            else:
                self.err("table type field expected")
            first = False
            if not (self.accept_op(",") or self.accept_op(";")):
                break
        self.expect_op("}")


def parse(src, chunkname="?"):
    return Parser(src, chunkname).parse_chunk()


def parse_file(path):
    with open(path, "rb") as f:
        src = f.read().decode("latin-1")
    return parse(src, path)


if __name__ == "__main__":
    import sys
    ok = True
    for p in sys.argv[1:]:
        try:
            parse_file(p)
        except (ParseError, LexError) as e:
            print(e)
            ok = False
    sys.exit(0 if ok else 1)

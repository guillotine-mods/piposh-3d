#!/usr/bin/env python3
"""WDL (Acknex/3D GameStudio script) parser: source text -> JSON AST.

Follows this repo's established convert-time-parsing pattern (WMB/MDL are
also parsed once in Python, never in GDScript) — see docs/CONTRACT.md and
the plan behind this file (a generic runtime interpreter replacing
per-level hand-porting in wdl_director.gd).

Grammar coverage is driven by what's actually in the corpus, measured, not
guessed (see tools/verify_wdl_parse.py and the survey in this file's
originating plan): no C-style `for`, no real `switch`/`case` (every
"switch" hit in the corpus is a `bmap` resource name or a comment/prose
word, not control flow — checked before deciding to skip it), `while`/`if`
control flow, `SET x,y;` as sugar for `x = y;`, `on`/`off` as boolean
literals, `<file.ext>` bracket resource literals, `//` and `/* */`
comments, case-insensitive keywords, `goto`/labels (rare, 15 hits — parsed
so files don't fail, executed as a no-op + warning by the interpreter,
not implemented as real control transfer).

Resilience: top-level constructs this parser doesn't specifically know
(panel/pushbutton/font/text/wave/... resource & UI declarations) are
skipped by balanced-brace or to the next `;`, not treated as a hard
failure — the goal is maximum real coverage of *behavior* (functions and
actions), not a from-scratch clone of every WDL declaration form.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]

# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------

TOKEN_RE = re.compile(
    r"""
    (?P<ws>[ \t\r\n]+)
  | (?P<lcomment>//[^\n]*)
  | (?P<bcomment>/\*.*?\*/)
  | (?P<resource><[^<>\n;()&|!=]*\.[A-Za-z0-9_]+>)
  | (?P<string>"(?:\\.|[^"\\])*")
  | (?P<number>\d+\.\d+|\.\d+|\d+)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>==|!=|<=|>=|&&|\|\||\+=|-=|\*=|/=|[-+*/=<>!.,;(){}\[\]:?&|^])
""",
    re.VERBOSE | re.DOTALL,
)

KEYWORDS = {
    "function", "action", "var", "vector", "entity", "string", "sound",
    "bmap", "wave", "font", "text", "synonym", "include", "if", "else",
    "while", "return", "wait", "waitt", "set", "on", "off", "null", "goto",
    "panel", "type", "break", "define", "path", "material", "view", "level",
    "bool", "ifndef", "ifdef", "endif",
}


class Token:
    __slots__ = ("kind", "value", "line")

    def __init__(self, kind: str, value: str, line: int) -> None:
        self.kind = kind
        self.value = value
        self.line = line

    def __repr__(self) -> str:  # pragma: no cover
        return f"Token({self.kind!r}, {self.value!r})"


def tokenize(text: str) -> list[Token]:
    tokens: list[Token] = []
    line = 1
    pos = 0
    n = len(text)
    while pos < n:
        m = TOKEN_RE.match(text, pos)
        if not m:
            # Unknown byte: skip it rather than aborting the whole file.
            pos += 1
            continue
        pos = m.end()
        kind = m.lastgroup
        val = m.group()
        line += val.count("\n")
        if kind in ("ws", "lcomment", "bcomment"):
            continue
        if kind == "ident":
            low = val.lower()
            if low in KEYWORDS:
                tokens.append(Token(low, val, line))
            else:
                tokens.append(Token("ident", val, line))
        elif kind == "op":
            tokens.append(Token(val, val, line))
        else:
            tokens.append(Token(kind, val, line))
    tokens.append(Token("eof", "", line))
    return _merge_split_operators(tokens)


def _merge_split_operators(tokens: list[Token]) -> list[Token]:
    """Some real files have whitespace-separated `!=` (e.g. `Photo ! = 3`
    in Shiks.wdl, confirmed real source, not a guess). Whitespace is
    dropped before this runs, so a split `!=` is two adjacent tokens here
    regardless of how much space separated them in the source -- merge
    them into one, the same operator either way."""
    out: list[Token] = []
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t.kind == "!" and i + 1 < len(tokens) and tokens[i + 1].kind == "=":
            out.append(Token("!=", "!=", t.line))
            i += 2
            continue
        out.append(t)
        i += 1
    return out


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

class ParseError(Exception):
    pass


class Parser:
    def __init__(self, tokens: list[Token]) -> None:
        self.toks = tokens
        self.i = 0
        self.functions: dict[str, Any] = {}
        self.actions: dict[str, Any] = {}
        self.globals: list[dict] = []
        self.sounds: dict[str, str] = {}
        self.bmaps: dict[str, str] = {}
        self.panels: dict[str, Any] = {}
        self.includes: list[str] = []
        self.top_level_stmts: list[dict] = []
        self.skipped: list[str] = []

    # -- token helpers --
    def cur(self) -> Token:
        return self.toks[self.i]

    def at(self, kind: str) -> bool:
        return self.toks[self.i].kind == kind

    def advance(self) -> Token:
        t = self.toks[self.i]
        if t.kind != "eof":
            self.i += 1
        return t

    def expect(self, kind: str) -> Token:
        if not self.at(kind):
            raise ParseError(
                f"line {self.cur().line}: expected {kind!r}, got {self.cur().kind!r} ({self.cur().value!r})"
            )
        return self.advance()

    def accept(self, kind: str) -> Token | None:
        if self.at(kind):
            return self.advance()
        return None

    # WDL keywords are contextual, not reserved -- `Level`, `Type`, `bmap`,
    # etc. are legitimately used as plain variable/field names outside the
    # one specific construct each is special in (found via Ziggy.wdl, a
    # real playable level, failing to parse over exactly this). Anywhere a
    # NAME is expected, accept any keyword token's text too instead of
    # only "ident".
    def take_name(self) -> str:
        t = self.cur()
        if t.kind == "ident" or t.kind in KEYWORDS:
            return self.advance().value
        raise ParseError(f"line {t.line}: expected a name, got {t.kind!r} ({t.value!r})")

    # -- top level --
    def parse_program(self) -> None:
        while not self.at("eof"):
            try:
                self.parse_top_decl()
            except ParseError as exc:
                self.skipped.append(str(exc))
                self._resync_top_level()

    def _resync_top_level(self) -> None:
        # Skip forward past the failing construct: to the next top-level
        # `;` at brace-depth 0, or past one balanced {..} block.
        depth = 0
        while not self.at("eof"):
            t = self.advance()
            if t.kind == "{":
                depth += 1
            elif t.kind == "}":
                depth -= 1
                if depth <= 0:
                    return
            elif t.kind == ";" and depth == 0:
                return

    def _skip_balanced_or_stmt(self) -> None:
        if self.at("{"):
            depth = 0
            while not self.at("eof"):
                t = self.advance()
                if t.kind == "{":
                    depth += 1
                elif t.kind == "}":
                    depth -= 1
                    if depth == 0:
                        return
        else:
            while not self.at("eof") and not self.at(";"):
                self.advance()
            self.accept(";")

    def parse_top_decl(self) -> None:
        t = self.cur()
        if t.kind == "ident" and self.toks[self.i + 1].kind in ("=", "+=", "-=", "*=", "/="):
            # A bare top-level assignment statement, e.g. Range.wdl's
            # `on_mouse_left = Fire;` (an Acknex global input-event
            # binding, written outside any function/action). Previously
            # fell through to the generic "unknown top-level construct"
            # skip below -- which assumes a `KEYWORD [ident] ({...}|...;)`
            # shape (panel/font/text/... declarations) and, applied to a
            # bare `ident = ident;`, silently ate the whole statement
            # without ever turning it into an executable AST node at all.
            # Confirmed live (2026-08-01, Range): "can't shoot" -- the
            # click hadn't even reached the interpreter's own runtime
            # `on_`-binding logic (WdlInterpreter._assign()), because this
            # line never became a statement in the first place. Reuses
            # the real statement grammar (parse_stmt()) so it round-trips
            # through the exact same `assign`/`id` AST shape a statement
            # inside a function would produce; collected separately so
            # to_json() can expose it and the interpreter can run these
            # once at level start, the same way top-level `var` inits do.
            self.top_level_stmts.append(self.parse_stmt())
            return
        if t.kind == "include":
            self.advance()
            res = self.expect("resource").value
            self.accept(";")
            self.includes.append(res.strip("<>"))
            return
        if t.kind == "function":
            self.advance()
            name = self.take_name()
            params = self.parse_param_list()
            if self.at("{"):
                body = self.parse_block()
            else:
                self.accept(";")
                body = {"t": "block", "body": []}
            self.functions[name] = {"params": params, "body": body}
            return
        if t.kind == "action":
            self.advance()
            name = self.take_name()
            if self.at("("):
                self.parse_param_list()
            if self.at("{"):
                body = self.parse_block()
            else:
                self.accept(";")
                body = {"t": "block", "body": []}
            self.actions[name] = {"body": body}
            return
        if t.kind in ("var", "vector", "entity", "string", "bool"):
            self.parse_var_decl_line(t.kind)
            return
        if t.kind in ("sound", "bmap", "wave"):
            # `SOUND name = <res>;` and the older juxtaposed `SOUND name
            # <res>;` (no `=`) both appear in the shared WDL/ library files
            # -- accept either.
            self.advance()
            name = self.take_name()
            store = self.sounds if t.kind == "sound" else self.bmaps
            if not self.accept("="):
                self.accept(",")  # `SOUND name,<res>;` sugar (auftrag.wdl)
            if self.at("resource"):
                store[name] = self.advance().value.strip("<>")
            else:
                self._skip_expr_until([";", ","])
            while self.accept(","):
                extra_name = self.take_name()
                self.accept("=")
                if self.at("resource"):
                    store[extra_name] = self.advance().value.strip("<>")
                else:
                    self._skip_expr_until([";", ","])
            self.accept(";")
            return
        if t.kind == "synonym":
            self.advance()
            self.take_name()
            self._skip_balanced_or_stmt()
            return
        if t.kind in ("ifndef", "ifdef", "endif"):
            # Preprocessor-like include-guards (`IFNDEF X; ... ENDIF;`) --
            # no real #define system here; treat guards as always-open
            # (their bodies are parsed normally as top-level decls).
            self.advance()
            if self.at("ident"):
                self.advance()
            self.accept(";")
            return
        if t.kind == "define":
            # `DEFINE NAME,VALUE;` -- a compile-time constant macro.
            # Previously parsed but discarded ("rare enough outside the
            # shared WDL/ library files" -- wrong assumption, corrected
            # 2026-08-01): `WDL/movement.wdl` (included by nearly every
            # level via IO.wdl) defines `_MODE_WALKING`/`_MODE_STILL`
            # (1/15) that real player-movement scripts gate their entire
            # per-tick loop on (`while((MY._MOVEMODE>0)&&(MY._MOVEMODE<=
            # _MODE_STILL)){...}`). Left unresolved, both read as the
            # generic undeclared-global fallback (0.0), so
            # `MY._MOVEMODE=_MODE_WALKING` sets movemode to 0 and the
            # loop's own `>0` guard is false from the very first check --
            # the entire loop body, including any win-condition checks it
            # guards, silently never runs at all. Confirmed live: Plane2's
            # `player_move2()` -- the real Acknex movement builtin body
            # this port's native CharacterBody3D controller replaces for
            # actual movement, but which still carries the ONLY copy of
            # "all 4 side-quest goals done -> Run(Range.exe)" -- reported
            # as "the logic that passes us to the next part... doesn't
            # trigger." Captured into `globals` as an ordinary var-shaped
            # decl (`kind: "define"`) so it merges/resolves exactly like
            # every other global already does, including through
            # WdlInterpreter's runtime include-merge -- no new machinery
            # needed on the interpreter side.
            self.advance()
            name = self.take_name()
            value = None
            if self.accept(","):
                value = self.parse_ternary()
            self.accept(";")
            self.globals.append(
                {"name": name, "kind": "define", "array_size": None, "init": value, "init_list": False}
            )
            return
        if t.kind in ("panel", "text"):
            self.parse_panel(t.kind)
            return
        if t.kind == ";":
            self.advance()
            return
        if t.kind == "}":
            # A stray extra closing brace -- confirmed real in the shipped
            # game source (Intro2.wdl's `function Blink()` has one brace
            # too many; verified by counting `{`/`}` depth through the
            # actual file: it goes to -1, not 0). The generic "unknown
            # construct, skip to the next `;`" recovery below is wrong for
            # this case: applied to a lone `}` it skips into and eats the
            # *next* function/action's body (its first inner `;` looks like
            # a top-level terminator), silently dropping real content with
            # no error recorded. A single stray `}` needs to consume only
            # itself and let the next token be re-examined fresh.
            self.skipped.append(f"line {t.line}: stray '}}' at top level (skipped)")
            self.advance()
            return
        # Unknown top-level construct (panel/font/text/material/path/...):
        # skip generically, don't fail the whole file over UI/resource decls.
        # Shape is `KEYWORD [ident] ( { balanced-block } | ... ; )` -- e.g.
        # `panel pSom { ... }` -- so an optional name must be consumed
        # BEFORE looking for the block/statement terminator, or a bare
        # `panel { ... }` skip stops at the first `;` *inside* the block
        # (its own field assignments look like fresh top-level statements
        # otherwise, which is exactly what desynced the whole rest of a
        # file the first time this was tried on Studio.wdl).
        self.advance()
        if self.at("ident"):
            self.advance()
        self._skip_balanced_or_stmt()

    # `panel NAME { field = value[,value...]; ... }` / `text NAME { ... }` --
    # Acknex 2D bitmap/text HUD declarations, previously discarded entirely
    # by the generic "unknown top-level construct" skip above (2026-08-01:
    # this is why Range's shooting-gallery HUD, health bar, and win/lose
    # screens never rendered -- the WDL data for them was never even
    # reaching the AST). Every field line is `NAME [=] atom[,atom...];`
    # (both forms appear in the real corpus -- `bmap = bPanel;` vs. the
    # bare `window 15,58,609,15,bpass,health2,0;`/`BUTTON 020,380,...;`),
    # captured generically (not a fixed schema of known field names) since
    # different panel/text blocks use different field sets. Fields that
    # can legitimately repeat within one panel (`button`, `window`) collect
    # into a list of atom-lists; the interpreter decides how to use each
    # field by name.
    def parse_panel(self, kind: str) -> None:
        self.advance()  # 'panel' / 'text'
        name = self.take_name() if (self.at("ident") or self.cur().kind in KEYWORDS) else f"_anon_{self.cur().line}"
        body: dict[str, list] = {}
        if not self.accept("{"):
            self.accept(";")
            self.panels[name] = {"kind": kind, "fields": body}
            return
        while not self.at("}") and not self.at("eof"):
            if self.accept(";"):
                continue
            field = self.take_name().lower()
            self.accept("=")
            atoms: list[str] = []
            while True:
                atoms.append(self._parse_panel_atom())
                if not self.accept(","):
                    break
            self.accept(";")
            body.setdefault(field, []).append(atoms)
        self.accept("}")
        self.panels[name] = {"kind": kind, "fields": body}

    def _parse_panel_atom(self) -> str:
        t = self.cur()
        if t.kind == "resource":
            return self.advance().value.strip("<>")
        if t.kind in ("number", "string", "ident", "on", "off", "null"):
            return self.advance().value
        if t.kind in KEYWORDS:
            return self.advance().value
        if t.kind == "-":
            # Negative numeric literal (panel positions can be off-screen).
            self.advance()
            return "-" + self._parse_panel_atom()
        # Unrecognized atom shape (rare: an inline expression) -- consume
        # one token so the field list still terminates instead of hanging.
        return self.advance().value

    def parse_param_list(self) -> list[str]:
        params: list[str] = []
        if not self.accept("("):
            return params
        while not self.at(")") and not self.at("eof"):
            if self.at("ident"):
                params.append(self.advance().value)
            else:
                self.advance()
            self.accept(",")
        self.expect(")")
        return params

    def _skip_expr_until(self, stops: list[str]) -> None:
        depth = 0
        while not self.at("eof"):
            if depth == 0 and self.cur().kind in stops:
                return
            k = self.advance().kind
            if k in ("(", "["):
                depth += 1
            elif k in (")", "]"):
                depth -= 1

    _LITERAL_STARTS = {"number", "string", "resource", "on", "off", "null", "-"}

    def parse_var_decl_line(self, kind: str) -> None:
        self.advance()  # consume var/vector/entity/string/bool
        self.accept("*")  # `ENTITY* name;` pointer-style typed decl (doors.wdl)
        decls = []
        while True:
            name = self.take_name()
            if self.at("{"):
                # Declarative object-literal form, not a variable decl:
                # `entity NAME { type = <res.mdl>; layer=10; ... }` (menu
                # decoration entities in IO.wdl). Skip the block; these are
                # static scene-decoration entities, not scripted behavior.
                self._skip_balanced_or_stmt()
                if not self.accept(","):
                    self.accept(";")
                    return
                continue
            array_size = None
            if self.accept("["):
                if not self.at("]"):
                    array_size = self.parse_expr()
                self.expect("]")
            init = None
            # Three initializer shapes seen in the real corpus:
            #  `NAME = value;`                    (standard)
            #  `NAME, "value";`                    (older STRING sugar,
            #                                       WDL/ shared-lib files)
            #  `NAME "value";` / `NAME <res.ext>;` (juxtaposed, no operator)
            # A comma is only "next declared name" if NOT immediately
            # followed by a literal -- `STRING a, b;` (two names) vs
            # `STRING a, "x";` (one name, comma-as-assign) are ambiguous
            # without this lookahead.
            is_list = False
            if self.accept("="):
                init = [self.parse_ternary()]
                while self.accept(","):
                    init.append(self.parse_ternary())
                if len(init) == 1:
                    init = init[0]
                else:
                    is_list = True
            elif self.at(",") and self.toks[self.i + 1].kind in self._LITERAL_STARTS:
                self.advance()  # the comma-as-assign sugar
                init = self.parse_ternary()
            elif self.cur().kind in self._LITERAL_STARTS:
                init = self.parse_ternary()  # juxtaposed, no operator at all
            decls.append(
                {
                    "name": name,
                    "kind": kind,
                    "array_size": array_size,
                    "init": init,
                    "init_list": is_list,
                }
            )
            if not self.accept(","):
                break
        self.accept(";")
        self.globals.extend(decls)

    # -- statements --
    def parse_block(self) -> dict:
        self.expect("{")
        body = []
        while not self.at("}") and not self.at("eof"):
            body.append(self.parse_stmt())
        self.expect("}")
        return {"t": "block", "body": body}

    def parse_stmt(self) -> dict:
        t = self.cur()
        if t.kind == "{":
            return self.parse_block()
        if t.kind == ";":
            self.advance()
            return {"t": "block", "body": []}
        if t.kind in ("var", "vector", "entity", "string", "bool"):
            before = len(self.globals)
            self.parse_var_decl_line(t.kind)
            decls = self.globals[before:]
            del self.globals[before:]
            return {"t": "local_decl", "decls": decls}
        if t.kind == "if":
            self.advance()
            # `if (cond) ...` normally, but `if cond { ... }` (no parens)
            # also appears in the corpus (AsyAct2.wdl) -- accept either.
            has_paren = bool(self.accept("("))
            cond = self.parse_expr()
            if has_paren:
                self.expect(")")
            then = self.parse_stmt()
            els = None
            if self.accept("else"):
                els = self.parse_stmt()
            return {"t": "if", "cond": cond, "then": then, "else": els}
        if t.kind == "while":
            self.advance()
            has_paren = bool(self.accept("("))
            cond = self.parse_expr()
            if has_paren:
                self.expect(")")
            body = self.parse_stmt()
            return {"t": "while", "cond": cond, "body": body}
        if t.kind == "return":
            self.advance()
            val = None
            if not self.at(";"):
                val = self.parse_expr()
            self.accept(";")
            return {"t": "return", "value": val}
        if t.kind in ("wait", "waitt"):
            self.advance()
            n = None
            if self.accept("("):
                if not self.at(")"):
                    n = self.parse_expr()
                self.expect(")")
            self.accept(";")
            return {"t": "wait", "ticks": t.kind == "wait", "n": n}
        if t.kind == "break":
            self.advance()
            self.accept(";")
            return {"t": "break"}
        if t.kind == "goto":
            self.advance()
            label = None
            if self.accept("("):
                label = self.take_name()
                self.expect(")")
            else:
                label = self.take_name()
            self.accept(";")
            return {"t": "goto", "label": label}
        if t.kind == "set":
            self.advance()
            target = self.parse_postfix()
            self.expect(",")
            value = self.parse_ternary()
            self.accept(";")
            return {"t": "expr_stmt", "expr": {"t": "assign", "op": "=", "target": target, "value": value}}
        if t.kind == "ident" and self.toks[self.i + 1].kind == ":":
            name = self.advance().value
            self.advance()
            return {"t": "label", "name": name}
        # Expression statement.
        expr = self.parse_expr()
        # `play_sound Break,100;` / `MOVE ME,NULLSKILL,abspeed;` -- older
        # no-parens, comma-separated command-call syntax (confirmed real,
        # in multiple actual level scripts: AfterMin/Desert/Range/Mount).
        # A bare identifier is never legally followed directly by another
        # primary token (only `;`/an operator/`,`/eof/block-end can follow
        # a real expression statement) -- when that happens, everything up
        # to `;` is this command's juxtaposed/comma-separated argument list.
        if expr.get("t") == "id" and self.cur().kind not in (";", "eof", "}"):
            args = [self.parse_ternary()]
            while self.accept(","):
                args.append(self.parse_ternary())
            expr = {"t": "call", "name": expr["name"], "args": args}
        self.accept(";")
        return {"t": "expr_stmt", "expr": expr}

    # -- expressions (precedence climbing) --
    def parse_expr(self) -> dict:
        return self.parse_assign()

    def parse_assign(self) -> dict:
        left = self.parse_ternary()
        if self.cur().kind in ("=", "+=", "-=", "*=", "/="):
            op = self.advance().kind
            right = self.parse_assign()
            return {"t": "assign", "op": op, "target": left, "value": right}
        return left

    def parse_ternary(self) -> dict:
        cond = self.parse_or()
        if self.accept("?"):
            a = self.parse_ternary()
            self.expect(":")
            b = self.parse_ternary()
            return {"t": "ternary", "cond": cond, "a": a, "b": b}
        return cond

    def parse_or(self) -> dict:
        left = self.parse_and()
        while self.at("||"):
            self.advance()
            left = {"t": "binop", "op": "||", "l": left, "r": self.parse_and()}
        return left

    def parse_and(self) -> dict:
        left = self.parse_bitwise()
        while self.at("&&"):
            self.advance()
            left = {"t": "binop", "op": "&&", "l": left, "r": self.parse_bitwise()}
        return left

    def parse_bitwise(self) -> dict:
        # Bit-flag masking (`MY._FIREMODE & BULLET_SMOKETRAIL`) -- one
        # precedence tier for &,|,^ is enough for how this corpus actually
        # uses them (always explicitly parenthesized flag checks).
        left = self.parse_equality()
        while self.cur().kind in ("&", "|", "^"):
            op = self.advance().kind
            left = {"t": "binop", "op": op, "l": left, "r": self.parse_equality()}
        return left

    def parse_equality(self) -> dict:
        left = self.parse_relational()
        while self.cur().kind in ("==", "!="):
            op = self.advance().kind
            left = {"t": "binop", "op": op, "l": left, "r": self.parse_relational()}
        return left

    def parse_relational(self) -> dict:
        left = self.parse_additive()
        while self.cur().kind in ("<", ">", "<=", ">="):
            op = self.advance().kind
            left = {"t": "binop", "op": op, "l": left, "r": self.parse_additive()}
        return left

    def parse_additive(self) -> dict:
        left = self.parse_mul()
        while self.cur().kind in ("+", "-"):
            op = self.advance().kind
            left = {"t": "binop", "op": op, "l": left, "r": self.parse_mul()}
        return left

    def parse_mul(self) -> dict:
        left = self.parse_unary()
        while self.cur().kind in ("*", "/"):
            op = self.advance().kind
            left = {"t": "binop", "op": op, "l": left, "r": self.parse_unary()}
        return left

    def parse_unary(self) -> dict:
        if self.cur().kind in ("-", "!"):
            op = self.advance().kind
            return {"t": "unop", "op": op, "expr": self.parse_unary()}
        return self.parse_postfix()

    def parse_postfix(self) -> dict:
        expr = self.parse_primary()
        while True:
            if self.accept("."):
                name = self.take_name()
                expr = {"t": "field", "obj": expr, "name": name}
            elif self.accept("["):
                idx = self.parse_expr()
                self.expect("]")
                expr = {"t": "index", "obj": expr, "idx": idx}
            else:
                break
        return expr

    def parse_primary(self) -> dict:
        t = self.cur()
        if t.kind == "number":
            self.advance()
            return {"t": "num", "v": float(t.value)}
        if t.kind == "string":
            self.advance()
            raw = t.value[1:-1]
            raw = raw.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
            return {"t": "str", "v": raw}
        if t.kind == "resource":
            self.advance()
            return {"t": "res", "v": t.value.strip("<>")}
        if t.kind == "on":
            self.advance()
            return {"t": "bool", "v": True}
        if t.kind == "off":
            self.advance()
            return {"t": "bool", "v": False}
        if t.kind == "null":
            self.advance()
            return {"t": "null"}
        if t.kind == "-":
            self.advance()
            return {"t": "unop", "op": "-", "expr": self.parse_unary()}
        if t.kind == "(":
            self.advance()
            e = self.parse_expr()
            self.expect(")")
            return e
        if t.kind == "ident" or t.kind in KEYWORDS:
            # Reached only for genuine expression position (statement-level
            # keywords like if/while/wait are consumed by parse_stmt before
            # parse_expr runs) -- a keyword here is a contextual identifier
            # (e.g. a variable literally named `Level`), same reasoning as
            # take_name().
            name = self.advance().value
            if self.accept("("):
                args = []
                while not self.at(")") and not self.at("eof"):
                    args.append(self.parse_ternary())
                    if not self.accept(","):
                        break
                self.expect(")")
                return {"t": "call", "name": name, "args": args}
            return {"t": "id", "name": name}
        raise ParseError(f"line {t.line}: unexpected token {t.kind!r} ({t.value!r})")


def parse_text(text: str) -> Parser:
    p = Parser(tokenize(text))
    p.parse_program()
    return p


def parse_file(path: Path) -> Parser:
    text = path.read_text(encoding="latin-1", errors="replace")
    return parse_text(text)


def to_json(p: Parser, source: str) -> dict:
    return {
        "source": source,
        "includes": p.includes,
        "globals": p.globals,
        "functions": {k: v for k, v in p.functions.items()},
        "actions": {k: v for k, v in p.actions.items()},
        "sounds": p.sounds,
        "bmaps": p.bmaps,
        "panels": p.panels,
        "top_level_stmts": p.top_level_stmts,
        "skip_count": len(p.skipped),
        "skipped": p.skipped[:20],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", type=Path, default=ROOT / "original" / "piposh3d")
    ap.add_argument("--dst", type=Path, default=ROOT / "assets" / "converted" / "wdl_ast")
    ap.add_argument("--only", nargs="*", default=[])
    args = ap.parse_args()

    # Top-level files (the game's real per-level scripts) must win any
    # stem collision against WDL/ (Conitec's shared/template library, only
    # meant to be reached via `include <...>`) -- e.g. the real game level
    # `Menu.wdl` vs. the unused SDK template `WDL/menu.wdl` collide on
    # output filename otherwise, and whichever wrote last silently wins.
    # Insert WDL/ first so top-level always overwrites on collision.
    by_stem: dict[str, Path] = {}
    for f in sorted((args.src / "WDL").glob("*.wdl")):
        by_stem[f.stem.lower()] = f
    for f in sorted(args.src.glob("*.wdl")):
        by_stem[f.stem.lower()] = f
    files = sorted(by_stem.values(), key=lambda p: p.name)
    if args.only:
        want = {n.lower() for n in args.only}
        files = [f for f in files if f.stem.lower() in want]

    # `include`s are deliberately NOT resolved here -- each file is parsed
    # standalone, `includes` is just recorded (see Parser.includes). That
    # resolution already happens once, at runtime, in
    # WdlInterpreter._merge_includes_recursive()/_merge_ast() (confirmed
    # 2026-08-01 while investigating why Range's `Restart()` -> `ShowRIP()`
    # -- defined only in the included IO.wdl -- appeared to do nothing:
    # turned out the runtime merge already pulls it in correctly, the
    # actual gap was that `panel {...}` blocks were never captured into the
    # AST at all, fixed by parse_panel() above. A second, parse-time merge
    # here would just duplicate that existing, working mechanism.
    args.dst.mkdir(parents=True, exist_ok=True)
    ok = 0
    total_skip = 0
    for f in files:
        p = parse_file(f)
        data = to_json(p, f.name)
        dst = args.dst / f"{f.stem}.json"
        dst.write_text(json.dumps(data, indent=1), encoding="utf-8")
        total_skip += len(p.skipped)
        print(
            f"OK {f.name}: functions={len(p.functions)} actions={len(p.actions)} "
            f"globals={len(p.globals)} panels={len(p.panels)} skipped_decls={len(p.skipped)}"
        )
        ok += 1
    print(f"Parsed {ok}/{len(files)} files, {total_skip} total skipped top-level decls")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

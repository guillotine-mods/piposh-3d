extends RefCounted
## Runtime WDL parser: source text -> the same AST `tools/parse_wdl.py` emits.
##
## Second step of moving conversion into the game. This is a direct port of
## `tools/parse_wdl.py`; every grammar decision there is a recorded corpus
## measurement, so this file deliberately reproduces its behaviour rather than
## improving on it. `tools/smoke_wdl_parser.gd` asserts that by comparing the
## output against the committed `assets/converted/wdl_ast/*.json` for all 85
## scripts. If the two ever disagree, this file is wrong.
##
## Deliberately NO `class_name` (see commit 5c0adfa). Use via `preload`.
##
## Two things differ from the Python by necessity, not by choice:
##
## 1. GDScript has no exceptions. `parse_wdl.py` raises ParseError and catches
##    it in parse_program() to resync. Here `_err` is set instead, and every
##    loop and caller checks it and unwinds. The observable result -- a message
##    appended to `skipped` and a resync -- is identical.
## 2. Source is decoded as latin-1, byte-for-byte, matching the Python's
##    `read_text(encoding="latin-1")`. Reading it as UTF-8 would mangle every
##    high byte in the Hebrew strings and silently change string literals.

const KEYWORDS := {
	"function": true, "action": true, "var": true, "vector": true,
	"entity": true, "string": true, "sound": true, "bmap": true, "wave": true,
	"font": true, "text": true, "synonym": true, "include": true, "if": true,
	"else": true, "while": true, "return": true, "wait": true, "waitt": true,
	"set": true, "on": true, "off": true, "null": true, "goto": true,
	"panel": true, "type": true, "break": true, "define": true, "path": true,
	"material": true, "view": true, "level": true, "bool": true,
	"ifndef": true, "ifdef": true, "endif": true,
}

const LITERAL_STARTS := {
	"number": true, "string": true, "resource": true,
	"on": true, "off": true, "null": true, "-": true,
}

## Token layout. Arrays rather than objects: the corpus is ~11k statements per
## file at peak and this avoids an allocation per token.
const T_KIND := 0
const T_VALUE := 1
const T_LINE := 2

var _toks: Array = []
var _i := 0
var _err := ""

var functions := {}
var actions := {}
var globals: Array = []
var sounds := {}
var bmaps := {}
var panels := {}
var includes: Array = []
var top_level_stmts: Array = []
var skipped: Array = []


# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

## Parse a .wdl file. `source_name` becomes the AST's `source` field and must be
## the file's basename, matching the Python (`f.name`).
static func parse_file(path: String, source_name: String = "") -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var p := new()
	p._parse(_latin1(bytes))
	return p.to_dict(source_name if source_name != "" else path.get_file())


static func parse_text(text: String, source_name: String) -> Dictionary:
	var p := new()
	p._parse(text)
	return p.to_dict(source_name)


## Decode bytes as latin-1: every byte maps 1:1 to the codepoint of the same
## value. Matches Python's `encoding="latin-1"`. Must NOT be UTF-8 -- the
## Hebrew dialogue strings are high-byte and would be corrupted or dropped.
##
## The newline normalisation is not cosmetic. `parse_wdl.py` uses
## `Path.read_text()`, which opens in TEXT mode and therefore applies Python's
## universal-newline translation (\r\n and lone \r both become \n) before the
## lexer ever sees the source. Reading the bytes verbatim instead leaves the \r
## alive inside multi-line string literals, so every such literal differs from
## the committed AST by one invisible character per line -- which is exactly how
## adept2.wdl, mission.wdl and venture.wdl first failed this oracle, printing
## byte sequences that looked identical.
static func _latin1(bytes: PackedByteArray) -> String:
	var out := PackedStringArray()
	out.resize(bytes.size())
	for i in bytes.size():
		out[i] = char(bytes[i])
	return "".join(out).replace("\r\n", "\n").replace("\r", "\n")


func _parse(text: String) -> void:
	_toks = _tokenize(text)
	_i = 0
	while not _at("eof"):
		_err = ""
		_parse_top_decl()
		if _err != "":
			skipped.append(_err)
			_err = ""
			_resync_top_level()


func to_dict(source_name: String) -> Dictionary:
	return {
		"source": source_name,
		"includes": includes,
		"globals": globals,
		"functions": functions,
		"actions": actions,
		"sounds": sounds,
		"bmaps": bmaps,
		"panels": panels,
		"top_level_stmts": top_level_stmts,
		"skip_count": skipped.size(),
		"skipped": skipped.slice(0, 20),
	}


# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------

## Mirrors TOKEN_RE in parse_wdl.py. Alternation order is significant and must
## not be reordered: `resource` must precede `op` or `<...>` lexes as two
## comparison operators, and `number` must precede `op` or `.5` lexes as a dot.
static func _make_regex() -> RegEx:
	var rx := RegEx.new()
	rx.compile(
		"(?s)" +
		"(?<ws>[ \\t\\r\\n]+)" +
		"|(?<lcomment>//[^\\n]*)" +
		"|(?<bcomment>/\\*.*?\\*/)" +
		"|(?<resource><[^<>\\n;()&|!=]*\\.[A-Za-z0-9_]+>)" +
		"|(?<string>\"(?:\\\\.|[^\"\\\\])*\")" +
		"|(?<number>\\d+\\.\\d+|\\.\\d+|\\d+)" +
		"|(?<ident>[A-Za-z_][A-Za-z0-9_]*)" +
		"|(?<op>==|!=|<=|>=|&&|\\|\\||\\+=|-=|\\*=|/=|[-+*/=<>!.,;(){}\\[\\]:?&|^])"
	)
	return rx


const _GROUPS := ["ws", "lcomment", "bcomment", "resource", "string", "number", "ident", "op"]


func _tokenize(text: String) -> Array:
	var rx := _make_regex()
	var toks: Array = []
	var line := 1
	var pos := 0
	var n := text.length()
	while pos < n:
		var m := rx.search(text, pos)
		# `search` finds the next match anywhere; we need a match anchored AT
		# pos, exactly like Python's `TOKEN_RE.match(text, pos)`. Anything else
		# means the byte at pos matches nothing -- skip it, as the Python does.
		if m == null or m.get_start() != pos:
			pos += 1
			continue
		pos = m.get_end()
		var val := m.get_string()
		line += val.count("\n")
		var kind := ""
		for g in _GROUPS:
			if m.get_start(g) != -1:
				kind = g
				break
		if kind == "ws" or kind == "lcomment" or kind == "bcomment":
			continue
		if kind == "ident":
			var low := val.to_lower()
			if KEYWORDS.has(low):
				toks.append([low, val, line])
			else:
				toks.append(["ident", val, line])
		elif kind == "op":
			toks.append([val, val, line])
		else:
			toks.append([kind, val, line])
	toks.append(["eof", "", line])
	return _merge_split_operators(toks)


## Some real files write `!=` with whitespace between (`Photo ! = 3` in
## Shiks.wdl -- confirmed real source). Whitespace is already dropped, so the
## two land adjacent regardless of how much separated them.
static func _merge_split_operators(toks: Array) -> Array:
	var out: Array = []
	var i := 0
	while i < toks.size():
		var t: Array = toks[i]
		if t[T_KIND] == "!" and i + 1 < toks.size() and toks[i + 1][T_KIND] == "=":
			out.append(["!=", "!=", t[T_LINE]])
			i += 2
			continue
		out.append(t)
		i += 1
	return out


# ---------------------------------------------------------------------------
# Token helpers
# ---------------------------------------------------------------------------

func _cur() -> Array:
	return _toks[_i]


func _at(kind: String) -> bool:
	return _toks[_i][T_KIND] == kind


func _peek_kind(offset: int) -> String:
	var j := _i + offset
	return _toks[j][T_KIND] if j < _toks.size() else "eof"


func _advance() -> Array:
	var t: Array = _toks[_i]
	if t[T_KIND] != "eof":
		_i += 1
	return t


func _expect(kind: String) -> Array:
	if not _at(kind):
		var t := _cur()
		# Quoting matches Python's !r so the recorded `skipped` strings are
		# byte-identical to the committed ASTs.
		_fail("line %d: expected '%s', got '%s' ('%s')" % [t[T_LINE], kind, t[T_KIND], t[T_VALUE]])
		return t
	return _advance()


func _accept(kind: String) -> bool:
	if _at(kind):
		_advance()
		return true
	return false


func _fail(msg: String) -> void:
	if _err == "":
		_err = msg


## Anywhere a NAME is expected, a keyword's text is accepted too: WDL keywords
## are contextual, not reserved (`Level`, `Type`, `bmap` are all used as plain
## field names -- found via Ziggy.wdl failing to parse over exactly this).
func _take_name() -> String:
	var t := _cur()
	if t[T_KIND] == "ident" or KEYWORDS.has(t[T_KIND]):
		return _advance()[T_VALUE]
	_fail("line %d: expected a name, got '%s' ('%s')" % [t[T_LINE], t[T_KIND], t[T_VALUE]])
	return ""


func _resync_top_level() -> void:
	var depth := 0
	while not _at("eof"):
		var t := _advance()
		if t[T_KIND] == "{":
			depth += 1
		elif t[T_KIND] == "}":
			depth -= 1
			if depth <= 0:
				return
		elif t[T_KIND] == ";" and depth == 0:
			return


func _skip_balanced_or_stmt() -> void:
	if _at("{"):
		var depth := 0
		while not _at("eof"):
			var t := _advance()
			if t[T_KIND] == "{":
				depth += 1
			elif t[T_KIND] == "}":
				depth -= 1
				if depth == 0:
					return
	else:
		while not _at("eof") and not _at(";"):
			_advance()
		_accept(";")


func _skip_expr_until(stops: Array) -> void:
	var depth := 0
	while not _at("eof"):
		if depth == 0 and stops.has(_cur()[T_KIND]):
			return
		var k: String = _advance()[T_KIND]
		if k == "(" or k == "[":
			depth += 1
		elif k == ")" or k == "]":
			depth -= 1


# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------

func _parse_top_decl() -> void:
	var t := _cur()
	var k: String = t[T_KIND]

	# A bare top-level assignment, e.g. Range.wdl's `on_mouse_left = Fire;`
	# (an Acknex global input-event binding written outside any function).
	# Must be handled before the generic unknown-construct skip, which would
	# silently eat it without producing an executable node.
	if k == "ident" and ["=", "+=", "-=", "*=", "/="].has(_peek_kind(1)):
		var s := _parse_stmt()
		if _err == "":
			top_level_stmts.append(s)
		return

	if k == "include":
		_advance()
		var res := _expect("resource")
		if _err != "":
			return
		_accept(";")
		includes.append(_strip_res(res[T_VALUE]))
		return

	if k == "function":
		_advance()
		var name := _take_name()
		if _err != "":
			return
		var params := _parse_param_list()
		if _err != "":
			return
		var body: Dictionary
		if _at("{"):
			body = _parse_block()
		else:
			_accept(";")
			body = {"t": "block", "body": []}
		if _err != "":
			return
		functions[name] = {"params": params, "body": body}
		return

	if k == "action":
		_advance()
		var name := _take_name()
		if _err != "":
			return
		if _at("("):
			_parse_param_list()
		var body: Dictionary
		if _at("{"):
			body = _parse_block()
		else:
			_accept(";")
			body = {"t": "block", "body": []}
		if _err != "":
			return
		actions[name] = {"body": body}
		return

	if ["var", "vector", "entity", "string", "bool"].has(k):
		_parse_var_decl_line(k)
		return

	if ["sound", "bmap", "wave"].has(k):
		# `SOUND name = <res>;` and the older juxtaposed `SOUND name <res>;`
		# (no `=`) both appear in the shared WDL/ library files.
		_advance()
		var name := _take_name()
		if _err != "":
			return
		var store: Dictionary = sounds if k == "sound" else bmaps
		if not _accept("="):
			_accept(",")  # `SOUND name,<res>;` sugar (auftrag.wdl)
		if _at("resource"):
			store[name] = _strip_res(_advance()[T_VALUE])
		else:
			_skip_expr_until([";", ","])
		while _accept(","):
			var extra := _take_name()
			if _err != "":
				return
			_accept("=")
			if _at("resource"):
				store[extra] = _strip_res(_advance()[T_VALUE])
			else:
				_skip_expr_until([";", ","])
		_accept(";")
		return

	if k == "synonym":
		_advance()
		_take_name()
		if _err != "":
			return
		_skip_balanced_or_stmt()
		return

	if ["ifndef", "ifdef", "endif"].has(k):
		# Include-guards. There is no real #define system here, so guards are
		# treated as always-open and their bodies parsed normally.
		_advance()
		if _at("ident"):
			_advance()
		_accept(";")
		return

	if k == "define":
		# `DEFINE NAME,VALUE;`. Captured as an ordinary var-shaped global so it
		# merges and resolves exactly like every other global, including via the
		# interpreter's runtime include-merge. WDL/movement.wdl's _MODE_WALKING
		# / _MODE_STILL are defined this way and real per-tick movement loops
		# gate on them -- discarding these silently disables those loops.
		_advance()
		var name := _take_name()
		if _err != "":
			return
		var value = null
		if _accept(","):
			value = _parse_ternary()
		if _err != "":
			return
		_accept(";")
		globals.append({
			"name": name, "kind": "define", "array_size": null,
			"init": value, "init_list": false,
		})
		return

	if k == "panel" or k == "text":
		_parse_panel(k)
		return

	if k == ";":
		_advance()
		return

	if k == "}":
		# A stray extra closing brace, confirmed real in the shipped source
		# (Intro2.wdl's `function Blink()` has one too many). The generic
		# skip-to-next-`;` recovery is wrong here: applied to a lone `}` it eats
		# into the NEXT function's body. Consume only the brace.
		skipped.append("line %d: stray '}' at top level (skipped)" % t[T_LINE])
		_advance()
		return

	# Unknown top-level construct (font/material/path/...). Shape is
	# `KEYWORD [ident] ( {balanced} | ...; )`, so the optional name must be
	# consumed BEFORE looking for the terminator -- otherwise a bare
	# `panel { ... }` skip stops at the first `;` INSIDE the block and desyncs
	# the rest of the file.
	_advance()
	if _at("ident"):
		_advance()
	_skip_balanced_or_stmt()


static func _strip_res(v: String) -> String:
	return v.lstrip("<").rstrip(">")


# `panel NAME { field = value[,value...]; ... }` / `text NAME { ... }`.
# Captured generically rather than against a fixed schema, since different
# blocks use different field sets; fields that legitimately repeat (`button`,
# `window`) collect into a list of atom-lists.
func _parse_panel(kind: String) -> void:
	_advance()
	var name := ""
	if _at("ident") or KEYWORDS.has(_cur()[T_KIND]):
		name = _take_name()
	else:
		name = "_anon_%d" % _cur()[T_LINE]
	if _err != "":
		return
	var body := {}
	if not _accept("{"):
		_accept(";")
		panels[name] = {"kind": kind, "fields": body}
		return
	while not _at("}") and not _at("eof"):
		if _accept(";"):
			continue
		var field := _take_name().to_lower()
		if _err != "":
			return
		_accept("=")
		var atoms: Array = []
		while true:
			atoms.append(_parse_panel_atom())
			if not _accept(","):
				break
		_accept(";")
		if not body.has(field):
			body[field] = []
		body[field].append(atoms)
	_accept("}")
	panels[name] = {"kind": kind, "fields": body}


func _parse_panel_atom() -> String:
	var t := _cur()
	var k: String = t[T_KIND]
	if k == "resource":
		return _strip_res(_advance()[T_VALUE])
	if ["number", "string", "ident", "on", "off", "null"].has(k):
		return _advance()[T_VALUE]
	if KEYWORDS.has(k):
		return _advance()[T_VALUE]
	if k == "-":
		# Negative numeric literal (panel positions can be off-screen).
		_advance()
		return "-" + _parse_panel_atom()
	# Unrecognized atom shape (rare inline expression): consume one token so
	# the field list terminates rather than hanging.
	return _advance()[T_VALUE]


func _parse_param_list() -> Array:
	var params: Array = []
	if not _accept("("):
		return params
	while not _at(")") and not _at("eof"):
		if _at("ident"):
			params.append(_advance()[T_VALUE])
		else:
			_advance()
		_accept(",")
	_expect(")")
	return params


func _parse_var_decl_line(kind: String) -> void:
	_advance()
	_accept("*")  # `ENTITY* name;` pointer-style decl (doors.wdl)
	var decls: Array = []
	while true:
		var name := _take_name()
		if _err != "":
			return
		if _at("{"):
			# Declarative object-literal form, not a variable decl:
			# `entity NAME { type = <res.mdl>; ... }` (IO.wdl menu decoration).
			_skip_balanced_or_stmt()
			if not _accept(","):
				_accept(";")
				return
			continue
		var array_size = null
		if _accept("["):
			if not _at("]"):
				array_size = _parse_expr()
			_expect("]")
			if _err != "":
				return
		var init = null
		var is_list := false
		# Three initializer shapes in the real corpus:
		#   `NAME = value;`                      standard
		#   `NAME, "value";`                     older STRING sugar
		#   `NAME "value";` / `NAME <res.ext>;`  juxtaposed, no operator
		# A comma is only "next declared name" if NOT followed by a literal:
		# `STRING a, b;` vs `STRING a, "x";` are ambiguous without lookahead.
		if _accept("="):
			var parts: Array = [_parse_ternary()]
			while _accept(","):
				parts.append(_parse_ternary())
			if _err != "":
				return
			if parts.size() == 1:
				init = parts[0]
			else:
				init = parts
				is_list = true
		elif _at(",") and LITERAL_STARTS.has(_peek_kind(1)):
			_advance()
			init = _parse_ternary()
		elif LITERAL_STARTS.has(_cur()[T_KIND]):
			init = _parse_ternary()
		if _err != "":
			return
		decls.append({
			"name": name, "kind": kind, "array_size": array_size,
			"init": init, "init_list": is_list,
		})
		if not _accept(","):
			break
	_accept(";")
	globals.append_array(decls)


# ---------------------------------------------------------------------------
# Statements
# ---------------------------------------------------------------------------

func _parse_block() -> Dictionary:
	_expect("{")
	if _err != "":
		return {"t": "block", "body": []}
	var body: Array = []
	while not _at("}") and not _at("eof"):
		body.append(_parse_stmt())
		if _err != "":
			return {"t": "block", "body": body}
	_expect("}")
	return {"t": "block", "body": body}


func _parse_stmt() -> Dictionary:
	if _err != "":
		return {"t": "block", "body": []}
	var t := _cur()
	var k: String = t[T_KIND]

	if k == "{":
		return _parse_block()
	if k == ";":
		_advance()
		return {"t": "block", "body": []}

	if ["var", "vector", "entity", "string", "bool"].has(k):
		var before := globals.size()
		_parse_var_decl_line(k)
		var decls := globals.slice(before)
		globals.resize(before)
		return {"t": "local_decl", "decls": decls}

	if k == "if":
		_advance()
		# `if (cond)` normally, but `if cond { ... }` (no parens) also appears
		# in the corpus (AsyAct2.wdl).
		var has_paren := _accept("(")
		var cond := _parse_expr()
		if has_paren:
			_expect(")")
		if _err != "":
			return {"t": "block", "body": []}
		var then := _parse_stmt()
		var els = null
		if _accept("else"):
			els = _parse_stmt()
		return {"t": "if", "cond": cond, "then": then, "else": els}

	if k == "while":
		_advance()
		var has_paren := _accept("(")
		var cond := _parse_expr()
		if has_paren:
			_expect(")")
		if _err != "":
			return {"t": "block", "body": []}
		var body := _parse_stmt()
		return {"t": "while", "cond": cond, "body": body}

	if k == "return":
		_advance()
		var val = null
		if not _at(";"):
			val = _parse_expr()
		_accept(";")
		return {"t": "return", "value": val}

	if k == "wait" or k == "waitt":
		_advance()
		var n = null
		if _accept("("):
			if not _at(")"):
				n = _parse_expr()
			_expect(")")
		_accept(";")
		return {"t": "wait", "ticks": k == "wait", "n": n}

	if k == "break":
		_advance()
		_accept(";")
		return {"t": "break"}

	if k == "goto":
		_advance()
		var label := ""
		if _accept("("):
			label = _take_name()
			_expect(")")
		else:
			label = _take_name()
		_accept(";")
		return {"t": "goto", "label": label}

	if k == "set":
		_advance()
		var target := _parse_postfix()
		_expect(",")
		if _err != "":
			return {"t": "block", "body": []}
		var value := _parse_ternary()
		_accept(";")
		return {"t": "expr_stmt", "expr": {
			"t": "assign", "op": "=", "target": target, "value": value,
		}}

	if k == "ident" and _peek_kind(1) == ":":
		var name: String = _advance()[T_VALUE]
		_advance()
		return {"t": "label", "name": name}

	# Expression statement.
	var expr := _parse_expr()
	if _err != "":
		return {"t": "block", "body": []}
	# `play_sound Break,100;` / `MOVE ME,NULLSKILL,abspeed;` -- the older
	# no-parens, comma-separated command-call syntax (real, in AfterMin /
	# Desert / Range / Mount). A bare identifier is never legally followed
	# directly by another primary, so when it is, everything up to `;` is this
	# command's argument list.
	if expr.get("t") == "id" and not [";", "eof", "}"].has(_cur()[T_KIND]):
		var args: Array = [_parse_ternary()]
		while _accept(","):
			args.append(_parse_ternary())
		if _err != "":
			return {"t": "block", "body": []}
		expr = {"t": "call", "name": expr["name"], "args": args}
	_accept(";")
	return {"t": "expr_stmt", "expr": expr}


# ---------------------------------------------------------------------------
# Expressions (precedence climbing)
# ---------------------------------------------------------------------------

func _parse_expr() -> Dictionary:
	return _parse_assign()


func _parse_assign() -> Dictionary:
	var left := _parse_ternary()
	if _err != "":
		return left
	if ["=", "+=", "-=", "*=", "/="].has(_cur()[T_KIND]):
		var op: String = _advance()[T_KIND]
		var right := _parse_assign()
		return {"t": "assign", "op": op, "target": left, "value": right}
	return left


func _parse_ternary() -> Dictionary:
	var cond := _parse_or()
	if _err != "":
		return cond
	if _accept("?"):
		var a := _parse_ternary()
		_expect(":")
		if _err != "":
			return cond
		var b := _parse_ternary()
		return {"t": "ternary", "cond": cond, "a": a, "b": b}
	return cond


func _parse_or() -> Dictionary:
	var left := _parse_and()
	while _at("||") and _err == "":
		_advance()
		left = {"t": "binop", "op": "||", "l": left, "r": _parse_and()}
	return left


func _parse_and() -> Dictionary:
	var left := _parse_bitwise()
	while _at("&&") and _err == "":
		_advance()
		left = {"t": "binop", "op": "&&", "l": left, "r": _parse_bitwise()}
	return left


func _parse_bitwise() -> Dictionary:
	# Bit-flag masking (`MY._FIREMODE & BULLET_SMOKETRAIL`). One precedence tier
	# for &,|,^ suffices: this corpus always parenthesizes flag checks.
	var left := _parse_equality()
	while ["&", "|", "^"].has(_cur()[T_KIND]) and _err == "":
		var op: String = _advance()[T_KIND]
		left = {"t": "binop", "op": op, "l": left, "r": _parse_equality()}
	return left


func _parse_equality() -> Dictionary:
	var left := _parse_relational()
	while ["==", "!="].has(_cur()[T_KIND]) and _err == "":
		var op: String = _advance()[T_KIND]
		left = {"t": "binop", "op": op, "l": left, "r": _parse_relational()}
	return left


func _parse_relational() -> Dictionary:
	var left := _parse_additive()
	while ["<", ">", "<=", ">="].has(_cur()[T_KIND]) and _err == "":
		var op: String = _advance()[T_KIND]
		left = {"t": "binop", "op": op, "l": left, "r": _parse_additive()}
	return left


func _parse_additive() -> Dictionary:
	var left := _parse_mul()
	while ["+", "-"].has(_cur()[T_KIND]) and _err == "":
		var op: String = _advance()[T_KIND]
		left = {"t": "binop", "op": op, "l": left, "r": _parse_mul()}
	return left


func _parse_mul() -> Dictionary:
	var left := _parse_unary()
	while ["*", "/"].has(_cur()[T_KIND]) and _err == "":
		var op: String = _advance()[T_KIND]
		left = {"t": "binop", "op": op, "l": left, "r": _parse_unary()}
	return left


func _parse_unary() -> Dictionary:
	if ["-", "!"].has(_cur()[T_KIND]):
		var op: String = _advance()[T_KIND]
		return {"t": "unop", "op": op, "expr": _parse_unary()}
	return _parse_postfix()


func _parse_postfix() -> Dictionary:
	var expr := _parse_primary()
	while _err == "":
		if _accept("."):
			var name := _take_name()
			if _err != "":
				return expr
			expr = {"t": "field", "obj": expr, "name": name}
		elif _accept("["):
			var idx := _parse_expr()
			_expect("]")
			if _err != "":
				return expr
			expr = {"t": "index", "obj": expr, "idx": idx}
		else:
			break
	return expr


func _parse_primary() -> Dictionary:
	# Python raises and unwinds the whole stack on a parse error. Here the leaf
	# of expression parsing must refuse to consume anything once `_err` is set,
	# or the two parsers advance by different amounts, resync at different
	# points, and diverge for the rest of the file.
	if _err != "":
		return {"t": "null"}
	var t := _cur()
	var k: String = t[T_KIND]

	if k == "number":
		_advance()
		return {"t": "num", "v": float(t[T_VALUE])}
	if k == "string":
		_advance()
		var raw: String = t[T_VALUE].substr(1, t[T_VALUE].length() - 2)
		# Order matters and matches the Python exactly: \" then \n then \\.
		raw = raw.replace("\\\"", "\"").replace("\\n", "\n").replace("\\\\", "\\")
		return {"t": "str", "v": raw}
	if k == "resource":
		_advance()
		return {"t": "res", "v": _strip_res(t[T_VALUE])}
	if k == "on":
		_advance()
		return {"t": "bool", "v": true}
	if k == "off":
		_advance()
		return {"t": "bool", "v": false}
	if k == "null":
		_advance()
		return {"t": "null"}
	if k == "-":
		_advance()
		return {"t": "unop", "op": "-", "expr": _parse_unary()}
	if k == "(":
		_advance()
		var e := _parse_expr()
		_expect(")")
		return e
	if k == "ident" or KEYWORDS.has(k):
		# Only reached in genuine expression position: statement-level keywords
		# are consumed by _parse_stmt first. A keyword here is a contextual
		# identifier (a variable literally named `Level`), per _take_name().
		var name: String = _advance()[T_VALUE]
		if _accept("("):
			var args: Array = []
			while not _at(")") and not _at("eof"):
				args.append(_parse_ternary())
				if _err != "":
					return {"t": "call", "name": name, "args": args}
				if not _accept(","):
					break
			_expect(")")
			return {"t": "call", "name": name, "args": args}
		return {"t": "id", "name": name}

	_fail("line %d: unexpected token '%s' ('%s')" % [t[T_LINE], k, t[T_VALUE]])
	return {"t": "null"}

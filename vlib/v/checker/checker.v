// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module checker

import v.ast
import v.table
import v.token
import v.pref
import v.util
import v.errors

const (
	max_nr_errors = 300
)

pub struct Checker {
	table          &table.Table
pub mut:
	file           ast.File
	nr_errors      int
	nr_warnings    int
	errors         []errors.Error
	warnings       []errors.Warning
	error_lines    []int // to avoid printing multiple errors for the same line
	expected_type  table.Type
	fn_return_type table.Type // current function's return type
	const_decl     string
	const_deps     []string
	const_names    []string
	pref           &pref.Preferences // Preferences shared from V struct
	in_for_count   int // if checker is currently in an for loop
	// checked_ident  string // to avoid infinit checker loops
	var_decl_name  string
	returns        bool
	scope_returns  bool
	mod            string // current module name
	is_builtin_mod bool // are we in `builtin`?
	inside_unsafe  bool
}

pub fn new_checker(table &table.Table, pref &pref.Preferences) Checker {
	return Checker{
		table: table
		pref: pref
	}
}

pub fn (mut c Checker) check(ast_file ast.File) {
	c.file = ast_file
	for i, ast_import in ast_file.imports {
		for j in 0 .. i {
			if ast_import.mod == ast_file.imports[j].mod {
				c.error('module name `$ast_import.mod` duplicate', ast_import.pos)
			}
		}
	}
	for stmt in ast_file.stmts {
		c.stmt(stmt)
	}
}

pub fn (mut c Checker) check2(ast_file ast.File) []errors.Error {
	c.file = ast_file
	for stmt in ast_file.stmts {
		c.stmt(stmt)
	}
	return c.errors
}

pub fn (mut c Checker) check_files(ast_files []ast.File) {
	mut has_main_mod_file := false
	mut has_main_fn := false
	for file in ast_files {
		c.check(file)
		if file.mod.name == 'main' {
			has_main_mod_file = true
			if c.check_file_in_main(file) {
				has_main_fn = true
			}
		}
	}
	// Make sure fn main is defined in non lib builds
	if c.pref.build_mode == .build_module || c.pref.is_test {
		return
	}
	if c.pref.is_shared {
		// shared libs do not need to have a main
		return
	}
	if !has_main_mod_file {
		c.error('project must include a `main` module or be a shared library (compile with `v -shared`)',
			token.Position{})
	} else if !has_main_fn {
		c.error('function `main` must be declared in the main module', token.Position{})
	}
}

const (
	no_pub_in_main_warning = 'in module main cannot be declared public'
)

// do checks specific to files in main module
// returns `true` if a main function is in the file
fn (mut c Checker) check_file_in_main(file ast.File) bool {
	mut has_main_fn := false
	for stmt in file.stmts {
		match stmt {
			ast.ConstDecl {
				if it.is_pub {
					c.warn('const $no_pub_in_main_warning', it.pos)
				}
			}
			ast.ConstField {
				if it.is_pub {
					c.warn('const field `$it.name` $no_pub_in_main_warning', it.pos)
				}
			}
			ast.EnumDecl {
				if it.is_pub {
					c.warn('enum `$it.name` $no_pub_in_main_warning', it.pos)
				}
			}
			ast.FnDecl {
				if it.name == 'main' {
					has_main_fn = true
					if it.is_pub {
						c.error('function `main` cannot be declared public', it.pos)
					}
					if it.args.len > 0 {
						c.error('function `main` cannot have arguments', it.pos)
					}
					if it.return_type != table.void_type {
						c.error('function `main` cannot return values', it.pos)
					}
				} else {
					if it.is_pub {
						c.warn('function `$it.name` $no_pub_in_main_warning', it.pos)
					}
				}
				if it.ctdefine.len > 0 {
					if it.return_type != table.void_type {
						c.error('only functions that do NOT return values can have `[if ${it.ctdefine}]` tags',
							it.pos)
					}
				}
			}
			ast.StructDecl {
				if it.is_pub {
					c.warn('struct `$it.name` $no_pub_in_main_warning', it.pos)
				}
			}
			ast.TypeDecl {
				type_decl := stmt as ast.TypeDecl
				if type_decl is ast.AliasTypeDecl {
					alias_decl := type_decl as ast.AliasTypeDecl
					if alias_decl.is_pub {
						c.warn('type alias `$alias_decl.name` $no_pub_in_main_warning', alias_decl.pos)
					}
				} else if type_decl is ast.SumTypeDecl {
					sum_decl := type_decl as ast.SumTypeDecl
					if sum_decl.is_pub {
						c.warn('sum type `$sum_decl.name` $no_pub_in_main_warning', sum_decl.pos)
					}
				} else if type_decl is ast.FnTypeDecl {
					fn_decl := type_decl as ast.FnTypeDecl
					if fn_decl.is_pub {
						c.warn('type alias `$fn_decl.name` $no_pub_in_main_warning', fn_decl.pos)
					}
				}
			}
			else {}
		}
	}
	return has_main_fn
}

pub fn (mut c Checker) type_decl(node ast.TypeDecl) {
	match node {
		ast.AliasTypeDecl {
			typ_sym := c.table.get_type_symbol(it.parent_type)
			if typ_sym.kind == .placeholder {
				c.error("type `$typ_sym.name` doesn't exist", it.pos)
			}
		}
		ast.FnTypeDecl {
			typ_sym := c.table.get_type_symbol(it.typ)
			fn_typ_info := typ_sym.info as table.FnType
			fn_info := fn_typ_info.func
			ret_sym := c.table.get_type_symbol(fn_info.return_type)
			if ret_sym.kind == .placeholder {
				c.error("type `$ret_sym.name` doesn't exist", it.pos)
			}
			for arg in fn_info.args {
				arg_sym := c.table.get_type_symbol(arg.typ)
				if arg_sym.kind == .placeholder {
					c.error("type `$arg_sym.name` doesn't exist", it.pos)
				}
			}
		}
		ast.SumTypeDecl {
			for typ in it.sub_types {
				typ_sym := c.table.get_type_symbol(typ)
				if typ_sym.kind == .placeholder {
					c.error("type `$typ_sym.name` doesn't exist", it.pos)
				}
			}
		}
	}
}

pub fn (mut c Checker) struct_decl(decl ast.StructDecl) {
	for i, field in decl.fields {
		for j in 0 .. i {
			if field.name == decl.fields[j].name {
				c.error('field name `$field.name` duplicate', field.pos)
			}
		}
		sym := c.table.get_type_symbol(field.typ)
		if sym.kind == .placeholder && !decl.is_c && !sym.name.starts_with('C.') {
			c.error('unknown type `$sym.name`', field.pos)
		}
		if sym.kind == .struct_ {
			info := sym.info as table.Struct
			if info.is_ref_only && !field.typ.is_ptr() {
				c.error('`$sym.name` type can only be used as a reference: `&$sym.name`', field.pos)
			}
		}
		if field.has_default_expr {
			c.expected_type = field.typ
			field_expr_type := c.expr(field.default_expr)
			if !c.table.check(field_expr_type, field.typ) {
				field_expr_type_sym := c.table.get_type_symbol(field_expr_type)
				field_type_sym := c.table.get_type_symbol(field.typ)
				c.error('default expression for field `${field.name}` ' + 'has type `${field_expr_type_sym.name}`, but should be `${field_type_sym.name}`',
					field.default_expr.position())
			}
		}
	}
}

pub fn (mut c Checker) struct_init(mut struct_init ast.StructInit) table.Type {
	// typ := c.table.find_type(struct_init.typ.typ.name) or {
	// c.error('unknown struct: $struct_init.typ.typ.name', struct_init.pos)
	// panic('')
	// }
	if struct_init.typ == table.void_type {
		// Short syntax `({foo: bar})`
		if c.expected_type == table.void_type {
			c.error('unexpected short struct syntax', struct_init.pos)
			return table.void_type
		}
		struct_init.typ = c.expected_type
	}
	type_sym := c.table.get_type_symbol(struct_init.typ)
	if type_sym.kind == .interface_ {
		c.error('cannot instantiate interface `$type_sym.name`', struct_init.pos)
	}
	if !type_sym.is_public && type_sym.kind != .placeholder && type_sym.mod != c.mod {
		c.error('type `$type_sym.name` is private', struct_init.pos)
	}
	// println('check struct $typ_sym.name')
	match type_sym.kind {
		.placeholder {
			c.error('unknown struct: $type_sym.name', struct_init.pos)
		}
		// string & array are also structs but .kind of string/array
		.struct_, .string, .array {
			info := type_sym.info as table.Struct
			if struct_init.is_short && struct_init.fields.len > info.fields.len {
				c.error('too many fields', struct_init.pos)
			}
			mut inited_fields := []string{}
			for i, field in struct_init.fields {
				mut info_field := table.Field{}
				mut field_name := ''
				if struct_init.is_short {
					if i >= info.fields.len {
						// It doesn't make sense to check for fields that don't exist.
						// We should just stop here.
						break
					}
					info_field = info.fields[i]
					field_name = info_field.name
					struct_init.fields[i].name = field_name
				} else {
					field_name = field.name
					mut exists := false
					for f in info.fields {
						if f.name == field_name {
							info_field = f
							exists = true
							break
						}
					}
					if !exists {
						c.error('unknown field `$field.name` in struct literal of type `$type_sym.name`',
							field.pos)
						continue
					}
					if field_name in inited_fields {
						c.error('duplicate field name in struct literal: `$field_name`', field.pos)
						continue
					}
				}
				inited_fields << field_name
				c.expected_type = info_field.typ
				expr_type := c.expr(field.expr)
				expr_type_sym := c.table.get_type_symbol(expr_type)
				field_type_sym := c.table.get_type_symbol(info_field.typ)
				if !c.table.check(expr_type, info_field.typ) {
					c.error('cannot assign `$expr_type_sym.name` as `$field_type_sym.name` for field `$info_field.name`',
						field.pos)
				}
				struct_init.fields[i].typ = expr_type
				struct_init.fields[i].expected_type = info_field.typ
			}
			// Check uninitialized refs
			for field in info.fields {
				if field.has_default_expr || field.name in inited_fields {
					continue
				}
				if field.typ.is_ptr() {
					c.warn('reference field `${type_sym.name}.${field.name}` must be initialized',
						struct_init.pos)
				}
			}
		}
		else {}
	}
	return struct_init.typ
}

pub fn (mut c Checker) infix_expr(mut infix_expr ast.InfixExpr) table.Type {
	// println('checker: infix expr(op $infix_expr.op.str())')
	former_expected_type := c.expected_type
	defer {
		c.expected_type = former_expected_type
	}
	c.expected_type = table.void_type
	left_type := c.expr(infix_expr.left)
	infix_expr.left_type = left_type
	c.expected_type = left_type
	right_type := c.expr(infix_expr.right)
	infix_expr.right_type = right_type
	right := c.table.get_type_symbol(right_type)
	left := c.table.get_type_symbol(left_type)
	// Single side check
	// Place these branches according to ops' usage frequency to accelerate.
	// TODO: First branch includes ops where single side check is not needed, or needed but hasn't been implemented.
	// TODO: Some of the checks are not single side. Should find a better way to organize them.
	match infix_expr.op {
		// .eq, .ne, .gt, .lt, .ge, .le, .and, .logical_or, .dot, .key_as, .right_shift {}
		.key_in, .not_in {
			match right.kind {
				.array {
					right_sym := c.table.get_type_symbol(right.array_info().elem_type)
					if left.kind != right_sym.kind {
						c.error('the data type on the left of `in` does not match the array item type',
							infix_expr.pos)
					}
				}
				.map {
					key_sym := c.table.get_type_symbol(right.map_info().key_type)
					if left.kind != key_sym.kind {
						c.error('the data type on the left of `in` does not match the map key type',
							infix_expr.pos)
					}
				}
				.string {
					if left.kind != .string {
						c.error('the data type on the left of `in` must be a string', infix_expr.pos)
					}
				}
				else {
					c.error('`in` can only be used with an array/map/string', infix_expr.pos)
				}
			}
			return table.bool_type
		}
		.plus, .minus, .mul, .div {
			if infix_expr.op == .div && (infix_expr.right is ast.IntegerLiteral && infix_expr.right.str() ==
				'0' || infix_expr.right is ast.FloatLiteral && infix_expr.right.str().f64() == 0.0) {
				c.error('division by zero', infix_expr.right.position())
			}
			if left.kind in [.array, .array_fixed, .map, .struct_] && !left.has_method(infix_expr.op.str()) {
				c.error('mismatched types `$left.name` and `$right.name`', infix_expr.left.position())
			} else if right.kind in [.array, .array_fixed, .map, .struct_] && !right.has_method(infix_expr.op.str()) {
				c.error('mismatched types `$left.name` and `$right.name`', infix_expr.right.position())
			}
		}
		.left_shift {
			if left.kind == .array {
				// `array << elm`
				c.fail_if_immutable(infix_expr.left)
				left_value_type := c.table.value_type(left_type)
				left_value_sym := c.table.get_type_symbol(left_value_type)
				if left_value_sym.kind == .interface_ {
					if right.kind != .array {
						// []Animal << Cat
						c.type_implements(right_type, left_value_type, infix_expr.right.position())
					} else {
						// []Animal << Cat
						c.type_implements(c.table.value_type(right_type), left_value_type,
							infix_expr.right.position())
					}
					return table.void_type
				}
				// the expressions have different types (array_x and x)
				if c.table.check(right_type, left_value_type) { // , right_type) {
					// []T << T
					return table.void_type
				}
				if right.kind == .array && c.table.check(left_value_type, c.table.value_type(right_type)) {
					// []T << []T
					return table.void_type
				}
				s := left.name.replace('array_', '[]')
				c.error('cannot append `$right.name` to `$s`', infix_expr.right.position())
				return table.void_type
			} else if !left.is_int() {
				c.error('cannot shift type $right.name into non-integer type $left.name', infix_expr.left.position())
				return table.void_type
			} else if !right.is_int() {
				c.error('cannot shift non-integer type $right.name into type $left.name', infix_expr.right.position())
				return table.void_type
			}
		}
		.key_is {
			type_expr := infix_expr.right as ast.Type
			typ_sym := c.table.get_type_symbol(type_expr.typ)
			if typ_sym.kind == .placeholder {
				c.error('is: type `${typ_sym.name}` does not exist', type_expr.pos)
			}
			return table.bool_type
		}
		.amp, .pipe, .xor {
			if !left.is_int() {
				c.error('left type of `${infix_expr.op.str()}` cannot be non-integer type $left.name',
					infix_expr.left.position())
			} else if !right.is_int() {
				c.error('right type of `${infix_expr.op.str()}` cannot be non-integer type $right.name',
					infix_expr.right.position())
			}
		}
		.mod {
			if left.is_int() && !right.is_int() {
				c.error('mismatched types `$left.name` and `$right.name`', infix_expr.right.position())
			} else if !left.is_int() && right.is_int() {
				c.error('mismatched types `$left.name` and `$right.name`', infix_expr.left.position())
			} else if left.kind in [.f32, .f64, .string, .array, .array_fixed, .map, .struct_] &&
				!left.has_method(infix_expr.op.str()) {
				c.error('mismatched types `$left.name` and `$right.name`', infix_expr.left.position())
			} else if right.kind in [.f32, .f64, .string, .array, .array_fixed, .map, .struct_] &&
				!right.has_method(infix_expr.op.str()) {
				c.error('mismatched types `$left.name` and `$right.name`', infix_expr.right.position())
			}
		}
		else {}
	}
	// TODO: Absorb this block into the above single side check block to accelerate.
	if left_type == table.bool_type && infix_expr.op !in [.eq, .ne, .logical_or, .and] {
		c.error('bool types only have the following operators defined: `==`, `!=`, `||`, and `&&`',
			infix_expr.pos)
	} else if left_type == table.string_type && infix_expr.op !in [.plus, .eq, .ne, .lt, .gt,
		.le, .ge] {
		// TODO broken !in
		c.error('string types only have the following operators defined: `==`, `!=`, `<`, `>`, `<=`, `>=`, and `&&`',
			infix_expr.pos)
	}
	// Dual sides check (compatibility check)
	if !c.table.check(right_type, left_type) {
		// for type-unresolved consts
		if left_type == table.void_type || right_type == table.void_type {
			return table.void_type
		}
		c.error('infix expr: cannot use `$right.name` (right expression) as `$left.name`',
			infix_expr.pos)
	}
	return if infix_expr.op.is_relational() {
		table.bool_type
	} else {
		left_type
	}
}

fn (mut c Checker) fail_if_immutable(expr ast.Expr) {
	match expr {
		ast.Ident {
			scope := c.file.scope.innermost(it.pos.pos)
			if v := scope.find_var(it.name) {
				if !v.is_mut && !v.typ.is_ptr() {
					c.error('`$it.name` is immutable, declare it with `mut` to make it mutable',
						it.pos)
				}
			} else if it.name in c.const_names {
				c.error('cannot assign to constant `$it.name`', it.pos)
			}
		}
		ast.IndexExpr {
			c.fail_if_immutable(it.left)
		}
		ast.ParExpr {
			c.fail_if_immutable(it.expr)
		}
		ast.PrefixExpr {
			c.fail_if_immutable(it.right)
		}
		ast.SelectorExpr {
			// retrieve table.Field
			if it.expr_type == 0 {
				c.error('0 type in SelectorExpr', it.pos)
				return
			}
			typ_sym := c.table.get_type_symbol(it.expr_type)
			match typ_sym.kind {
				.struct_ {
					struct_info := typ_sym.info as table.Struct
					field_info := struct_info.find_field(it.field_name) or {
						type_str := c.table.type_to_str(it.expr_type)
						c.error('unknown field `${type_str}.$it.field_name`', it.pos)
						return
					}
					if !field_info.is_mut {
						type_str := c.table.type_to_str(it.expr_type)
						c.error('field `$it.field_name` of struct `${type_str}` is immutable',
							it.pos)
					}
					c.fail_if_immutable(it.expr)
				}
				.array, .string {
					// This should only happen in `builtin`
					// TODO Remove `crypto.rand` when possible (see vlib/crypto/rand/rand.v,
					// if `c_array_to_bytes_tmp` doesn't exist, then it's safe to remove it)
					if c.file.mod.name !in ['builtin', 'crypto.rand'] {
						c.error('`$typ_sym.kind` can not be modified', it.pos)
					}
				}
				else {
					c.error('unexpected symbol `${typ_sym.kind}`', it.pos)
				}
			}
		}
		else {
			c.error('unexpected expression `${typeof(expr)}`', expr.position())
		}
	}
}

fn (mut c Checker) assign_expr(mut assign_expr ast.AssignExpr) {
	c.expected_type = table.void_type
	left_type := c.expr(assign_expr.left)
	c.expected_type = left_type
	assign_expr.left_type = left_type
	// println('setting exp type to $c.expected_type $t.name')
	right_type := c.expr(assign_expr.val)
	assign_expr.right_type = right_type
	right := c.table.get_type_symbol(right_type)
	left := c.table.get_type_symbol(left_type)
	if ast.expr_is_blank_ident(assign_expr.left) {
		return
	}
	// Make sure the variable is mutable
	c.fail_if_immutable(assign_expr.left)
	// Do now allow `*x = y` outside `unsafe`
	if assign_expr.left is ast.PrefixExpr {
		p := assign_expr.left as ast.PrefixExpr
		if p.op == .mul && !c.inside_unsafe {
			c.error('modifying variables via deferencing can only be done in `unsafe` blocks',
				assign_expr.pos)
		}
	}
	// Single side check
	match assign_expr.op {
		.assign {} // No need to do single side check for =. But here put it first for speed.
		.plus_assign {
			if !left.is_number() && left_type != table.string_type && !left.is_pointer() {
				c.error('operator += not defined on left operand type `$left.name`', assign_expr.left.position())
			} else if !right.is_number() && right_type != table.string_type && !right.is_pointer() {
				c.error('operator += not defined on right operand type `$right.name`', assign_expr.val.position())
			}
		}
		.minus_assign {
			if !left.is_number() && !left.is_pointer() {
				c.error('operator -= not defined on left operand type `$left.name`', assign_expr.left.position())
			} else if !right.is_number() && !right.is_pointer() {
				c.error('operator -= not defined on right operand type `$right.name`', assign_expr.val.position())
			}
		}
		.mult_assign, .div_assign {
			if !left.is_number() {
				c.error('operator ${assign_expr.op.str()} not defined on left operand type `$left.name`',
					assign_expr.left.position())
			} else if !right.is_number() {
				c.error('operator ${assign_expr.op.str()} not defined on right operand type `$right.name`',
					assign_expr.val.position())
			}
		}
		.and_assign, .or_assign, .xor_assign, .mod_assign, .left_shift_assign, .right_shift_assign {
			if !left.is_int() {
				c.error('operator ${assign_expr.op.str()} not defined on left operand type `$left.name`',
					assign_expr.left.position())
			} else if !right.is_int() {
				c.error('operator ${assign_expr.op.str()} not defined on right operand type `$right.name`',
					assign_expr.val.position())
			}
		}
		else {}
	}
	// Dual sides check (compatibility check)
	if !c.table.check(right_type, left_type) {
		left_type_sym := c.table.get_type_symbol(left_type)
		right_type_sym := c.table.get_type_symbol(right_type)
		c.error('cannot assign `$right_type_sym.name` to variable `${assign_expr.left.str()}` of type `$left_type_sym.name`',
			assign_expr.val.position())
	}
	c.check_expr_opt_call(assign_expr.val, right_type, true)
}

pub fn (mut c Checker) call_expr(mut call_expr ast.CallExpr) table.Type {
	c.stmts(call_expr.or_block.stmts)
	if call_expr.is_method {
		return c.call_method(call_expr)
	}
	return c.call_fn(call_expr)
}

pub fn (mut c Checker) call_method(mut call_expr ast.CallExpr) table.Type {
	left_type := c.expr(call_expr.left)
	call_expr.left_type = left_type
	left_type_sym := c.table.get_type_symbol(left_type)
	method_name := call_expr.name
	// TODO: remove this for actual methods, use only for compiler magic
	// FIXME: Argument count != 1 will break these
	if left_type_sym.kind == .array && method_name in ['filter', 'clone', 'repeat', 'reverse',
		'map', 'slice'] {
		if method_name in ['filter', 'map'] {
			array_info := left_type_sym.info as table.Array
			mut scope := c.file.scope.innermost(call_expr.pos.pos)
			scope.update_var_type('it', array_info.elem_type)
		}
		// map/filter are supposed to have 1 arg only
		mut arg_type := left_type
		for arg in call_expr.args {
			arg_type = c.expr(arg.expr)
		}
		call_expr.return_type = left_type
		call_expr.receiver_type = left_type
		if method_name == 'map' {
			call_expr.return_type = c.table.find_or_register_array(arg_type, 1)
		} else if method_name == 'clone' {
			// need to return `array_xxx` instead of `array`
			// in ['clone', 'str'] {
			call_expr.receiver_type = left_type.to_ptr()
			// call_expr.return_type = call_expr.receiver_type
		}
		return call_expr.return_type
	} else if left_type_sym.kind == .array && method_name in ['first', 'last'] {
		info := left_type_sym.info as table.Array
		call_expr.return_type = info.elem_type
		call_expr.receiver_type = left_type
		return call_expr.return_type
	}
	if method := c.table.type_find_method(left_type_sym, method_name) {
		if !method.is_pub && !c.is_builtin_mod && !c.pref.is_test && left_type_sym.mod != c.mod &&
			left_type_sym.mod != '' { // method.mod != c.mod {
			// If a private method is called outside of the module
			// its receiver type is defined in, show an error.
			// println('warn $method_name lef.mod=$left_type_sym.mod c.mod=$c.mod')
			c.error('method `${left_type_sym.name}.$method_name` is private', call_expr.pos)
		}
		if method.return_type == table.void_type && method.ctdefine.len > 0 && method.ctdefine !in
			c.pref.compile_defines {
			call_expr.should_be_skipped = true
		}
		nr_args := if method.args.len == 0 { 0 } else { method.args.len - 1 }
		min_required_args := method.args.len - if method.is_variadic && method.args.len > 1 { 2 } else { 1 }
		if call_expr.args.len < min_required_args {
			c.error('too few arguments in call to `${left_type_sym.name}.$method_name` ($call_expr.args.len instead of $min_required_args)',
				call_expr.pos)
		} else if !method.is_variadic && call_expr.args.len > nr_args {
			c.error('!too many arguments in call to `${left_type_sym.name}.$method_name` ($call_expr.args.len instead of $nr_args)',
				call_expr.pos)
			return method.return_type
		}
		// if method_name == 'clone' {
		// println('CLONE nr args=$method.args.len')
		// }
		// call_expr.args << method.args[0].typ
		// call_expr.exp_arg_types << method.args[0].typ
		for i, arg in call_expr.args {
			exp_arg_typ := if method.is_variadic && i >= method.args.len - 1 { method.args[method.args.len -
					1].typ } else { method.args[i + 1].typ }
			exp_arg_sym := c.table.get_type_symbol(exp_arg_typ)
			c.expected_type = exp_arg_typ
			got_arg_typ := c.expr(arg.expr)
			call_expr.args[i].typ = got_arg_typ
			if method.is_variadic && got_arg_typ.flag_is(.variadic) && call_expr.args.len -
				1 > i {
				c.error('when forwarding a varg variable, it must be the final argument', call_expr.pos)
			}
			if exp_arg_sym.kind == .interface_ {
				c.type_implements(got_arg_typ, exp_arg_typ, arg.expr.position())
				continue
			}
			if !c.table.check(got_arg_typ, exp_arg_typ) {
				got_arg_sym := c.table.get_type_symbol(got_arg_typ)
				// str method, allow type with str method if fn arg is string
				if exp_arg_sym.kind == .string && got_arg_sym.has_method('str') {
					continue
				}
				c.error('cannot use type `$got_arg_sym.str()` as type `$exp_arg_sym.str()` in argument ${i+1} to `${left_type_sym.name}.$method_name`',
					call_expr.pos)
			}
		}
		// TODO: typ optimize.. this node can get processed more than once
		if call_expr.expected_arg_types.len == 0 {
			for i in 1 .. method.args.len {
				call_expr.expected_arg_types << method.args[i].typ
			}
		}
		call_expr.receiver_type = method.args[0].typ
		call_expr.return_type = method.return_type
		return method.return_type
	}
	// TODO: str methods
	if method_name == 'str' {
		call_expr.receiver_type = left_type
		call_expr.return_type = table.string_type
		return table.string_type
	}
	// call struct field fn type
	// TODO: can we use SelectorExpr for all? this dosent really belong here
	if field := c.table.struct_find_field(left_type_sym, method_name) {
		field_type_sym := c.table.get_type_symbol(field.typ)
		if field_type_sym.kind == .function {
			call_expr.is_method = false
			info := field_type_sym.info as table.FnType
			call_expr.return_type = info.func.return_type
			// TODO: check args (do it once for all of the above)
			for arg in call_expr.args {
				c.expr(arg.expr)
			}
			return info.func.return_type
		}
	}
	c.error('unknown method: `${left_type_sym.name}.$method_name`', call_expr.pos)
	return table.void_type
}

pub fn (mut c Checker) call_fn(mut call_expr ast.CallExpr) table.Type {
	if call_expr.name == 'panic' {
		c.returns = true
	}
	fn_name := call_expr.name
	if fn_name == 'main' {
		c.error('the `main` function cannot be called in the program', call_expr.pos)
	}
	if fn_name == 'typeof' {
		// TODO: impl typeof properly (probably not going to be a fn call)
		return table.string_type
	}
	// if c.fileis('json_test.v') {
	// println(fn_name)
	// }
	if fn_name == 'json.encode' {
	} else if fn_name == 'json.decode' {
		expr := call_expr.args[0].expr
		if !(expr is ast.Type) {
			typ := typeof(expr)
			c.error('json.decode: first argument needs to be a type, got `$typ`', call_expr.pos)
			return table.void_type
		}
		c.expected_type = table.string_type
		call_expr.args[1].typ = c.expr(call_expr.args[1].expr)
		if call_expr.args[1].typ != table.string_type {
			c.error('json.decode: second argument needs to be a string', call_expr.pos)
		}
		typ := expr as ast.Type
		return typ.typ.set_flag(.optional)
	}
	// look for function in format `mod.fn` or `fn` (main/builtin)
	mut f := table.Fn{}
	mut found := false
	mut found_in_args := false
	// try prefix with current module as it would have never gotten prefixed
	if !fn_name.contains('.') && call_expr.mod !in ['builtin', 'main'] {
		name_prefixed := '${call_expr.mod}.$fn_name'
		if f1 := c.table.find_fn(name_prefixed) {
			call_expr.name = name_prefixed
			found = true
			f = f1
		}
	}
	// already prefixed (mod.fn) or C/builtin/main
	if !found {
		if f1 := c.table.find_fn(fn_name) {
			found = true
			f = f1
		}
	}
	// check for arg (var) of fn type
	if !found {
		scope := c.file.scope.innermost(call_expr.pos.pos)
		if v := scope.find_var(fn_name) {
			if v.typ != 0 {
				vts := c.table.get_type_symbol(v.typ)
				if vts.kind == .function {
					info := vts.info as table.FnType
					f = info.func
					found = true
					found_in_args = true
				}
			}
		}
	}
	if !found {
		c.error('unknown function: $fn_name', call_expr.pos)
		return table.void_type
	}
	if !found_in_args && call_expr.mod in ['builtin', 'main'] {
		scope := c.file.scope.innermost(call_expr.pos.pos)
		if _ := scope.find_var(fn_name) {
			c.error('ambiguous call to: `$fn_name`, may refer to fn `$fn_name` or variable `$fn_name`',
				call_expr.pos)
		}
	}
	call_expr.return_type = f.return_type
	if f.return_type == table.void_type && f.ctdefine.len > 0 && f.ctdefine !in c.pref.compile_defines {
		call_expr.should_be_skipped = true
	}
	if f.is_c || call_expr.is_c || f.is_js || call_expr.is_js {
		for arg in call_expr.args {
			c.expr(arg.expr)
		}
		return f.return_type
	}
	min_required_args := if f.is_variadic { f.args.len - 1 } else { f.args.len }
	if call_expr.args.len < min_required_args {
		c.error('too few arguments in call to `$fn_name` ($call_expr.args.len instead of $min_required_args)',
			call_expr.pos)
	} else if !f.is_variadic && call_expr.args.len > f.args.len {
		c.error('too many arguments in call to `$fn_name` ($call_expr.args.len instead of $f.args.len)',
			call_expr.pos)
		return f.return_type
	}
	// println can print anything
	if (fn_name == 'println' || fn_name == 'print') && call_expr.args.len > 0 {
		c.expected_type = table.string_type
		call_expr.args[0].typ = c.expr(call_expr.args[0].expr)
		/*
		// TODO: optimize `struct T{} fn (t &T) str() string {return 'abc'} mut a := []&T{} a << &T{} println(a[0])`
		// It currently generates:
		// `println(T_str_no_ptr(*(*(T**)array_get(a, 0))));`
		// ... which works, but could be just:
		// `println(T_str(*(T**)array_get(a, 0)));`
		prexpr := call_expr.args[0].expr
		prtyp := call_expr.args[0].typ
		prtyp_sym := c.table.get_type_symbol(prtyp)
		prtyp_is_ptr := prtyp.is_ptr()
		prhas_str, prexpects_ptr, prnr_args := prtyp_sym.str_method_info()
		eprintln('>>> println hack typ: ${prtyp} | sym.name: ${prtyp_sym.name} | is_ptr: $prtyp_is_ptr | has_str: $prhas_str | expects_ptr: $prexpects_ptr | nr_args: $prnr_args | expr: ${prexpr.str()} ')
		*/
		return f.return_type
	}
	// TODO: typ optimize.. this node can get processed more than once
	if call_expr.expected_arg_types.len == 0 {
		for arg in f.args {
			call_expr.expected_arg_types << arg.typ
		}
	}
	for i, call_arg in call_expr.args {
		arg := if f.is_variadic && i >= f.args.len - 1 { f.args[f.args.len - 1] } else { f.args[i] }
		c.expected_type = arg.typ
		typ := c.expr(call_arg.expr)
		call_expr.args[i].typ = typ
		typ_sym := c.table.get_type_symbol(typ)
		arg_typ_sym := c.table.get_type_symbol(arg.typ)
		if f.is_variadic && typ.flag_is(.variadic) && call_expr.args.len - 1 > i {
			c.error('when forwarding a varg variable, it must be the final argument', call_expr.pos)
		}
		// Handle expected interface
		if arg_typ_sym.kind == .interface_ {
			c.type_implements(typ, arg.typ, call_arg.expr.position())
			continue
		}
		// Handle expected interface array
		/*
		if exp_type_sym.kind == .array && t.get_type_symbol(t.value_type(exp_idx)).kind == .interface_ {
			return true
		}
		*/
		if !c.table.check(typ, arg.typ) {
			// str method, allow type with str method if fn arg is string
			if arg_typ_sym.kind == .string && typ_sym.has_method('str') {
				continue
			}
			if typ_sym.kind == .void && arg_typ_sym.kind == .string {
				continue
			}
			if f.is_generic {
				continue
			}
			if typ_sym.kind == .array_fixed {
			}
			c.error('cannot use type `$typ_sym.str()` as type `$arg_typ_sym.str()` in argument ${i+1} to `$fn_name`',
				call_expr.pos)
		}
	}
	return f.return_type
}

fn (mut c Checker) type_implements(typ, inter_typ table.Type, pos token.Position) {
	typ_sym := c.table.get_type_symbol(typ)
	inter_sym := c.table.get_type_symbol(inter_typ)
	styp := c.table.type_to_str(typ)
	for imethod in inter_sym.methods {
		if method := typ_sym.find_method(imethod.name) {
			if !imethod.is_same_method_as(method) {
				c.error('`$styp` incorrectly implements method `$imethod.name` of interface `$inter_sym.name`, expected `${c.table.fn_to_str(imethod)}`',
					pos)
			}
			continue
		}
		c.error("`$styp` doesn't implement method `$imethod.name`", pos)
	}
	mut inter_info := inter_sym.info as table.Interface
	if typ !in inter_info.types && typ_sym.kind != .interface_ {
		inter_info.types << typ
	}
}

pub fn (mut c Checker) check_expr_opt_call(x ast.Expr, xtype table.Type, is_return_used bool) {
	match x {
		ast.CallExpr {
			if it.return_type.flag_is(.optional) {
				c.check_or_block(it, xtype, is_return_used)
			} else if it.or_block.is_used && it.name != 'json.decode' { // TODO remove decode hack
				c.error('unexpected `or` block, the function `$it.name` does not return an optional',
					it.pos)
			}
		}
		else {}
	}
}

pub fn (mut c Checker) check_or_block(mut call_expr ast.CallExpr, ret_type table.Type, is_ret_used bool) {
	if !call_expr.or_block.is_used {
		c.error('${call_expr.name}() returns an option, but you missed to add an `or {}` block to it',
			call_expr.pos)
		return
	}
	stmts_len := call_expr.or_block.stmts.len
	if stmts_len == 0 {
		if is_ret_used {
			// x := f() or {}
			c.error('assignment requires a non empty `or {}` block', call_expr.pos)
			return
		}
		// allow `f() or {}`
		return
	}
	last_stmt := call_expr.or_block.stmts[stmts_len - 1]
	if is_ret_used {
		if !c.is_last_or_block_stmt_valid(last_stmt) {
			expected_type_name := c.table.get_type_symbol(ret_type).name
			c.error('last statement in the `or {}` block should return `$expected_type_name`',
				call_expr.pos)
			return
		}
		match last_stmt {
			ast.ExprStmt {
				type_fits := c.table.check(c.expr(it.expr), ret_type)
				is_panic_or_exit := is_expr_panic_or_exit(it.expr)
				if type_fits || is_panic_or_exit {
					return
				}
				type_name := c.table.get_type_symbol(c.expr(it.expr)).name
				expected_type_name := c.table.get_type_symbol(ret_type).name
				c.error('wrong return type `$type_name` in the `or {}` block, expected `$expected_type_name`',
					it.pos)
				return
			}
			ast.BranchStmt {
				if it.tok.kind !in [.key_continue, .key_break] {
					c.error('only break/continue is allowed as a branch statement in the end of an `or {}` block',
						it.tok.position())
					return
				}
			}
			else {}
		}
		return
	}
}

fn is_expr_panic_or_exit(expr ast.Expr) bool {
	match expr {
		ast.CallExpr { return it.name in ['panic', 'exit'] }
		else { return false }
	}
}

// TODO: merge to check_or_block when v can handle it
pub fn (mut c Checker) is_last_or_block_stmt_valid(stmt ast.Stmt) bool {
	return match stmt {
		ast.Return { true }
		ast.BranchStmt { true }
		ast.ExprStmt { true }
		else { false }
	}
}

pub fn (mut c Checker) selector_expr(mut selector_expr ast.SelectorExpr) table.Type {
	typ := c.expr(selector_expr.expr)
	if typ == table.void_type_idx {
		c.error('unknown selector expression', selector_expr.pos)
		return table.void_type
	}
	selector_expr.expr_type = typ
	// println('sel expr line_nr=$selector_expr.pos.line_nr typ=$selector_expr.expr_type')
	typ_sym := c.table.get_type_symbol(typ)
	field_name := selector_expr.field_name
	// variadic
	if typ.flag_is(.variadic) {
		if field_name == 'len' {
			return table.int_type
		}
	}
	if field := c.table.struct_find_field(typ_sym, field_name) {
		if typ_sym.mod != c.mod && !field.is_pub {
			c.error('field `${typ_sym.name}.$field_name` is not public', selector_expr.pos)
		}
		return field.typ
	}
	if typ_sym.kind != .struct_ {
		c.error('`$typ_sym.name` is not a struct', selector_expr.pos)
	} else {
		c.error('unknown field `${typ_sym.name}.$field_name`', selector_expr.pos)
	}
	return table.void_type
}

// TODO: non deferred
pub fn (mut c Checker) return_stmt(mut return_stmt ast.Return) {
	c.expected_type = c.fn_return_type
	if return_stmt.exprs.len > 0 && c.fn_return_type == table.void_type {
		c.error('too many arguments to return, current function does not return anything',
			return_stmt.pos)
		return
	} else if return_stmt.exprs.len == 0 && c.fn_return_type != table.void_type {
		c.error('too few arguments to return', return_stmt.pos)
		return
	}
	if return_stmt.exprs.len == 0 {
		return
	}
	expected_type := c.fn_return_type
	expected_type_sym := c.table.get_type_symbol(expected_type)
	exp_is_optional := expected_type.flag_is(.optional)
	mut expected_types := [expected_type]
	if expected_type_sym.kind == .multi_return {
		mr_info := expected_type_sym.info as table.MultiReturn
		expected_types = mr_info.types
	}
	mut got_types := []table.Type{}
	for expr in return_stmt.exprs {
		typ := c.expr(expr)
		got_types << typ
	}
	return_stmt.types = got_types
	// allow `none` & `error (Option)` return types for function that returns optional
	if exp_is_optional && got_types[0].idx() in [table.none_type_idx, c.table.type_idxs['Option']] {
		return
	}
	if expected_types.len > 0 && expected_types.len != got_types.len {
		// c.error('wrong number of return arguments:\n\texpected: $expected_table.str()\n\tgot: $got_types.str()', return_stmt.pos)
		c.error('wrong number of return arguments', return_stmt.pos)
	}
	for i, exp_typ in expected_types {
		got_typ := got_types[i]
		if !c.table.check(got_typ, exp_typ) {
			got_typ_sym := c.table.get_type_symbol(got_typ)
			exp_typ_sym := c.table.get_type_symbol(exp_typ)
			pos := return_stmt.exprs[i].position()
			c.error('cannot use `$got_typ_sym.name` as type `$exp_typ_sym.name` in return argument',
				pos)
		}
	}
}

pub fn (mut c Checker) enum_decl(decl ast.EnumDecl) {
	for i, field in decl.fields {
		for j in 0 .. i {
			if field.name == decl.fields[j].name {
				c.error('field name `$field.name` duplicate', field.pos)
			}
		}
		if field.has_expr {
			match field.expr {
				ast.IntegerLiteral {}
				ast.PrefixExpr {}
				else {
					if field.expr is ast.Ident {
						expr := field.expr as ast.Ident
						if expr.is_c {
							continue
						}
					}
					mut pos := field.expr.position()
					if pos.pos == 0 {
						pos = field.pos
					}
					c.error('default value for enum has to be an integer', pos)
				}
			}
		}
	}
}

pub fn (mut c Checker) assign_stmt(mut assign_stmt ast.AssignStmt) {
	c.expected_type = table.none_type // TODO a hack to make `x := if ... work`
	right_first := assign_stmt.right[0]
	mut right_len := assign_stmt.right.len
	if right_first is ast.CallExpr || right_first is ast.IfExpr || right_first is ast.MatchExpr {
		right_type0 := c.expr(assign_stmt.right[0])
		assign_stmt.right_types = [right_type0]
		right_type_sym0 := c.table.get_type_symbol(right_type0)
		right_len = if right_type0 == table.void_type {
			0
		} else {
			right_len
		}
		if right_type_sym0.kind == .multi_return {
			assign_stmt.right_types = right_type_sym0.mr_info().types
			right_len = assign_stmt.right_types.len
		}
		if assign_stmt.left.len != right_len {
			if right_first is ast.CallExpr {
				call_expr := assign_stmt.right[0] as ast.CallExpr
				c.error('assignment mismatch: $assign_stmt.left.len variable(s) but `${call_expr.name}()` returns $right_len value(s)',
					assign_stmt.pos)
				return
			} else {
				c.error('assignment mismatch: $assign_stmt.left.len variable(s) $right_len value(s)',
					assign_stmt.pos)
				return
			}
		}
	} else if assign_stmt.left.len != right_len {
		c.error('assignment mismatch: $assign_stmt.left.len variable(s) $assign_stmt.right.len value(s)',
			assign_stmt.pos)
		return
	}
	mut scope := c.file.scope.innermost(assign_stmt.pos.pos)
	for i, _ in assign_stmt.left {
		mut ident := assign_stmt.left[i]
		if assign_stmt.right_types.len < right_len {
			assign_stmt.right_types << c.expr(assign_stmt.right[i])
		}
		val_type := assign_stmt.right_types[i]
		// check variable name for beginning with capital letter 'Abc'
		is_decl := assign_stmt.op == .decl_assign
		if is_decl && util.contains_capital(ident.name) {
			c.error('variable names cannot contain uppercase letters, use snake_case instead',
				ident.pos)
		} else if is_decl && ident.kind != .blank_ident {
			if ident.name.starts_with('__') {
				c.error('variable names cannot start with `__`', ident.pos)
			}
		}
		if assign_stmt.op == .decl_assign {
			c.var_decl_name = ident.name
		}
		mut ident_var_info := ident.var_info()
		// c.assigned_var_name = ident.name
		if assign_stmt.op == .assign {
			var_type := c.expr(ident)
			assign_stmt.left_types << var_type
			if !c.table.check(val_type, var_type) {
				val_type_sym := c.table.get_type_symbol(val_type)
				var_type_sym := c.table.get_type_symbol(var_type)
				c.error('assign stmt: cannot use `$val_type_sym.name` as `$var_type_sym.name`',
					assign_stmt.pos)
			}
		}
		ident_var_info.typ = val_type
		ident.info = ident_var_info
		assign_stmt.left[i] = ident
		scope.update_var_type(ident.name, val_type)
		if i < assign_stmt.right.len { // only once for multi return
			c.check_expr_opt_call(assign_stmt.right[i], assign_stmt.right_types[i], true)
		}
	}
	c.var_decl_name = ''
	c.expected_type = table.void_type
	// c.assigned_var_name = ''
}

pub fn (mut c Checker) array_init(mut array_init ast.ArrayInit) table.Type {
	// println('checker: array init $array_init.pos.line_nr $c.file.path')
	mut elem_type := table.void_type
	// []string - was set in parser
	if array_init.typ != table.void_type {
		if array_init.exprs.len == 0 {
			if array_init.has_cap {
				if c.expr(array_init.cap_expr) != table.int_type {
					c.error('array cap needs to be an int', array_init.pos)
				}
			}
			if array_init.has_len {
				if c.expr(array_init.len_expr) != table.int_type {
					c.error('array len needs to be an int', array_init.pos)
				}
			}
		}
		return array_init.typ
	}
	// a = []
	if array_init.exprs.len == 0 {
		if array_init.has_cap {
			if c.expr(array_init.cap_expr) != table.int_type {
				c.error('array cap needs to be an int', array_init.pos)
			}
		}
		if array_init.has_len {
			if c.expr(array_init.len_expr) != table.int_type {
				c.error('array len needs to be an int', array_init.pos)
			}
		}
		type_sym := c.table.get_type_symbol(c.expected_type)
		if type_sym.kind != .array {
			c.error('array_init: no type specified (maybe: `[]Type{}` instead of `[]`)', array_init.pos)
			return table.void_type
		}
		// TODO: seperate errors once bug is fixed with `x := if expr { ... } else { ... }`
		// if c.expected_type == table.void_type {
		// c.error('array_init: use `[]Type{}` instead of `[]`', array_init.pos)
		// return table.void_type
		// }
		array_info := type_sym.array_info()
		array_init.elem_type = array_info.elem_type
		return c.expected_type
	}
	// [1,2,3]
	if array_init.exprs.len > 0 && array_init.elem_type == table.void_type {
		mut expected_value_type := table.void_type
		mut expecting_interface_array := false
		cap := array_init.exprs.len
		mut interface_types := []table.Type{cap: cap}
		if c.expected_type != 0 {
			expected_value_type = c.table.value_type(c.expected_type)
			if c.table.get_type_symbol(expected_value_type).kind == .interface_ {
				// Array of interfaces? (`[dog, cat]`) Save the interface type (`Animal`)
				expecting_interface_array = true
				array_init.interface_type = expected_value_type
				array_init.is_interface = true
			}
		}
		// expecting_interface_array := c.expected_type != 0 &&
		// c.table.get_type_symbol(c.table.value_type(c.expected_type)).kind ==			.interface_
		//
		// if expecting_interface_array {
		// println('ex $c.expected_type')
		// }
		for i, expr in array_init.exprs {
			typ := c.expr(expr)
			if expecting_interface_array {
				if i == 0 {
					elem_type = expected_value_type
					c.expected_type = elem_type
				}
				interface_types << typ
				continue
			}
			// The first element's type
			if i == 0 {
				elem_type = typ
				c.expected_type = typ
				continue
			}
			if !c.table.check(elem_type, typ) {
				elem_type_sym := c.table.get_type_symbol(elem_type)
				c.error('expected array element with type `$elem_type_sym.name`', array_init.pos)
			}
		}
		if expecting_interface_array {
			array_init.interface_types = interface_types
		}
		if array_init.is_fixed {
			idx := c.table.find_or_register_array_fixed(elem_type, array_init.exprs.len, 1)
			array_init.typ = table.new_type(idx)
		} else {
			idx := c.table.find_or_register_array(elem_type, 1)
			array_init.typ = table.new_type(idx)
		}
		array_init.elem_type = elem_type
	} else if array_init.is_fixed && array_init.exprs.len == 1 && array_init.elem_type != table.void_type {
		// [50]byte
		mut fixed_size := 1
		match array_init.exprs[0] {
			ast.IntegerLiteral {
				fixed_size = it.val.int()
			}
			ast.Ident {
				// if obj := c.file.global_scope.find_const(it.name) {
				// if  obj := scope.find(it.name) {
				// scope := c.file.scope.innermost(array_init.pos.pos)
				// eprintln('scope: ${scope.str()}')
				// scope.find(it.name) or {
				// c.error('undefined: `$it.name`', array_init.pos)
				// }
				mut full_const_name := if it.mod == 'main' { it.name } else { it.mod + '.' +
						it.name }
				if obj := c.file.global_scope.find_const(full_const_name) {
					if cint := const_int_value(obj) {
						fixed_size = cint
					}
				} else {
					c.error('non existant integer const $full_const_name while initializing the size of a static array',
						array_init.pos)
				}
			}
			else {
				c.error('expecting `int` for fixed size', array_init.pos)
			}
		}
		idx := c.table.find_or_register_array_fixed(array_init.elem_type, fixed_size, 1)
		array_type := table.new_type(idx)
		array_init.typ = array_type
	}
	return array_init.typ
}

fn const_int_value(cfield ast.ConstField) ?int {
	if cint := is_const_integer(cfield) {
		return cint.val.int()
	}
	return none
}

fn is_const_integer(cfield ast.ConstField) ?ast.IntegerLiteral {
	match cfield.expr {
		ast.IntegerLiteral { return it }
		else {}
	}
	return none
}

fn (mut c Checker) stmt(node ast.Stmt) {
	// c.expected_type = table.void_type
	match mut node {
		ast.AssertStmt {
			assert_type := c.expr(it.expr)
			if assert_type != table.bool_type_idx {
				atype_name := c.table.get_type_symbol(assert_type).name
				c.error('assert can be used only with `bool` expressions, but found `${atype_name}` instead',
					it.pos)
			}
		}
		// ast.Attr {}
		ast.AssignStmt {
			c.assign_stmt(mut it)
		}
		ast.Block {
			c.stmts(it.stmts)
		}
		ast.BranchStmt {
			if c.in_for_count == 0 {
				c.error('$it.tok.lit statement not within a loop', it.tok.position())
			}
		}
		ast.CompIf {
			// c.expr(it.cond)
			c.stmts(it.stmts)
			if it.has_else {
				c.stmts(it.else_stmts)
			}
		}
		ast.ConstDecl {
			mut field_names := []string{}
			mut field_order := []int{}
			for i, field in it.fields {
				if field.name in c.const_names {
					c.error('field name `$field.name` duplicate', field.pos)
				}
				c.const_names << field.name
				field_names << field.name
				field_order << i
			}
			mut needs_order := false
			mut done_fields := []int{}
			for i, field in it.fields {
				c.const_decl = field.name
				c.const_deps << field.name
				typ := c.expr(field.expr)
				it.fields[i].typ = typ
				for cd in c.const_deps {
					for j, f in it.fields {
						if j != i && cd in field_names && cd == f.name && j !in done_fields {
							needs_order = true
							x := field_order[j]
							field_order[j] = field_order[i]
							field_order[i] = x
							break
						}
					}
				}
				done_fields << i
				c.const_deps = []
			}
			if needs_order {
				mut ordered_fields := []ast.ConstField{}
				for order in field_order {
					ordered_fields << it.fields[order]
				}
				it.fields = ordered_fields
			}
		}
		ast.DeferStmt {
			c.stmts(it.stmts)
		}
		ast.EnumDecl {
			c.enum_decl(it)
		}
		ast.ExprStmt {
			etype := c.expr(it.expr)
			c.expected_type = table.void_type
			c.check_expr_opt_call(it.expr, etype, false)
		}
		ast.FnDecl {
			if it.is_method {
				sym := c.table.get_type_symbol(it.receiver.typ)
				if sym.kind == .interface_ {
					c.error('interfaces cannot be used as method receiver', it.receiver_pos)
				}
				// if sym.has_method(it.name) {
				// c.warn('duplicate method `$it.name`', it.pos)
				// }
			}
			if !it.is_c {
				// Make sure all types are valid
				for arg in it.args {
					sym := c.table.get_type_symbol(arg.typ)
					if sym.kind == .placeholder {
						c.error('unknown type `$sym.name`', it.pos)
					}
				}
			}
			c.expected_type = table.void_type
			c.fn_return_type = it.return_type
			c.stmts(it.stmts)
			if !it.is_c && !it.is_js && !it.no_body && it.return_type != table.void_type &&
				!c.returns && it.name !in ['panic', 'exit'] {
				c.error('missing return at end of function `$it.name`', it.pos)
			}
			c.returns = false
		}
		ast.ForCStmt {
			c.in_for_count++
			c.stmt(it.init)
			c.expr(it.cond)
			// c.stmt(it.inc)
			c.expr(it.inc)
			c.stmts(it.stmts)
			c.in_for_count--
		}
		ast.ForInStmt {
			c.in_for_count++
			typ := c.expr(it.cond)
			typ_idx := typ.idx()
			if it.is_range {
				high_type_idx := c.expr(it.high).idx()
				if typ_idx in table.integer_type_idxs && high_type_idx !in table.integer_type_idxs {
					c.error('range types do not match', it.cond.position())
				} else if typ_idx in table.float_type_idxs || high_type_idx in table.float_type_idxs {
					c.error('range type can not be float', it.cond.position())
				} else if typ_idx == table.bool_type_idx || high_type_idx == table.bool_type_idx {
					c.error('range type can not be bool', it.cond.position())
				} else if typ_idx == table.string_type_idx || high_type_idx == table.string_type_idx {
					c.error('range type can not be string', it.cond.position())
				}
				c.expr(it.high)
			} else {
				mut scope := c.file.scope.innermost(it.pos.pos)
				sym := c.table.get_type_symbol(typ)
				if sym.kind == .map && !(it.key_var.len > 0 && it.val_var.len > 0) {
					c.error('for in: cannot use one variable in map', it.pos)
				}
				if it.key_var.len > 0 {
					key_type := match sym.kind {
						.map { sym.map_info().key_type }
						else { table.int_type }
					}
					it.key_type = key_type
					scope.update_var_type(it.key_var, key_type)
				}
				value_type := c.table.value_type(typ)
				if value_type == table.void_type {
					typ_sym := c.table.get_type_symbol(typ)
					c.error('for in: cannot index `$typ_sym.name`', it.cond.position())
				}
				it.cond_type = typ
				it.kind = sym.kind
				it.val_type = value_type
				scope.update_var_type(it.val_var, value_type)
			}
			c.stmts(it.stmts)
			c.in_for_count--
		}
		ast.ForStmt {
			c.in_for_count++
			typ := c.expr(it.cond)
			if !it.is_inf && typ.idx() != table.bool_type_idx {
				c.error('non-bool used as for condition', it.pos)
			}
			// TODO: update loop var type
			// how does this work currenly?
			c.stmts(it.stmts)
			c.in_for_count--
		}
		// ast.GlobalDecl {}
		ast.GoStmt {
			if !(it.call_expr is ast.CallExpr) {
				c.error('expression in `go` must be a function call', it.call_expr.position())
			}
			c.expr(it.call_expr)
		}
		// ast.HashStmt {}
		ast.Import {}
		ast.InterfaceDecl {
			name := it.name.after('.')
			if !name[0].is_capital() {
				pos := token.Position{
					line_nr: it.pos.line_nr
					pos: it.pos.pos + 'interface'.len
					len: name.len
				}
				c.error('interface name must begin with capital letter', pos)
			}
		}
		ast.Module {
			c.mod = it.name
			c.is_builtin_mod = it.name == 'builtin'
		}
		ast.Return {
			c.returns = true
			c.return_stmt(mut it)
			c.scope_returns = true
		}
		ast.StructDecl {
			c.struct_decl(it)
		}
		ast.TypeDecl {
			c.type_decl(it)
		}
		ast.UnsafeStmt {
			c.inside_unsafe = true
			c.stmts(it.stmts)
			c.inside_unsafe = false
		}
		else {
			// println('checker.stmt(): unhandled node')
			// println('checker.stmt(): unhandled node (${typeof(node)})')
		}
	}
}

fn (mut c Checker) stmts(stmts []ast.Stmt) {
	mut unreachable := token.Position{
		line_nr: -1
	}
	c.expected_type = table.void_type
	for stmt in stmts {
		if c.scope_returns {
			if unreachable.line_nr == -1 {
				unreachable = stmt.position()
			}
		}
		c.stmt(stmt)
	}
	if unreachable.line_nr >= 0 {
		c.warn('unreachable code', unreachable)
	}
	c.scope_returns = false
	c.expected_type = table.void_type
}

pub fn (mut c Checker) expr(node ast.Expr) table.Type {
	match mut node {
		ast.AnonFn {
			keep_ret_type := c.fn_return_type
			c.fn_return_type = it.decl.return_type
			c.stmts(it.decl.stmts)
			c.fn_return_type = keep_ret_type
			return it.typ
		}
		ast.ArrayInit {
			return c.array_init(mut it)
		}
		ast.AsCast {
			it.expr_type = c.expr(it.expr)
			expr_type_sym := c.table.get_type_symbol(it.expr_type)
			type_sym := c.table.get_type_symbol(it.typ)
			if expr_type_sym.kind == .sum_type {
				info := expr_type_sym.info as table.SumType
				if it.typ !in info.variants {
					c.error('cannot cast `$expr_type_sym.name` to `$type_sym.name`', it.pos)
					// c.error('only $info.variants can be casted to `$typ`', it.pos)
				}
			} else {
				//
				c.error('cannot cast non sum type `$type_sym.name` using `as`', it.pos)
			}
			return it.typ.to_ptr()
			// return it.typ
		}
		ast.AssignExpr {
			c.assign_expr(mut it)
		}
		ast.Assoc {
			scope := c.file.scope.innermost(it.pos.pos)
			v := scope.find_var(it.var_name) or {
				panic(err)
			}
			for i, _ in it.fields {
				c.expr(it.exprs[i])
			}
			it.typ = v.typ
			return v.typ
		}
		ast.BoolLiteral {
			return table.bool_type
		}
		ast.CastExpr {
			it.expr_type = c.expr(it.expr)
			sym := c.table.get_type_symbol(it.expr_type)
			if it.typ == table.string_type && !(sym.kind in [.byte, .byteptr] || sym.kind ==
				.array && sym.name == 'array_byte') {
				type_name := c.table.type_to_str(it.expr_type)
				c.error('cannot cast type `$type_name` to string, use `x.str()` instead', it.pos)
			}
			if it.has_arg {
				c.expr(it.arg)
			}
			it.typname = c.table.get_type_symbol(it.typ).name
			return it.typ
		}
		ast.CallExpr {
			return c.call_expr(mut it)
		}
		ast.CharLiteral {
			return table.byte_type
		}
		ast.ConcatExpr {
			return c.concat_expr(mut it)
		}
		ast.EnumVal {
			return c.enum_val(mut it)
		}
		ast.FloatLiteral {
			return table.f64_type
		}
		ast.Ident {
			// c.checked_ident = it.name
			res := c.ident(mut it)
			// c.checked_ident = ''
			return res
		}
		ast.IfExpr {
			return c.if_expr(mut it)
		}
		ast.IfGuardExpr {
			it.expr_type = c.expr(it.expr)
			return table.bool_type
		}
		ast.IndexExpr {
			return c.index_expr(mut it)
		}
		ast.InfixExpr {
			return c.infix_expr(mut it)
		}
		ast.IntegerLiteral {
			return table.int_type
		}
		ast.MapInit {
			return c.map_init(mut it)
		}
		ast.MatchExpr {
			return c.match_expr(mut it)
		}
		ast.PostfixExpr {
			return c.postfix_expr(it)
		}
		ast.PrefixExpr {
			right_type := c.expr(it.right)
			// TODO: testing ref/deref strategy
			if it.op == .amp && !right_type.is_ptr() {
				return right_type.to_ptr()
			}
			if it.op == .mul && right_type.is_ptr() {
				return right_type.deref()
			}
			if it.op == .not && right_type != table.bool_type_idx {
				c.error('! operator can only be used with bool types', it.pos)
			}
			return right_type
		}
		ast.None {
			return table.none_type
		}
		ast.ParExpr {
			return c.expr(it.expr)
		}
		ast.SelectorExpr {
			return c.selector_expr(mut it)
		}
		ast.SizeOf {
			return table.int_type
		}
		ast.StringLiteral {
			if it.is_c {
				return table.byteptr_type
			}
			return table.string_type
		}
		ast.StringInterLiteral {
			for expr in it.exprs {
				it.expr_types << c.expr(expr)
			}
			return table.string_type
		}
		ast.StructInit {
			return c.struct_init(mut it)
		}
		ast.Type {
			return it.typ
		}
		ast.TypeOf {
			it.expr_type = c.expr(it.expr)
			return table.string_type
		}
		else {
			tnode := typeof(node)
			if tnode != 'unknown v.ast.Expr' {
				println('checker.expr(): unhandled node with typeof(`${tnode}`)')
			}
		}
	}
	return table.void_type
}

pub fn (mut c Checker) ident(mut ident ast.Ident) table.Type {
	if ident.name == c.var_decl_name { // c.checked_ident {
		c.error('unresolved: `$ident.name`', ident.pos)
		return table.void_type
	}
	// TODO: move this
	if c.const_deps.len > 0 {
		mut name := ident.name
		if !name.contains('.') && ident.mod !in ['builtin', 'main'] {
			name = '${ident.mod}.$ident.name'
		}
		if name == c.const_decl {
			c.error('cycle in constant `$c.const_decl`', ident.pos)
			return table.void_type
		}
		c.const_deps << name
	}
	if ident.kind == .blank_ident {
		return table.void_type
	}
	// second use
	if ident.kind == .variable {
		info := ident.info as ast.IdentVar
		return info.typ
	} else if ident.kind == .constant {
		info := ident.info as ast.IdentVar
		return info.typ
	} else if ident.kind == .function {
		info := ident.info as ast.IdentFn
		return info.typ
	} else if ident.kind == .unresolved {
		// first use
		start_scope := c.file.scope.innermost(ident.pos.pos)
		if obj := start_scope.find(ident.name) {
			match obj {
				ast.Var {
					mut typ := it.typ
					if typ == 0 {
						typ = c.expr(it.expr)
					}
					is_optional := typ.flag_is(.optional)
					ident.kind = .variable
					ident.info = ast.IdentVar{
						typ: typ
						is_optional: is_optional
					}
					it.typ = typ
					// unwrap optional (`println(x)`)
					if is_optional {
						return typ.set_flag(.unset)
					}
					return typ
				}
				else {}
			}
		}
		// prepend mod to look for fn call or const
		mut name := ident.name
		if !name.contains('.') && ident.mod !in ['builtin', 'main'] {
			name = '${ident.mod}.$ident.name'
		}
		if obj := c.file.global_scope.find(name) {
			match obj {
				ast.GlobalDecl {
					ident.kind = .global
					ident.info = ast.IdentVar{
						typ: it.typ
					}
					return it.typ
				}
				ast.ConstField {
					mut typ := it.typ
					if typ == 0 {
						typ = c.expr(it.expr)
					}
					ident.name = name
					ident.kind = .constant
					ident.info = ast.IdentVar{
						typ: typ
					}
					it.typ = typ
					return typ
				}
				else {}
			}
		}
		// Non-anon-function object (not a call), e.g. `onclick(my_click)`
		if func := c.table.find_fn(name) {
			fn_type := table.new_type(c.table.find_or_register_fn_type(ident.mod, func, false,
				true))
			ident.name = name
			ident.kind = .function
			ident.info = ast.IdentFn{
				typ: fn_type
			}
			return fn_type
		}
	}
	if ident.is_c {
		return table.int_type
	}
	if ident.name != '_' {
		c.error('undefined: `$ident.name`', ident.pos)
	}
	if c.table.known_type(ident.name) {
		// e.g. `User`  in `json.decode(User, '...')`
		return table.void_type
	}
	return table.void_type
}

pub fn (mut c Checker) concat_expr(concat_expr mut ast.ConcatExpr) table.Type {
	mut mr_types := []table.Type{}
	for expr in concat_expr.vals {
		mr_types << c.expr(expr)
	}
	if concat_expr.vals.len == 1 {
		typ := mr_types[0]
		concat_expr.return_type = typ
		return typ
	} else {
		typ := c.table.find_or_register_multi_return(mr_types)
		table.new_type(typ)
		concat_expr.return_type = typ
		return typ
	}
}

pub fn (mut c Checker) match_expr(mut node ast.MatchExpr) table.Type {
	node.is_expr = c.expected_type != table.void_type
	node.expected_type = c.expected_type
	cond_type := c.expr(node.cond)
	if cond_type == 0 {
		c.error('match 0 cond type', node.pos)
	}
	type_sym := c.table.get_type_symbol(cond_type)
	if type_sym.kind != .sum_type {
		node.is_sum_type = false
	}
	c.match_exprs(mut node, type_sym)
	c.expected_type = cond_type
	mut ret_type := table.void_type
	for branch in node.branches {
		for expr in branch.exprs {
			c.expected_type = cond_type
			typ := c.expr(expr)
			typ_sym := c.table.get_type_symbol(typ)
			if !node.is_sum_type && !c.table.check(typ, cond_type) {
				exp_sym := c.table.get_type_symbol(cond_type)
				c.error('cannot use `$typ_sym.name` as `$exp_sym.name` in `match`', node.pos)
			}
			// TODO:
			if typ_sym.kind == .sum_type {
			}
		}
		c.stmts(branch.stmts)
		// If the last statement is an expression, return its type
		if branch.stmts.len > 0 {
			match branch.stmts[branch.stmts.len - 1] {
				ast.ExprStmt {
					ret_type = c.expr(it.expr)
				}
				else {
					// TODO: ask alex about this
					// typ := c.expr(it.expr)
					// type_sym := c.table.get_type_symbol(typ)
					// p.warn('match expr ret $type_sym.name')
					// node.typ = typ
					// return typ
				}
			}
		}
	}
	// if ret_type != table.void_type {
	// node.is_expr = c.expected_type != table.void_type
	// node.expected_type = c.expected_type
	// }
	node.return_type = ret_type
	node.cond_type = cond_type
	// println('!m $expr_type')
	return ret_type
}

fn (mut c Checker) match_exprs(mut node ast.MatchExpr, type_sym table.TypeSymbol) {
	// branch_exprs is a histogram of how many times
	// an expr was used in the match
	mut branch_exprs := map[string]int{}
	for branch in node.branches {
		for expr in branch.exprs {
			mut key := ''
			match expr {
				ast.Type { key = c.table.type_to_str(it.typ) }
				ast.EnumVal { key = it.val }
				else { key = expr.str() }
			}
			val := if key in branch_exprs { branch_exprs[key] } else { 0 }
			if val == 1 {
				c.error('match case `$key` is handled more than once', branch.pos)
			}
			branch_exprs[key] = val + 1
		}
	}
	// check that expressions are exhaustive
	// this is achieved either by putting an else
	// or, when the match is on a sum type or an enum
	// by listing all variants or values
	mut is_exhaustive := true
	mut unhandled := []string{}
	match type_sym.info {
		table.SumType { for v in it.variants {
				v_str := c.table.type_to_str(v)
				if v_str !in branch_exprs {
					is_exhaustive = false
					unhandled << '`$v_str`'
				}
			} }
		table.Enum { for v in it.vals {
				if v !in branch_exprs {
					is_exhaustive = false
					unhandled << '`.$v`'
				}
			} }
		else { is_exhaustive = false }
	}
	mut else_branch := node.branches[node.branches.len - 1]
	mut has_else := else_branch.is_else
	if !has_else {
		for i, branch in node.branches {
			if branch.is_else && i != node.branches.len - 1 {
				c.error('`else` must be the last branch of `match`', branch.pos)
				else_branch = branch
				has_else = true
			}
		}
	}
	if is_exhaustive {
		if has_else {
			c.error('match expression is exhaustive, `else` is unnecessary', else_branch.pos)
		}
		return
	}
	if has_else {
		return
	}
	mut err_details := 'match must be exhaustive'
	if unhandled.len > 0 {
		err_details += ' (add match branches for: ' + unhandled.join(', ') + ' or `else {}` at the end)'
	} else {
		err_details += ' (add `else {}` at the end)'
	}
	c.error(err_details, node.pos)
}

pub fn (mut c Checker) if_expr(mut node ast.IfExpr) table.Type {
	mut expr_required := false
	if c.expected_type != table.void_type {
		// | c.assigned_var_name != '' {
		// sym := c.table.get_type_symbol(c.expected_type)
		// println('$c.file.path  $node.pos.line_nr IF is expr: checker exp type = ' + sym.name)
		expr_required = true
	}
	former_expected_type := c.expected_type
	node.typ = table.void_type
	for i, branch in node.branches {
		if branch.cond is ast.ParExpr {
			c.error('unnecessary `()` in an if condition. use `if expr {` instead of `if (expr) {`.',
				branch.pos)
		}
		if !node.has_else || i < node.branches.len - 1 {
			// check condition type is boolean
			cond_typ := c.expr(branch.cond)
			if cond_typ.idx() != table.bool_type_idx {
				typ_sym := c.table.get_type_symbol(cond_typ)
				c.error('non-bool type `$typ_sym.name` used as if condition', branch.pos)
			}
		}
		c.stmts(branch.stmts)
		if expr_required {
			if branch.stmts.len > 0 && branch.stmts[branch.stmts.len - 1] is ast.ExprStmt {
				last_expr := branch.stmts[branch.stmts.len - 1] as ast.ExprStmt
				c.expected_type = former_expected_type
				expr_type := c.expr(last_expr.expr)
				if expr_type != node.typ {
					// first branch of if expression
					if node.typ == table.void_type {
						node.is_expr = true
						node.typ = expr_type
					} else {
						c.error('mismatched types `${c.table.type_to_str(node.typ)}` and `${c.table.type_to_str(expr_type)}`',
							node.pos)
					}
				}
			} else {
				c.error('`if` expression requires an expression as the last statement of every branch',
					branch.pos)
			}
		}
	}
	if expr_required {
		if !node.has_else {
			c.error('`if` expression needs `else` clause', node.pos)
		}
		return node.typ
	}
	return table.bool_type
}

pub fn (mut c Checker) postfix_expr(node ast.PostfixExpr) table.Type {
	typ := c.expr(node.expr)
	typ_sym := c.table.get_type_symbol(typ)
	// if !typ.is_number() {
	if !typ_sym.is_number() {
		println(typ_sym.kind.str())
		c.error('invalid operation: $node.op.str() (non-numeric type `$typ_sym.name`)', node.pos)
	} else {
		c.fail_if_immutable(node.expr)
	}
	return typ
}

pub fn (mut c Checker) index_expr(mut node ast.IndexExpr) table.Type {
	typ := c.expr(node.left)
	node.left_type = typ
	mut is_range := false // TODO is_range := node.index is ast.RangeExpr
	match node.index {
		ast.RangeExpr {
			is_range = true
			if it.has_low {
				c.expr(it.low)
			}
			if it.has_high {
				c.expr(it.high)
			}
		}
		else {}
	}
	typ_sym := c.table.get_type_symbol(typ)
	if !is_range {
		index_type := c.expr(node.index)
		index_type_sym := c.table.get_type_symbol(index_type)
		// println('index expr left=$typ_sym.name $node.pos.line_nr')
		// if typ_sym.kind == .array && (!(table.type_idx(index_type) in table.number_type_idxs) &&
		// index_type_sym.kind != .enum_) {
		if typ_sym.kind in [.array, .array_fixed] && !(index_type.is_number() || index_type_sym.kind ==
			.enum_) {
			c.error('non-integer index `$index_type_sym.name` (array type `$typ_sym.name`)',
				node.pos)
		} else if typ_sym.kind == .map && index_type.idx() != table.string_type_idx {
			c.error('non-string map index (map type `$typ_sym.name`)', node.pos)
		}
		value_type := c.table.value_type(typ)
		if value_type != table.void_type {
			return value_type
		}
	} else if is_range {
		// array[1..2] => array
		// fixed_array[1..2] => array
		if typ_sym.kind == .array_fixed {
			elem_type := c.table.value_type(typ)
			idx := c.table.find_or_register_array(elem_type, 1)
			return table.new_type(idx)
		}
	}
	return typ
}

// `.green` or `Color.green`
// If a short form is used, `expected_type` needs to be an enum
// with this value.
pub fn (mut c Checker) enum_val(mut node ast.EnumVal) table.Type {
	typ_idx := if node.enum_name == '' {
		c.expected_type.idx()
	} else { //
		c.table.find_type_idx(node.enum_name)
	}
	// println('checker: enum_val: $node.enum_name typeidx=$typ_idx')
	if typ_idx == 0 {
		c.error('not an enum (name=$node.enum_name) (type_idx=0)', node.pos)
		return table.void_type
	}
	typ := table.new_type(typ_idx)
	if typ == table.void_type {
		c.error('not an enum', node.pos)
		return table.void_type
	}
	typ_sym := c.table.get_type_symbol(typ)
	// println('tname=$typ_sym.name $node.pos.line_nr $c.file.path')
	if typ_sym.kind != .enum_ {
		c.error('not an enum', node.pos)
		return table.void_type
	}
	if !(typ_sym.info is table.Enum) {
		c.error('not an enum', node.pos)
		return table.void_type
	}
	// info := typ_sym.info as table.Enum
	info := typ_sym.enum_info()
	// rintln('checker: x = $info.x enum val $c.expected_type $typ_sym.name')
	// println(info.vals)
	if node.val !in info.vals {
		c.error('enum `$typ_sym.name` does not have a value `$node.val`', node.pos)
	}
	node.typ = typ
	return typ
}

pub fn (mut c Checker) map_init(mut node ast.MapInit) table.Type {
	// `x ;= map[string]string` - set in parser
	if node.typ != 0 {
		info := c.table.get_type_symbol(node.typ).map_info()
		node.key_type = info.key_type
		node.value_type = info.value_type
		return node.typ
	}
	// `{'age': 20}`
	key0_type := c.expr(node.keys[0])
	val0_type := c.expr(node.vals[0])
	for i, key in node.keys {
		key_i := key as ast.StringLiteral
		for j in 0 .. i {
			key_j := node.keys[j] as ast.StringLiteral
			if key_i.val == key_j.val {
				c.error('duplicate key "$key_i.val" in map literal', key.position())
			}
		}
		if i == 0 {
			continue
		}
		val := node.vals[i]
		key_type := c.expr(key)
		val_type := c.expr(val)
		if !c.table.check(key_type, key0_type) {
			key0_type_sym := c.table.get_type_symbol(key0_type)
			key_type_sym := c.table.get_type_symbol(key_type)
			c.error('map init: cannot use `$key_type_sym.name` as `$key0_type_sym.name` for map key',
				node.pos)
		}
		if !c.table.check(val_type, val0_type) {
			val0_type_sym := c.table.get_type_symbol(val0_type)
			val_type_sym := c.table.get_type_symbol(val_type)
			c.error('map init: cannot use `$val_type_sym.name` as `$val0_type_sym.name` for map value',
				node.pos)
		}
	}
	map_type := table.new_type(c.table.find_or_register_map(key0_type, val0_type))
	node.typ = map_type
	node.key_type = key0_type
	node.value_type = val0_type
	return map_type
}

pub fn (mut c Checker) warn(s string, pos token.Position) {
	allow_warnings := !c.pref.is_prod // allow warnings only in dev builds
	c.warn_or_error(s, pos, allow_warnings) // allow warnings only in dev builds
}

pub fn (mut c Checker) error(message string, pos token.Position) {
	if c.pref.is_verbose {
		print_backtrace()
	}
	c.warn_or_error(message, pos, false)
}

fn (mut c Checker) warn_or_error(message string, pos token.Position, warn bool) {
	// add backtrace to issue struct, how?
	// if c.pref.is_verbose {
	// print_backtrace()
	// }
	if warn {
		c.nr_warnings++
		wrn := errors.Warning{
			reporter: errors.Reporter.checker
			pos: pos
			file_path: c.file.path
			message: message
		}
		c.file.warnings << wrn
		c.warnings << wrn
	} else {
		c.nr_errors++
		if pos.line_nr !in c.error_lines {
			err := errors.Error{
				reporter: errors.Reporter.checker
				pos: pos
				file_path: c.file.path
				message: message
			}
			c.file.errors << err
			c.errors << err
			c.error_lines << pos.line_nr
		}
	}
}

// for debugging only
fn (c &Checker) fileis(s string) bool {
	return c.file.path.contains(s)
}

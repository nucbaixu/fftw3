(*
 * Copyright (c) 1997-1999 Massachusetts Institute of Technology
 * Copyright (c) 2003 Matteo Frigo
 * Copyright (c) 2003 Massachusetts Institute of Technology
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *
 *)
(* $Id: simd.ml,v 1.18 2005-02-11 02:47:38 athena Exp $ *)

open Expr
open List
open Printf
open Variable
open Annotate
open Simdmagic
open C

let realtype = "V"
let realtypep = realtype ^ " *"
let constrealtype = "const " ^ realtype
let constrealtypep = constrealtype ^ " *"
let ivs = ref "ivs"
let ovs = ref "ovs"
let alignment_mod = 2

(*
 * SIMD C AST unparser 
 *)
let foldr_string_concat l = fold_right (^) l ""

let rec unparse_by_twiddle nam tw src = 
  sprintf "%s(&(%s),%s)" nam (Variable.unparse tw) (unparse_expr src)

and unparse_store dst = function
  | Times (NaN PAIR1, x) ->
      sprintf "STPAIR1(&(%s),%s,%s,&(%s));\n" 
	(Variable.unparse dst) (unparse_expr x) !ovs
	(Variable.unparse_for_alignment alignment_mod dst)
  | Times (NaN PAIR2, Plus [even; odd]) ->
      sprintf "STPAIR2(&(%s),%s,%s,%s);\n" 
	(Variable.unparse dst) (unparse_expr even) (unparse_expr odd) !ovs
  | src_expr -> 
      sprintf "ST(&(%s),%s,%s,&(%s));\n" 
	(Variable.unparse dst) (unparse_expr src_expr) !ovs
	(Variable.unparse_for_alignment alignment_mod dst)

and unparse_expr =
  let rec unparse_plus = function
    | [a] -> unparse_expr a

    | (Uminus (Times (NaN I, b))) :: c :: d -> op2 "VFNMSI" [b] (c :: d)
    | c :: (Uminus (Times (NaN I, b))) :: d -> op2 "VFNMSI" [b] (c :: d)
    | (Times (NaN I, b)) :: (Uminus c) :: d -> failwith "VFMSI"
    | (Uminus c) :: (Times (NaN I, b)) :: d -> failwith "VFMSI"
    | (Times (NaN I, b)) :: c :: d -> op2 "VFMAI" [b] (c :: d)
    | c :: (Times (NaN I, b)) :: d -> op2 "VFMAI" [b] (c :: d)

    | (Uminus (Times (a, b))) :: c :: d when t a ->
	op3 "VFNMS" a b (c :: d)
    | c :: (Uminus (Times (a, b))) :: d when t a -> 
	op3 "VFNMS" a b (c :: d)
    | (Times (a, b)) :: (Uminus c) :: d when t a ->
        op3 "VFMS" a b (c :: negate d)
    | (Uminus c) :: (Times (a, b)) :: d when t a ->
        op3 "VFMS" a b (c :: negate d)
    | (Times (a, b)) :: c :: d when t a -> op3 "VFMA" a b (c :: d)
    | c :: (Times (a, b)) :: d when t a -> op3 "VFMA" a b (c :: d)

    | (Uminus a :: b)                   -> op2 "VSUB" b [a]
    | (b :: Uminus a :: c)              -> op2 "VSUB" (b :: c) [a]
    | (a :: b)                          -> op2 "VADD" [a] b
    | [] -> failwith "unparse_plus"
  and op3 nam a b c =
    nam ^ "(" ^ (unparse_expr a) ^ ", " ^ (unparse_expr b) ^ ", " ^
    (unparse_plus c) ^ ")"
  and op2 nam a b = 
    nam ^ "(" ^ (unparse_plus a) ^ ", " ^ (unparse_plus b) ^ ")"
  and op1 nam a = 
    nam ^ "(" ^ (unparse_expr a) ^ ")"
  and negate = function
    | [] -> []
    | (Uminus x) :: y -> x :: negate y
    | x :: y -> (Uminus x) :: negate y
  and t = function 
    | Num _ -> true 
    | _ -> false

  in function
    | Times(Times(NaN CPLX, Load tw), src) when Variable.is_constant tw ->
	unparse_by_twiddle "BYTW" tw src
    | Times(Times(NaN CPLXJ, Load tw), src) when Variable.is_constant tw ->
	unparse_by_twiddle "BYTWJ" tw src
    | Load v when is_locative(v) ->
	sprintf "LD(&(%s),%s,&(%s))" (Variable.unparse v) !ivs
	  (Variable.unparse_for_alignment alignment_mod v)
    | Load v  -> Variable.unparse v
    | Num n -> sprintf "LDK(%s)" (Number.to_konst n)
    | NaN n -> failwith "NaN in unparse_expr"
    | Plus [] -> "0.0 /* bug */"
    | Plus [a] -> " /* bug */ " ^ (unparse_expr a)
    | Plus a -> unparse_plus a
    | Times(NaN I,b) -> op1 "VBYI" b
    | Times(a,b) ->
	sprintf "VMUL(%s,%s)" (unparse_expr a) (unparse_expr b)
    | Uminus a when !Magic.vneg -> op1 "VNEG" a
    | Uminus a -> failwith "SIMD Uminus"
    | _ -> failwith "unparse_expr"

and unparse_decl x = C.unparse_decl x

and unparse_ast ast = 
  let rec unparse_assignment = function
    | Assign (v, x) when Variable.is_locative v ->
	unparse_store v x
    | Assign (v, x) -> 
	(Variable.unparse v) ^ " = " ^ (unparse_expr x) ^ ";\n"

  and unparse_annotated force_bracket = 
    let rec unparse_code = function
      | ADone -> ""
      | AInstr i -> unparse_assignment i
      | ASeq (a, b) -> 
	  (unparse_annotated false a) ^ (unparse_annotated false b)
    and declare_variables l = 
      let rec uvar = function
	  [] -> failwith "uvar"
	|	[v] -> (Variable.unparse v) ^ ";\n"
	| a :: b -> (Variable.unparse a) ^ ", " ^ (uvar b)
      in let rec vvar l = 
	let s = if !Magic.compact then 15 else 1 in
	if (List.length l <= s) then
	  match l with
	    [] -> ""
	  | _ -> realtype ^ " " ^ (uvar l)
	else
	  (vvar (Util.take s l)) ^ (vvar (Util.drop s l))
      in vvar (List.filter Variable.is_temporary l)
    in function
        Annotate (_, _, decl, _, code) ->
          if (not force_bracket) && (Util.null decl) then 
            unparse_code code
          else "{\n" ^
            (declare_variables decl) ^
            (unparse_code code) ^
	    "}\n"

(* ---- *)
  and unparse_plus = function
    | [] -> ""
    | (CUminus a :: b) -> " - " ^ (parenthesize a) ^ (unparse_plus b)
    | (a :: b) -> " + " ^ (parenthesize a) ^ (unparse_plus b)
  and parenthesize x = match x with
  | (CVar _) -> unparse_ast x
  | (CCall _) -> unparse_ast x
  | (Integer _) -> unparse_ast x
  | _ -> "(" ^ (unparse_ast x) ^ ")"

  in match ast with 
  | Asch a -> (unparse_annotated true a)
  | Return x -> "return " ^ unparse_ast x ^ ";"
  | For (a, b, c, d) ->
      "for (" ^
      unparse_ast a ^ "; " ^ unparse_ast b ^ "; " ^ unparse_ast c
      ^ ")" ^ unparse_ast d
  | If (a, d) ->
      "if (" ^
      unparse_ast a 
      ^ ")" ^ unparse_ast d
  | Block (d, s) ->
      if (s == []) then ""
      else 
        "{\n"                                      ^ 
        foldr_string_concat (map unparse_decl d)   ^ 
        foldr_string_concat (map unparse_ast s)    ^
        "}\n"      
  | x -> C.unparse_ast x

and unparse_function = function
    Fcn (typ, name, args, body) ->
      let rec unparse_args = function
          [Decl (a, b)] -> a ^ " " ^ b 
	| (Decl (a, b)) :: s -> a ^ " " ^ b  ^ ", "
            ^  unparse_args s
	| [] -> ""
	| _ -> failwith "unparse_function"
      in 
      (typ ^ " " ^ name ^ "(" ^ unparse_args args ^ ")\n" ^
       unparse_ast body)

let extract_constants f =
  let constlist = flatten (map expr_to_constants (C.ast_to_expr_list f))
  in map
    (fun n ->
      Tdecl 
	("DVK(" ^ (Number.to_konst n) ^ ", " ^ (Number.to_string n) ^ ")"))
    (unique_constants constlist)


(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*                     Pierre Chambart, OCamlPro                       *)
(*                                                                     *)
(*  Copyright 2014 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

open Symbol
open Abstract_identifiers
open Flambda

type tag = int

type descr =
  | Value_block of tag * approx array
  | Value_int of int
  | Value_constptr of int
  | Value_set_of_closures of value_closure
  | Value_closure of value_offset
  | Value_unknown
  | Value_bottom
  | Value_extern of Flambdaexport.ExportId.t
  | Value_symbol of Symbol.t

and value_offset =
  { fun_id : Closure_id.t;
    closure : value_closure }

and value_closure =
  { ffunctions : Expr_id.t function_declarations;
    bound_var : approx Var_within_closure.Map.t;
    kept_params : Variable.Set.t;
    ffunction_sb :
      Flambdasubst.Alpha_renaming_map_for_ids_and_bound_vars_of_closures.t;
  }

and approx =
  { descr : descr;
    var : Variable.t option;
    symbol : Symbol.t option }

let rec print_descr ppf = function
  | Value_int i -> Format.pp_print_int ppf i
  | Value_constptr i -> Format.fprintf ppf "%ia" i
  | Value_block (tag,fields) ->
    let p ppf fields =
      Array.iter (fun v -> Format.fprintf ppf "%a@ " print_approx v) fields in
    Format.fprintf ppf "[%i:@ @[<1>%a@]]" tag p fields
  | Value_unknown -> Format.fprintf ppf "?"
  | Value_bottom -> Format.fprintf ppf "bottom"
  | Value_extern id -> Format.fprintf ppf "_%a_" Flambdaexport.ExportId.print id
  | Value_symbol sym -> Format.fprintf ppf "%a" Symbol.print sym
  | Value_closure { fun_id } ->
    Format.fprintf ppf "(fun:@ %a)" Closure_id.print fun_id
  | Value_set_of_closures { ffunctions = { funs } } ->
    Format.fprintf ppf "(unoffseted:@ %a)"
      (fun ppf -> Variable.Map.iter (fun id _ -> Variable.print ppf id)) funs

and print_approx ppf { descr } = print_descr ppf descr

(** Smart constructors *)

let approx descr = { descr; var = None; symbol = None }

let value_unknown = approx Value_unknown
let value_int i = approx (Value_int i)
let value_constptr i = approx (Value_constptr i)
let value_closure c = approx (Value_closure c)
let value_unoffseted_closure c = approx (Value_set_of_closures c)
let value_block (t,b) = approx (Value_block (t,b))
let value_extern ex = approx (Value_extern ex)
let value_symbol sym = approx (Value_symbol sym)
let value_bottom = approx Value_bottom

let make_const_int n eid =
  Fconst(Fconst_base(Asttypes.Const_int n),eid), value_int n
let make_const_ptr n eid = Fconst(Fconst_pointer n,eid), value_constptr n
let make_const_bool b eid = make_const_ptr (if b then 1 else 0) eid

let const_approx = function
  | Fconst_base const ->
      let open Asttypes in
      begin match const with
      | Const_int i -> value_int i
      | Const_char c -> value_int (Char.code c)
      | Const_string _ -> value_unknown
      | Const_float  _ -> value_unknown
      | Const_int32  _ -> value_unknown
      | Const_int64  _ -> value_unknown
      | Const_nativeint  _ -> value_unknown
      end
  | Fconst_pointer i -> value_constptr i
  | Fconst_float_array _ -> value_unknown
  | Fconst_immstring _ -> value_unknown

let check_constant_result lam approx =
  let lam, approx =
    match approx.descr with
      Value_int n when Flambdaeffects.no_effects lam ->
        make_const_int n (data_at_toplevel_node lam)
    | Value_constptr n when Flambdaeffects.no_effects lam ->
        make_const_ptr n (data_at_toplevel_node lam)
    | Value_symbol sym when Flambdaeffects.no_effects lam ->
        Fsymbol(sym, data_at_toplevel_node lam), approx
    | _ -> lam, approx
  in
  lam, approx

let check_var_and_constant_result ~is_present_in_env lam approx =
  let res = match approx.var with
    | None ->
        lam
    | Some var ->
        if is_present_in_env var
        then Fvar(var, data_at_toplevel_node lam)
        else lam
  in
  check_constant_result res approx

let useful t =
  match t.descr with
  | Value_unknown | Value_bottom -> false
  | Value_block _ | Value_int _ | Value_constptr _ | Value_set_of_closures _
  | Value_closure _ | Value_extern _ | Value_symbol _ -> true

let get_field i = function
  | [{descr = Value_block (tag, fields)}] ->
      if i >= 0 && i < Array.length fields
      then fields.(i)
      else value_unknown
  | _ -> value_unknown

let descrs approxs = List.map (fun v -> v.descr) approxs

(** Import external approx *)

module Import = struct
  type t = approx
  open Flambdaexport
  let rec import_ex ex : t =

    ignore(Compilenv.approx_for_global (ExportId.unit ex));

    let ex_info = Compilenv.approx_env () in
    try match EidMap.find ex ex_info.ex_values with
      | Value_int i -> value_int i
      | Value_block (tag, fields) ->
          value_block (tag, Array.map import_approx fields)
      | Value_closure { fun_id; closure = { closure_id; bound_var } } ->
        let bound_var = Var_within_closure.Map.map import_approx bound_var in
        let kept_params =
          try Set_of_closures_id.Map.find closure_id ex_info.ex_kept_arguments with
          | Not_found -> assert false
        in
        value_closure
          { fun_id;
            closure =
              { ffunctions = Compilenv.imported_closure closure_id;
                bound_var;
                kept_params = kept_params;
                ffunction_sb =
                  Flambdasubst.
                  Alpha_renaming_map_for_ids_and_bound_vars_of_closures.empty;
              } }
      | Value_set_of_closures { closure_id; bound_var } ->
        let bound_var = Var_within_closure.Map.map import_approx bound_var in
        let kept_params =
          try Set_of_closures_id.Map.find closure_id ex_info.ex_kept_arguments with
          | Not_found -> assert false
        in
        value_unoffseted_closure
          { ffunctions = Compilenv.imported_closure closure_id;
            bound_var;
            kept_params = kept_params;
            ffunction_sb =
              Flambdasubst.
              Alpha_renaming_map_for_ids_and_bound_vars_of_closures.empty; }
      | _ ->
          value_unknown
    with Not_found ->
      value_unknown

  and import_approx (ap:Flambdaexport.approx) : t =
    match ap with
    | Value_unknown -> value_unknown
    | Value_id ex -> value_extern ex
    | Value_symbol sym -> value_symbol sym

  let import_symbol sym : t =
    if Compilenv.is_predefined_exception sym then
      value_unknown
    else
      let symbol_id_map =
        (Compilenv.approx_for_global sym.sym_unit).ex_symbol_id in
      try import_ex (SymbolMap.find sym symbol_id_map) with
      | Not_found ->
        value_unknown

  let rec really_import = function
    | Value_extern ex -> really_import_ex ex
    | Value_symbol sym -> really_import_symbol sym
    | r -> r

  and really_import_ex ex =
    really_import (import_ex ex).descr

  and really_import_symbol sym =
    really_import (import_symbol sym).descr

  let import_global id =
    let unit = Compilenv.unit_for_global id in
    import_approx
      (Ident.Map.find id (Compilenv.approx_for_global unit).ex_globals)

end

(* This file is part of DBL, released under MIT license.
 * See LICENSE for details.
 *)

(** Translation of names of named parameters *)

(* Author: Piotr Polesiuk, 2024 *)

open Common

let tr_name env (name : S.name) =
  match name with
  | NVar x      -> T.NVar x
  | NImplicit n -> T.NImplicit n

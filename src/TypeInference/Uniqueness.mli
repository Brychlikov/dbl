(* This file is part of DBL, released under MIT license.
 * See LICENSE for details.
 *)

(** Checking uniqueness of various mutual definitions *)

(* Author: Piotr Polesiuk, 2023,2024 *)

open Common

(** Ensure that each constructor in given ADT has a unique name *)
val check_ctor_uniqueness : S.ctor_decl list -> unit

(** Ensure that each named parameter is instantiated at most once *)
val check_inst_uniqueness : S.inst list -> unit

(** Ensure that each named pattern is defined at most once *)
val check_named_pattern_uniqueness : S.named_pattern list -> unit

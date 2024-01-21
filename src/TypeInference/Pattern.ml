(* This file is part of DBL, released under MIT license.
 * See LICENSE for details.
 *)

(** Type-inference for patterns *)

(* Author: Piotr Polesiuk, 2023,2024 *)

open Common

type named_pattern = (T.name * S.pattern) S.node

let tr_named_pattern env (np : S.named_pattern) =
  let (name, pat) = np.data in
  { np with data = (Name.tr_name env name, pat) }

(** Select named pattern for given name. On success returns pattern assigned
  to given name and list of remaining named patterns *)
let rec select_named_pattern name (nps : named_pattern list) =
  match nps with
  | [] -> None
  | { data = (n, p); _ } :: nps when n = name -> Some(p, nps)
  | np :: nps ->
    Option.map
      (fun (p, nps) -> (p, np :: nps))
      (select_named_pattern name nps)

let rec check_ctor_type_args ~env ~scope ~sub tvs =
  match tvs with
  | []        -> (env, scope, sub, [])
  | tv :: tvs ->
    let (env, a) = Env.add_anon_tvar env (T.TVar.kind tv) in
    let scope = T.Scope.add scope a in
    let sub   = T.Subst.rename_to_fresh sub tv a in
    let (env, scope, sub, tvs) = check_ctor_type_args ~env ~scope ~sub tvs in
    (env, scope, sub, a :: tvs)

(** Extend the environment by a named parameter that is not explicitly
  mentioned *)
let introduce_implicit_name env (name : T.name) sch =
  match name with
  | NVar x ->
    (* Do not introduce anything. Just create a fresh variable *)
    (env, Var.fresh ~name:x ())

  | NImplicit n ->
    (* Implicit parameters are implicitly introduced to the environment.
     This behavior might be considered controversial. We will see how it works
     in practice. *)
    Env.add_poly_implicit env n sch ignore

let rec check_ctor_named_args ~pos ~env ~scope nps named =
  match named with
  | [] ->
    List.iter
      (fun { S.pos; S.data = (n, _) } ->
        Error.warn (Error.redundant_named_pattern ~pos n))
      nps;
    (env, [])
  | (name, sch) :: named ->
    begin match select_named_pattern name nps with
    | None ->
      let (env, x) = introduce_implicit_name env name sch in
      let p = { T.pos = pos; T.data = T.PVar(x, sch) } in
      let (env, ps) = check_ctor_named_args ~pos ~env ~scope nps named in
      (env, p :: ps)
    | Some(p, nps) ->
      let (env, p, _) = check_scheme ~env ~scope p sch in
      let (env, ps) = check_ctor_named_args ~pos ~env ~scope nps named in
      (env, p :: ps)
    end

and check_scheme ~env ~scope (pat : S.pattern) sch =
  let make data = { pat with T.data = data } in
  match pat.data with
  | PWildcard ->
    (env, make T.PWildcard, Pure)
  | PId (IdVar x) ->
    let (env, x) = Env.add_poly_var env x sch in
    (env, make (T.PVar(x, sch)), Pure)
  | PId (IdImplicit n) ->
    let (env, x) = Env.add_poly_implicit env n sch ignore in
    (env, make (T.PVar(x, sch)), Pure)
  | PCtor _ ->
    begin match sch with
    | { sch_tvars = []; sch_named = []; sch_body = tp } ->
      check_type ~env ~scope pat tp
    | _ ->
      Error.fatal (Error.non_polymorphic_pattern ~pos:pat.pos)
    end
  | PAnnot(pat, sch') ->
    let sch_pos = sch'.sch_pos in
    let sch' = Type.tr_scheme env sch' in
    if not (Unification.subscheme env sch sch') then
      Error.report (Error.pattern_annot_mismatch ~pos:sch_pos ~env sch sch');
    check_scheme ~env ~scope:(Env.scope env) pat sch'

and check_type ~env ~scope (pat : S.pattern) tp =
  let make data = { pat with T.data = data } in
  match pat.data with
  | PWildcard | PId _ | PAnnot _ ->
    let sch = T.Scheme.of_type tp in
    check_scheme ~env ~scope pat sch

  | PCtor(cname, nps, args) ->
    begin match Env.lookup_ctor env cname.data with
    | Some(idx, info) ->
      let (sub, tps) = ExprUtils.guess_types env info.adt_args in
      let proof  = ExprUtils.make_tapp info.adt_proof tps in
      let ctors  = List.map (T.CtorDecl.subst sub) info.adt_ctors in
      let ctor   = List.nth ctors idx in
      let res_tp = T.Type.subst sub info.adt_type in
      let (env, scope, sub2, tvars) =
        check_ctor_type_args ~env ~scope ~sub:T.Subst.empty ctor.ctor_tvars in
      let ctor_named =
        List.map (T.NamedScheme.subst sub2) ctor.ctor_named in
      let ctor_arg_schemes =
        List.map (T.Scheme.subst sub2) ctor.ctor_arg_schemes in
      Uniqueness.check_named_pattern_uniqueness nps;
      let nps = List.map (tr_named_pattern env) nps in
      let (env, ps1) =
        check_ctor_named_args ~pos:pat.pos ~env ~scope nps ctor_named in
      if List.length ctor_arg_schemes <> List.length args then
        Error.fatal (Error.ctor_arity_mismatch ~pos:pat.pos
          cname.data (List.length ctor_arg_schemes) (List.length args))
      else if not (Unification.subtype env tp res_tp) then
        Error.fatal (Error.pattern_type_mismatch ~pos:pat.pos ~env
          res_tp tp)
      else
        let (env, ps2, _) =
          check_pattern_schemes ~env ~scope args ctor_arg_schemes in
        let pat = make
          (T.PCtor(cname.data, idx, proof, ctors, tvars, ps1 @ ps2)) in
        (* Pattern matching is always impure, as due to recursive types it can
          be used to encode non-termination *)
        (env, pat, Impure)

    | None ->
      Error.fatal (Error.unbound_constructor ~pos:cname.pos cname.data)
    end

and check_pattern_schemes ~env ~scope pats schs =
  match pats, schs with
  | [], [] -> (env, [], Pure)

  | pat :: pats, sch :: schs ->
    let (env, pat, r_eff1)  = check_scheme ~env ~scope pat sch in
    let (env, pats, r_eff2) = check_pattern_schemes ~env ~scope pats schs in
    (env, pat :: pats, ret_effect_join r_eff1 r_eff2)

  | [], _ :: _ | _ :: _, [] -> assert false

let infer_arg_scheme env (arg : S.arg) =
  match arg with
  | ArgAnnot(pat, sch) ->
    let sch = Type.tr_scheme env sch in
    let scope = Env.scope env in
    let (env, pat, r_eff) = check_scheme ~env ~scope pat sch in
    (env, pat, sch, r_eff)
  | ArgPattern pat ->
    let tp = Env.fresh_uvar env T.Kind.k_type in
    let scope = Env.scope env in
    let (env, pat, r_eff) = check_type ~env ~scope pat tp in
    (env, pat, T.Scheme.of_type tp, r_eff)

let check_arg_scheme env (arg : S.arg) sch =
  match arg with
  | ArgAnnot(pat, sch') ->
    let sch_pos = sch'.sch_pos in
    let sch' = Type.tr_scheme env sch' in
    if not (Unification.subscheme env sch sch') then
      Error.report (Error.pattern_annot_mismatch ~pos:sch_pos ~env sch sch');
    check_scheme ~env ~scope:(Env.scope env) pat sch'
  | ArgPattern pat -> check_scheme ~env ~scope:(Env.scope env) pat sch

let infer_named_arg_scheme env (na : S.named_arg) =
  let (name, arg) = na.data in
  let name = Name.tr_name env name in
  let (env, pat, sch, r_eff) = infer_arg_scheme env arg in
  (env, (name, pat, sch), r_eff)

let rec infer_named_arg_schemes env ims =
  match ims with
  | []        -> (env, [], Pure)
  | im :: ims ->
    let (env, im, r_eff1)  = infer_named_arg_scheme env im in
    let (env, ims, r_eff2) = infer_named_arg_schemes env ims in
    (env, im :: ims, ret_effect_join r_eff1 r_eff2)

let rec fold_implicit f acc (pat : S.pattern) =
  match pat.data with
  | PWildcard | PId (IdVar _) -> acc
  | PId (IdImplicit n) -> f acc n
  | PCtor(_, named, ps) ->
    let acc = List.fold_left (fold_implicit_n f) acc named in
    List.fold_left (fold_implicit f) acc ps
  | PAnnot(pat, _) ->
    fold_implicit f acc pat

and fold_implicit_n f acc (np : S.named_pattern) =
  match np.data with
  | (_, p) -> fold_implicit f acc p
